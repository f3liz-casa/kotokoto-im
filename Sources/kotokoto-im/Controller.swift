import AppKit
import ApplicationServices
import Carbon
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

    private var config = Config()
    private var configWarning: String?
    private var switchWarning: String?
    private var state: State = .needsAccessibility
    private var tap: EventTap?
    private var remapped = false
    private var remapGeneration = 0
    private let remapDelay = 1.0       // タップ開始から Caps Lock を差し替えるまでの待ち (秒)
    private var suspendStamps: [UInt64] = []
    private var pollTimer: Timer?
    private var timeoutStamps: [UInt64] = []
    private var healthTimer: Timer?
    private var settingsURL = ""
    private var askedForAccessibility = false

    private let settleInterval = 0.08  // これより短い間隔の切り替えはまとめる (秒)
    private let verifyDelay = 0.06     // 切り替え後にこの時間待って確認する (秒)
    private var lastSwitchAt = DispatchTime(uptimeNanoseconds: 0)
    private var pendingSwitch: DispatchWorkItem?
    private var generation = 0

    private let landingDelay = 0.03    // 切り替えの通知から、入力先が使えるようになるまでの余裕 (秒)
    private let holdTimeout = 0.3      // 通知が来なくてもキーを預かるのはこの時間まで (秒)
    private var holdGeneration = 0
    private var holdTarget: (language: Language, preferred: [String])?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        InputSources.observeChanges()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.inputSourceChanged() }
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
        if !tryStart() { startPolling() }
        refresh()
    }

    private func teardown(wait: Bool = false) {
        remapGeneration += 1 // まだ実行されていない Caps Lock の差し替えを取り消す
        pollTimer?.invalidate()
        pollTimer = nil
        healthTimer?.invalidate()
        healthTimer = nil
        tap?.endHold()
        tap?.stop()
        tap = nil
        if remapped {
            if wait { CapsLockRemap.disableAndWait() } else { CapsLockRemap.disable() }
            remapped = false
        }
    }

    private func loadConfig() {
        configWarning = nil
        config = Config()
        Trace.enabled = false
        defer { if config.trace { Trace.enabled = true; Trace.log("--- 起動 / 設定を読み込み (trace 有効) ---") } }
        guard let data = try? Data(contentsOf: Self.configURL) else { return } // 無ければ既定値
        do {
            config = try Config.parse(data)
        } catch {
            configWarning = "設定ファイルを読めなかったので既定値で動いています (\(error))"
        }
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
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            return false
        }
        let t = EventTap(config: config,
                         onSwitch: { [weak self] lang in self?.switchTo(lang) },
                         onDisabled: { [weak self] reason in self?.tapWasDisabled(reason) })
        guard t.start() else {
            state = .needsInputMonitoring
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            return false
        }
        tap = t
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
            let now = DispatchTime.now().uptimeNanoseconds
            timeoutStamps = timeoutStamps.filter { now - $0 < 10_000_000_000 } + [now]
            if timeoutStamps.count > 3 { suspend() } else if AXIsProcessTrusted() { tap?.reenable() } else { suspend() }
        }
    }

    /// タップと Caps Lock の差し替えを手放し、権限が戻る/落ち着くのを待つ (すぐには再開しない)。
    private func suspend() {
        teardown()
        timeoutStamps = []
        state = AXIsProcessTrusted() ? .restarting : .needsAccessibility
        settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        // 繰り返し止められるなら、再開の間隔を倍々に延ばす (最大 30 秒)。権限の状態が食い違っていると、
        // 再開と停止を繰り返してキー入力が滞るため。
        let now = DispatchTime.now().uptimeNanoseconds
        suspendStamps = suspendStamps.filter { now - $0 < 60_000_000_000 } + [now]
        let interval = min(30.0, 2.0 * pow(2.0, Double(suspendStamps.count - 1)))
        Trace.log("手放した。再確認まで \(Int(interval)) 秒 (60 秒間に \(suspendStamps.count) 回目)")
        startPolling(interval: interval)
        refresh()
    }

    /// 動作中に権限が外された (見張りが気づいた)。
    private func permissionLost() {
        suspend()
    }

    /// 権限が外されたことをタップが止められる前に気づくための見張り (1 秒ごと)。
    private func startHealthCheck() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            if !AXIsProcessTrusted() { self?.permissionLost() }
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

    /// 切り替え要求。前の切り替えから間もないときは、落ち着くまで待って最後の要求だけ行う
    /// (英語⇔日本語を素早く往復すると、表示は日本語なのに英語が入力される問題への対策)。
    /// 間隔が空いているときは待たずに即座に切り替える。
    private func switchTo(_ language: Language) {
        pendingSwitch?.cancel()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSwitchAt.uptimeNanoseconds) / 1e9
        Trace.log("要求 \(language.displayName) (前の切り替えから \(Int(elapsed * 1000)) ms\(elapsed >= settleInterval ? "" : "、待って実行"))")
        if elapsed >= settleInterval {
            perform(language)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.perform(language) }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (settleInterval - elapsed), execute: work)
    }

    private func perform(_ language: Language) {
        lastSwitchAt = DispatchTime.now()
        generation += 1
        let mine = generation
        let preferred = config.inputSources[language.rawValue] ?? []
        let willChange = !InputSources.isCurrent(language, preferred: preferred)
        Trace.log("実行 \(language.displayName): 現在=\(InputSources.currentID() ?? "?") 切り替わる=\(willChange)")
        let failure = InputSources.select(language, preferred: preferred)
        Trace.log("select 結果: \(failure ?? "OK") 現在=\(InputSources.currentID() ?? "?")")
        if failure != switchWarning { switchWarning = failure; refresh() }
        guard failure == nil else { return }
        if willChange { holdKeys(until: language, preferred: preferred) }
        // 切り替えが IME 側で戻されていたら一度だけ選び直す (間に別の切り替えが入っていたら何もしない)
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
            guard let self = self, self.generation == mine else { return }
            let ok = InputSources.isCurrent(language, preferred: preferred)
            Trace.log("確認 (+\(Int(self.verifyDelay * 1000)) ms): 現在=\(InputSources.currentID() ?? "?") 一致=\(ok)")
            if !ok {
                // 覚えていた参照が古くて効いていない可能性があるので、引き直してから選び直す
                InputSources.invalidate()
                let retry = InputSources.select(language, preferred: preferred)
                Trace.log("選び直し: \(retry ?? "OK")")
                return
            }
        }
    }

    /// 切り替えが入力先に届くまでキー入力を預かる (`EventTap` の説明を参照)。
    /// 切り替えの通知が来て少し待ったら、通知が来なくても `holdTimeout` で必ず戻す。
    private func holdKeys(until language: Language, preferred: [String]) {
        tap?.beginHold()
        Trace.log("キーを預かり始める")
        holdTarget = (language, preferred)
        holdGeneration += 1
        let mine = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + holdTimeout) { [weak self] in
            guard let self = self, self.holdGeneration == mine else { return }
            self.releaseHeldKeys("時間切れ")
        }
    }

    /// 預かったキーを返す。
    private func releaseHeldKeys(_ reason: String) {
        guard holdTarget != nil else { return } // 二重に呼ばれても一度だけ
        holdTarget = nil
        let count = tap?.endHold() ?? 0
        Trace.log("キーを返す (\(reason)): \(count) 件")
    }

    /// 入力ソースが切り替わった通知。狙いどおりなら、入力先の準備を少し待ってから預かったキーを送る。
    private func inputSourceChanged() {
        Trace.log("通知: 入力ソース変更 現在=\(InputSources.currentID() ?? "?")")
        guard let target = holdTarget,
              InputSources.isCurrent(target.language, preferred: target.preferred) else { return }
        let mine = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + landingDelay) { [weak self] in
            guard let self = self, self.holdGeneration == mine else { return }
            self.releaseHeldKeys("切り替え確認")
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
