import Foundation

/// Caps Lock を F18 に割り当てる (hidutil、root 不要)。
/// Caps Lock を直接フックすると遅延や取りこぼしが出るため、gksdud と同様にキーを差し替える。
/// 設定は再起動で消える。終了時に UserKeyMapping を空に戻す。
enum CapsLockRemap {
    static let f18KeyCode: Int64 = 79 // kVK_F18

    private static let capsLockUsage = 0x700000039
    private static let f18Usage = 0x70000006D

    private static func hidutil(_ json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        p.arguments = ["property", "--set", json]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func enable() {
        hidutil("""
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(capsLockUsage),"HIDKeyboardModifierMappingDst":\(f18Usage)}]}
        """)
    }

    static func disable() {
        hidutil(#"{"UserKeyMapping":[]}"#)
    }
}
