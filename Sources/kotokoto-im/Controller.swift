import AppKit
import ApplicationServices
import KotokotoCore

/// メニューバー常駐の本体。普段は静かで、困ったときだけメニューに理由と次の一手を出す。
final class Controller: NSObject, NSApplicationDelegate {
    private enum State {
        case running
        case needsAccessibility
        case needsInputMonitoring
    }

    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/kotokoto-im/config.json")

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warningLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "", action: #selector(openPrivacySettings), keyEquivalent: "")

    private var config = Config()
    private var configWarning: String?
    private var switchWarning: String?
    private var state: State = .needsAccessibility
    private var tap: EventTap?
    private var remapped = false
    private var pollTimer: Timer?
    private var settingsURL = ""
    private var askedForAccessibility = false

    private let settleInterval = 0.08  // これより短い間隔の切り替えはまとめる (秒)
    private let verifyDelay = 0.06     // 切り替え後にこの時間待って確認する (秒)
    private var lastSwitchAt = DispatchTime(uptimeNanoseconds: 0)
    private var pendingSwitch: DispatchWorkItem?
    private var generation = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        InputSources.observeChanges()
        reload()
    }

    func applicationWillTerminate(_ notification: Notification) {
        teardown()
    }

    /// Ctrl-C / kill 用。Caps Lock の割り当てを戻してから終了する。
    func shutdown() -> Never {
        teardown()
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

    private func teardown() {
        pollTimer?.invalidate()
        pollTimer = nil
        tap?.stop()
        tap = nil
        if remapped { CapsLockRemap.disable(); remapped = false }
    }

    private func loadConfig() {
        configWarning = nil
        config = Config()
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
        let t = EventTap(config: config) { [weak self] lang in self?.switchTo(lang) }
        guard t.start() else {
            state = .needsInputMonitoring
            settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            return false
        }
        tap = t
        // タップが動いてから差し替える (動かないのに Caps Lock だけ効かなくなるのを防ぐ)
        if config.capsLock != .none { CapsLockRemap.enable(); remapped = true }
        state = .running
        return true
    }

    /// 権限が許可されるまで 2 秒ごとに再試行する (許可後に再起動しなくてよい)。
    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
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
        let failure = InputSources.select(language, preferred: preferred)
        if failure != switchWarning { switchWarning = failure; refresh() }
        guard failure == nil else { return }
        // 切り替えが IME 側で戻されていたら一度だけ選び直す (間に別の切り替えが入っていたら何もしない)
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
            guard let self = self, self.generation == mine,
                  !InputSources.isCurrent(language, preferred: preferred) else { return }
            _ = InputSources.select(language, preferred: preferred)
        }
    }

    // MARK: - メニュー

    private func buildMenu() {
        let menu = NSMenu()
        for i in [statusLine, warningLine, settingsItem] { i.target = self; menu.addItem(i) }
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
        case .needsAccessibility:
            statusLine.title = "アクセシビリティの許可が必要です"
            settingsItem.title = "アクセシビリティ設定を開く…"
            settingsItem.isHidden = false
        case .needsInputMonitoring:
            statusLine.title = "入力監視の許可が必要です"
            settingsItem.title = "入力監視の設定を開く…"
            settingsItem.isHidden = false
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
