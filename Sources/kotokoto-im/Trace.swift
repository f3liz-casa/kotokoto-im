import Foundation

/// 切り替えの経緯を ~/Library/Logs/kotokoto-im.log に書く診断用ログ (設定の trace が true のときだけ)。
/// 「表示と入力がずれる」ような再現しにくい問題を、タイミングごと確かめるためのもの。
enum Trace {
    static var enabled = false

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/kotokoto-im.log")
    private static let origin = DispatchTime.now().uptimeNanoseconds

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        // origin は初回アクセスで初期化される。先に読んでから現在時刻を取る (逆だと UInt64 の引き算が負になって落ちる)
        let start = origin
        let now = DispatchTime.now().uptimeNanoseconds
        let ms = Double(now >= start ? now - start : 0) / 1e6
        let line = String(format: "%10.1f ms  ", ms) + message() + "\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
