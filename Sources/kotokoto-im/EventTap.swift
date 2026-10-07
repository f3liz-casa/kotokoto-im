import AppKit
import CoreGraphics
import Foundation
import KotokotoCore

/// システムにタップを止められた理由。
enum TapDisabledReason {
    case timeout    // コールバックが遅かった
    case userInput  // 権限の取り消しなど、システム側の都合
}

/// キーイベントを監視して切り替え要求を出す。
/// - F18 (Caps Lock から差し替え済み) → capsLock の割り当て (イベントは消費)
/// - 左/右⌘の単独タップ → leftCommand / rightCommand の割り当て
final class EventTap {
    private let config: Config
    private let onSwitch: (Language) -> Void
    /// システムにタップを止められたとき (タイムアウトや権限の取り消し) に呼ばれる。
    private let onDisabled: (TapDisabledReason) -> Void
    private var detector: TapDetector
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var mouseMonitors: [Any] = []

    // 入力ソースの切り替え中に打たれたキーを預かる。macOS は切り替えを通知してから、
    // 入力先アプリの入力メソッドが使えるようになるまで少し間があり、その間のキーは切り替え前の入力ソースに届く
    // (表示は日本語なのに英語が入力される)。切り替えが済んでから元の順序で送り直す。gksdud と同じ考え方。
    private var holding = false
    private var heldEvents: [CGEvent] = []
    private let maxHeld = 128
    /// 送り直したイベントの目印。自分のタップで再び預からないようにする。
    private let replayMarker: Int64 = 0x4B4F544F // "KOTO"

    // NX_DEVICELCMDKEY / NX_DEVICERCMDKEY (左右を区別するデバイス依存ビット)
    private let leftCmdBit: UInt64 = 0x08
    private let rightCmdBit: UInt64 = 0x10
    private let leftCmdKey: Int64 = 55
    private let rightCmdKey: Int64 = 54

    init(config: Config, onSwitch: @escaping (Language) -> Void, onDisabled: @escaping (TapDisabledReason) -> Void) {
        self.config = config
        self.onSwitch = onSwitch
        self.onDisabled = onDisabled
        self.detector = TapDetector(maxTapDuration: config.maxTapDuration)
    }

    func start() -> Bool {
        // マウスは差し止め可能なタップに通さない (タップが止まったときにマウスまで固まるのを避ける)。
        // クリックの検知は NSEvent の監視で行う (cmd-eikana と同じ)。
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
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
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] _ in self?.detector.otherInput() }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] event in
            self?.detector.otherInput(); return event
        }) {
            mouseMonitors.append(local)
        }
        return true
    }

    func reenable() {
        if let port = port { CGEvent.tapEnable(tap: port, enable: true) }
    }

    /// キーを預かり始める。`endHold()` が呼ばれるまで、キー入力は届かない。
    func beginHold() { holding = true }

    /// 預かったキーを元の順序で送り直し、通常に戻す。
    @discardableResult
    func endHold() -> Int {
        holding = false
        let events = heldEvents
        heldEvents = []
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: replayMarker)
            event.post(tap: .cghidEventTap)
        }
        return events.count
    }

    func stop() {
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
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
            let reason: TapDisabledReason = type == .tapDisabledByTimeout ? .timeout : .userInput
            DispatchQueue.main.async { notify(reason) }
            return pass

        case .keyDown, .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == replayMarker { return pass }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            // 差し替えが有効なときだけ F18 を消費する (本物の F18 キーを奪わない)
            if code == CapsLockRemap.f18KeyCode, let lang = config.capsLock.language {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // 入力ソースの操作はコールバックの外で行う (重いとタップが止まり、入力全体が固まる)
                if type == .keyDown && !isRepeat { let go = onSwitch; DispatchQueue.main.async { go(lang) } }
                return nil
            }
            detector.otherInput()
            if holding, let copy = event.copy() {
                heldEvents.append(copy)
                if heldEvents.count >= maxHeld { endHold() }
                return nil
            }
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
                if let lang = target.language { let go = onSwitch; DispatchQueue.main.async { go(lang) } }
            }
            return pass

        default:
            return pass
        }
    }
}
