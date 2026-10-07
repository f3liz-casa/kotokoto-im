import Foundation

/// キーの割り当て先。`none` はそのキーを何もしない(Caps Lock なら差し替えもしない)。
public enum Target: String, Codable, Equatable {
    case english, japanese, korean, none

    public var language: Language? { Language(rawValue: rawValue) }
}

/// ~/.config/kotokoto-im/config.json。書かれていない項目は既定値になる。
public struct Config: Codable, Equatable {
    public var capsLock: Target = .korean
    public var leftCommand: Target = .english
    public var rightCommand: Target = .japanese
    /// ⌘をこの秒数より長く押していたらタップとみなさない。
    public var maxTapDuration: Double = 0.5
    /// 言語ごとに優先して使う入力ソース ID (例: {"korean": ["com.apple.inputmethod.Korean.3SetKorean"]})。
    /// `kotokoto-im --list` で ID を確認できる。
    public var inputSources: [String: [String]] = [:]
    /// 日本語への切り替えのあと、Mozc / Google 日本語入力なら「かな」キーを送ってひらがなモードにする (実験的)。
    /// 入力ソースは日本語になっても IME が直接入力モードのまま、英字が入力されることへの対策。
    /// 日本語入力が使えるようになる前に送ると制御文字 (U+0010) が入力されることがあるため、既定はオフ。
    public var sendKanaKey: Bool = false
    /// 切り替えの経緯を ~/Library/Logs/kotokoto-im.log に書く (診断用)。
    public var trace: Bool = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case capsLock, leftCommand, rightCommand, maxTapDuration, inputSources, sendKanaKey, trace
    }

    public struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        capsLock = try c.decodeIfPresent(Target.self, forKey: .capsLock) ?? d.capsLock
        leftCommand = try c.decodeIfPresent(Target.self, forKey: .leftCommand) ?? d.leftCommand
        rightCommand = try c.decodeIfPresent(Target.self, forKey: .rightCommand) ?? d.rightCommand
        maxTapDuration = try c.decodeIfPresent(Double.self, forKey: .maxTapDuration) ?? d.maxTapDuration
        inputSources = try c.decodeIfPresent([String: [String]].self, forKey: .inputSources) ?? d.inputSources
        sendKanaKey = try c.decodeIfPresent(Bool.self, forKey: .sendKanaKey) ?? d.sendKanaKey
        trace = try c.decodeIfPresent(Bool.self, forKey: .trace) ?? d.trace
        guard maxTapDuration > 0 else { throw Invalid(description: "maxTapDuration は 0 より大きい値にしてください") }
    }

    public static func parse(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    /// 設定ファイルの雛形 (`既定値そのもの`)。
    public func templateData() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}
