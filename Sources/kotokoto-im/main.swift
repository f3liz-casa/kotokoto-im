import AppKit
import ApplicationServices

let args = CommandLine.arguments.dropFirst()

if args.contains("--list") {
    InputSources.printEnabled()
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    kotokoto-im: Caps Lock=韓国語 / 左⌘=英語 / 右⌘=日本語
      --list               有効な入力ソース ID を表示
      --no-capslock-remap  Caps Lock → F18 の差し替えを行わない
    """)
    exit(0)
}

// アクセシビリティ権限 (未許可ならシステムのダイアログを出す)
let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary) else {
    fputs("アクセシビリティ権限が必要です。システム設定 > プライバシーとセキュリティ > アクセシビリティ で許可して再起動してください。\n", stderr)
    exit(1)
}

let remapCapsLock = !args.contains("--no-capslock-remap")
if remapCapsLock { CapsLockRemap.enable() }

func shutdown() -> Never {
    if remapCapsLock { CapsLockRemap.disable() }
    exit(0)
}

let tap = EventTap()
guard tap.start() else {
    fputs("イベントタップを作成できませんでした (入力監視の権限を確認してください)。\n", stderr)
    if remapCapsLock { CapsLockRemap.disable() }
    exit(1)
}

// Ctrl-C / kill で終了するときも Caps Lock の割り当てを元に戻す
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { shutdown() }
    s.resume()
    signalSources.append(s)
}

// メニューバー常駐 (Dock には出さない)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "言"
let menu = NSMenu()
let quit = NSMenuItem(title: "kotokoto-im を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
menu.addItem(quit)
item.menu = menu

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        if remapCapsLock { CapsLockRemap.disable() }
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()
