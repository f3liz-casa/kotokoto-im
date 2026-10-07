import CoreGraphics
import Foundation
import KotokotoCore

/// キーイベントを監視して入力ソースを切り替える。
/// - F18 (Caps Lock から差し替え済み) → 韓国語 (イベントは消費)
/// - 左⌘単独タップ → 英語 / 右⌘単独タップ → 日本語
final class EventTap {
    private var detector = TapDetector()
    private var port: CFMachPort?

    // NX_DEVICELCMDKEY / NX_DEVICERCMDKEY (左右を区別するデバイス依存ビット)
    private let leftCmdBit: UInt64 = 0x08
    private let rightCmdBit: UInt64 = 0x10
    private let leftCmdKey: Int64 = 55
    private let rightCmdKey: Int64 = 54

    func start() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port = port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if code == CapsLockRemap.f18KeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if type == .keyDown && !isRepeat { InputSources.select(.korean) }
                return nil
            }
            detector.otherInput()
            return pass

        case .flagsChanged:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let side: CommandSide
            let bit: UInt64
            switch code {
            case leftCmdKey: (side, bit) = (.left, leftCmdBit)
            case rightCmdKey: (side, bit) = (.right, rightCmdBit)
            default:
                detector.otherInput()
                return pass
            }
            let now = Double(event.timestamp) / 1_000_000_000 // ns → s
            let isDown = event.flags.rawValue & bit != 0
            if let lang = detector.commandChanged(side, isDown: isDown, at: now) {
                InputSources.select(lang)
            }
            return pass

        default: // マウスクリック (⌘+クリック対策)
            detector.otherInput()
            return pass
        }
    }
}
