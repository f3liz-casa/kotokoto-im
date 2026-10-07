/// 切り替え先の言語。
public enum Language: String, Equatable, CaseIterable {
    case english
    case japanese
    case korean

    public var displayName: String {
        switch self {
        case .english: return "英語"
        case .japanese: return "日本語"
        case .korean: return "韓国語"
        }
    }
}
