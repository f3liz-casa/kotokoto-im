import AppKit
import ApplicationServices
import KotokotoCore

/// メニューバー常駐の本体。普段は静かで、困ったときだけメニューに理由と次の一手を出す。
final class Controller: NSObject, NSApplicationDelegate {
    private enum State {
        case running
        case needsAccessibility
        case needsInputMonitoring
        case restarting  // システムに止められたので、少し待ってから再開する
    }

    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kotokoto-im/config.json")

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warningLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "", action: #selector(openPrivacySettings), keyEquivalent: "")

    // 設定と状態
    private var config = Config()
    private var configWarning: String?
    private var switchWarning: String?
    private var state: State = .needsAccessibility
    private var settingsURL = ""
    private var askedForAccessibility = false

    // 切り替え
    private let switcher = Switcher()
    private var tap: EventTap?

    // Caps Lock の差し替え
    private var remapped = false
    private var remapGeneration = 0    // 取り消したい差し替えを無効にする
    private let remapDelay = 1.0       // タップ開始から Caps Lock を差し替えるまでの待ち (秒)

    // 権限と、システムにタップを止められたときの対処
    private var pollTimer: Timer?
    private var healthTimer: Timer?
    private var timeoutStamps: [UInt64] = []
    private var suspendStamps: [UInt64] = []

