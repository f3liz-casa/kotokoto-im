/// 切り替え先の言語。
public enum Language: Equatable {
    case english
    case japanese
    case korean
}

public enum CommandSide: Equatable {
    case left
    case right
}

/// ⌘キーが「単独で軽く押されて離された」ことを検出する。
/// ⌘+C のようなショートカットや ⌘+クリック、長押しでは発火しない。
public struct TapDetector {
    /// これより長く押していたらタップとみなさない (秒)。
    public var maxTapDuration: Double

    private var held: Set<Int> = []   // 0 = left, 1 = right
    private var pending: CommandSide?
    private var pressedAt: Double = 0

    public init(maxTapDuration: Double = 0.5) {
        self.maxTapDuration = maxTapDuration
    }

    /// ⌘キーの押下/解放を通知する。タップが成立したら切り替え先を返す。
    public mutating func commandChanged(_ side: CommandSide, isDown: Bool, at time: Double) -> Language? {
        let id = side == .left ? 0 : 1
        if isDown {
            let alreadyHeld = !held.isEmpty
            held.insert(id)
            // 両⌘同時押しは曖昧なので無効化
            pending = alreadyHeld ? nil : side
            pressedAt = time
            return nil
        }
        held.remove(id)
        defer { pending = nil }
        guard pending == side, time - pressedAt <= maxTapDuration else { return nil }
        return side == .left ? .english : .japanese
    }

    /// ⌘以外のキー入力・修飾キー変化・マウスクリックを通知する (タップを無効化)。
    public mutating func otherInput() {
        pending = nil
    }
}
