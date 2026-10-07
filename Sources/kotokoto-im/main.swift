import AppKit

let args = CommandLine.arguments.dropFirst()

if args.contains("--list") {
    InputSources.printEnabled()
    exit(0)
}
if args.contains("--bench") {
    InputSources.bench()
    exit(0)
}
if args.contains("--reset") {
    CapsLockRemap.disable()
    print("Caps Lock の割り当てを元に戻しました。")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print("""
    kotokoto-im: メニューバー常駐の入力ソース切り替え (既定: Caps Lock=韓国語 / 左⌘=英語 / 右⌘=日本語)
      --list    有効な入力ソース ID を表示
      --bench   入力ソースの切り替え時間を測る (終わると元の入力ソースに戻る)
      --reset   強制終了などで残った Caps Lock の割り当てを元に戻す
    設定: \(Controller.configURL.path) (メニューの「設定ファイルを開く」から雛形を作れます)
    """)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Dock には出さない
let controller = Controller()
app.delegate = controller

// Ctrl-C / kill / ログアウトで終了するときも Caps Lock の割り当てを戻す
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { controller.shutdown() }
    s.resume()
    signalSources.append(s)
}

app.run()
