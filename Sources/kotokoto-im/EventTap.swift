import CoreGraphics
import Foundation
import KotokotoCore

/// キーイベントを監視して切り替え要求を出す。
/// - F18 (Caps Lock から差し替え済み) → capsLock の割り当て (イベントは消費)
/// - 左/右⌘の単独タップ → leftCommand / rightCommand の割り当て
final class EventTap {
    private let config: Config
    private let onSwitch: (Language) -> Void
    /// システムにタップを止められたとき (タイムアウトや権限の取り消し) に呼ばれる。
    private let onDisabled: () -> Void
    private var detector: TapDetector
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    // NX_DEVICELCMDKEY / NX_DEVICERCMDKEY (左右を区別するデバイス依存ビット)
    private let leftCmdBit: UInt64 = 0x08
    private let rightCmdBit: UInt64 = 0x10
    private let leftCmdKey: Int64 = 55
    private let rightCmdKey: Int64 = 54

    init(config: Config, onSwitch: @escaping (Language) -> Void, onDisabled: @escaping () -> Void) {
        self.config = config
        self.onSwitch = onSwitch
        self.onDisabled = onDisabled
        self.detector = TapDetector(maxTapDuration: config.maxTapDuration)
    }

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
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func reenable() {
        if let port = port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    func stop() {
        if let port = port { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        port = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 再開してよいかは持ち主が決める (権限が外されているのに再開し続けると入力が固まる)。
            // タップを止める・壊す処理をコールバックの中で行わないよう、次の実行ループに回す。
            let notify = onDisabled
            DispatchQueue.main.async { notify() }
            return pass

        case .keyDown, .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // 差し替えが有効なときだけ F18 を消費する (本物の F18 キーを奪わない)
            if code == CapsLockRemap.f18KeyCode, let lang = config.capsLock.language {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if type == .keyDown && !isRepeat { onSwitch(lang) }
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
            if let tapped = detector.commandChanged(side, isDown: isDown, at: now) {
                let target = tapped == .left ? config.leftCommand : config.rightCommand
                if let lang = target.language { onSwitch(lang) }
            }
            return pass

        default: // マウスクリック (⌘+クリック対策)
            detector.otherInput()
            return pass
        }
    }
}
