import Foundation

/// Caps Lock を F18 に割り当てる (hidutil、root 不要)。
/// Caps Lock を直接フックすると遅延や取りこぼしが出るため、gksdud と同様にキーを差し替える。
/// 設定は再起動で消える。正常終了時は UserKeyMapping を空に戻す。
/// 強制終了で残った場合は `kotokoto-im --reset` で戻せる。
enum CapsLockRemap {
    static let f18KeyCode: Int64 = 79 // kVK_F18

    private static let capsLockUsage = 0x700000039
    private static let f18Usage = 0x70000006D

    /// hidutil は数百 ms かかることがある。メインスレッド (= キー入力を処理する側) を止めないよう、専用のキューで実行する。
    private static let queue = DispatchQueue(label: "casa.f3liz.kotokoto-im.hidutil")

    private static func hidutil(_ json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", json]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    private static var enableJSON: String {
        """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockUsage),"HIDKeyboardModifierMappingDst":\(f18Usage)}]}
        """
    }
    private static let disableJSON = #"{"UserKeyMapping":[]}"#

    /// 順序は保たれる (enable → disable の順に呼べば、その順に実行される)。
    static func enable() {
        queue.async { hidutil(enableJSON) }
    }

    static func disable() {
        queue.async { hidutil(disableJSON) }
    }

    /// 終了時用。割り当てを戻し終わるまで待つ (待たないと、戻す前にプロセスが終わる)。
    static func disableAndWait() {
        queue.sync { hidutil(disableJSON) }
    }
}