    private static let accessibilityURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let inputMonitoringURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        InputSources.observeChanges()
        switcher.onWarning = { [weak self] warning in
            guard let self = self, warning != self.switchWarning else { return }
            self.switchWarning = warning
            self.refresh()
        }
        reload()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown(wait: true)
    }

    /// Ctrl-C / kill 用。Caps Lock の割り当てを戻してから終了する。
    func shutdown() -> Never {
        teardown(wait: true)
        exit(0)
    }

    // MARK: - 起動・停止

    @objc private func reload() {
        teardown()
        InputSources.invalidate()
        loadConfig()
        switcher.config = config
        if !tryStart() { startPolling() }
        refresh()
    }

    private func teardown(wait: Bool = false) {
        remapGeneration += 1 // まだ実行されていない Caps Lock の差し替えを取り消す
        pollTimer?.invalidate()
        pollTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        switcher.cancelAll() // 預かっているキーを返してから、タップを止める
        tap?.stop()
        tap = nil
        switcher.tap = nil
        if remapped {
            if wait { CapsLockRemap.disableAndWait() } else { CapsLockRemap.disable() }
            remapped = false
        }
    }

    private func loadConfig() {
        configWarning = nil
        config = Config()
        if let data = try? Data(contentsOf: Self.configURL) { // 無ければ既定値
            do {
                config = try Config.parse(data)
            } catch {
                configWarning = "設定ファイルを読めなかったので既定値で動いています (\(error))"
            }
        }
        Trace.enabled = config.trace
        Trace.log("--- 起動 / 設定を読み込み (trace 有効) ---")
    }

    /// 権限が揃っていれば開始する。揃っていなければ state を更新して false。
    private func tryStart() -> Bool {
        if !AXIsProcessTrusted() {
            if !askedForAccessibility { // システムのダイアログは一度だけ
                askedForAccessibility = true
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
            state = .needsAccessibility
            settingsURL = Self.accessibilityURL
            return false
        }
        let t = EventTap(config: config,
                         onSwitch: { [weak self] lang in self?.switcher.request(lang) },
                         onDisabled: { [weak self] reason in self?.tapWasDisabled(reason) })
        guard t.start() else {
            state = .needsInputMonitoring
            settingsURL = Self.inputMonitoringURL
            return false
        }
        tap = t
        switcher.tap = t
        // タップが動いてから差し替える (動かないのに Caps Lock だけ効かなくなるのを防ぐ)。
        // さらに少し待ち、タップがすぐ止められなかったときだけ行う (権限が外れかけているときに、
        // 開始と解除を繰り返して hidutil を何度も起動するのを避ける)。
        remapGeneration += 1
        let mine = remapGeneration
        if config.capsLock != .none {
            DispatchQueue.main.asyncAfter(deadline: .now() + remapDelay) { [weak self] in
                guard let self = self, self.remapGeneration == mine, self.tap === t else { return }
                CapsLockRemap.enable()
                self.remapped = true
            }
        }
        state = .running
        startHealthCheck()
        return true
    }

    /// システムにタップを止められた。
    /// - 権限の取り消しなどシステム側の都合 (userInput): 再開せず、タップと Caps Lock の差し替えを手放す。
    ///   権限を外した直後は `AXIsProcessTrusted()` がまだ true を返すことがあり、再開しても直後にまた止められ、
    ///   その繰り返しで入力が固まる。再開は少し待ってから (`startPolling`) 確かめ直す。
    /// - コールバックが遅かった (timeout): 再開するが、短時間に繰り返すなら手放す。
    private func tapWasDisabled(_ reason: TapDisabledReason) {
        guard tap != nil else { return } // すでに手放したあとに届いた通知は無視する
        Trace.log("タップが止められた: \(reason) 信頼=\(AXIsProcessTrusted())")
        switch reason {
        case .userInput:
            suspend()
        case .timeout:
            timeoutStamps = Self.appendingNow(to: timeoutStamps, within: 10)
            if timeoutStamps.count > 3 || !AXIsProcessTrusted() { suspend() } else { tap?.reenable() }
        }
    }

    /// タップと Caps Lock の差し替えを手放し、権限が戻る/落ち着くのを待つ (すぐには再開しない)。
    private func suspend() {
        teardown()
        timeoutStamps = []
        state = AXIsProcessTrusted() ? .restarting : .needsAccessibility
        settingsURL = Self.accessibilityURL
        // 繰り返し止められるなら、再開の間隔を倍々に延ばす (最大 30 秒)。権限の状態が食い違っていると、
        // 再開と停止を繰り返してキー入力が滞るため。
        suspendStamps = Self.appendingNow(to: suspendStamps, within: 60)
        let interval = min(30.0, 2.0 * pow(2.0, Double(suspendStamps.count - 1)))
        Trace.log("手放した。再確認まで \(Int(interval)) 秒 (60 秒間に \(suspendStamps.count) 回目)")
        startPolling(interval: interval)
        refresh()
    }

    /// 直近 `window` 秒以内の時刻に、今を足したもの。
    private static func appendingNow(to stamps: [UInt64], within window: Double) -> [UInt64] {
        let now = DispatchTime.now().uptimeNanoseconds
        let limit = UInt64(window * 1e9)
        return stamps.filter { now - $0 < limit } + [now]
    }

    /// 権限が外されたことを、タップが止められる前に気づくための見張り (1 秒ごと)。
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if !AXIsProcessTrusted() { self?.suspend() }
        }
    }

    /// 権限が許可されるまで 2 秒ごとに再試行する (許可後に再起動しなくてよい)。
    private func startPolling(interval: Double = 2) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self, self.tryStart() else { self?.refresh(); return }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.refresh()
        }
    }

    // MARK: - メニュー

    private func buildMenu() {
        let menu = NSMenu()
        for i in [statusLine, warningLine, hintLine, settingsItem] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        let reloadItem = NSMenuItem(title: "設定を再読み込み", action: #selector(reload), keyEquivalent: "r")
        let openItem = NSMenuItem(title: "設定ファイルを開く", action: #selector(openConfig), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "kotokoto-im を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for i in [reloadItem, openItem] { i.target = self }
        [reloadItem, openItem, .separator(), quitItem].forEach(menu.addItem)
        item.menu = menu
    }

    private func refresh() {
        let warning = configWarning ?? switchWarning
        item.button?.title = state == .running && warning == nil ? "言" : "言⚠"

        switch state {
        case .running:
            statusLine.title = "動作中: " + bindingSummary()
            settingsItem.isHidden = true
            hintLine.isHidden = true
        case .needsAccessibility:
            statusLine.title = "アクセシビリティの許可が必要です"
            settingsItem.title = "アクセシビリティ設定を開く…"
            settingsItem.isHidden = false
            // 再ビルドで署名が変わると、一覧でオンでも許可として扱われないことがある
            hintLine.title = "オンなのに変わらない場合: 一覧から kotokoto-im を削除(−)し、アプリを追加し直してください"
            hintLine.isHidden = false
        case .restarting:
            statusLine.title = "キー入力の監視をシステムに止められました。少し待って再開します"
            settingsItem.isHidden = true
            hintLine.isHidden = true
        case .needsInputMonitoring:
            statusLine.title = "入力監視の許可が必要です"
            settingsItem.title = "入力監視の設定を開く…"
            settingsItem.isHidden = false
            hintLine.isHidden = true
        }
        warningLine.title = warning ?? ""
        warningLine.isHidden = warning == nil
    }

    private func bindingSummary() -> String {
        func label(_ key: String, _ t: Target) -> String? { t.language.map { "\(key)→\($0.displayName)" } }
        return [label("Caps Lock", config.capsLock), label("左⌘", config.leftCommand), label("右⌘", config.rightCommand)]
            .compactMap { $0 }.joined(separator: " / ")
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
    }

    /// 設定ファイルが無ければ既定値の雛形を作ってから開く。
    @objc private func openConfig() {
        let url = Self.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config().templateData().write(to: url)
        }
        NSWorkspace.shared.open(url)
    }
}
