import Carbon
import KotokotoCore

/// Text Input Source Services を使った入力ソースの選択。
enum InputSources {
    /// 優先して探す入力ソース ID。見つからなければ言語コードで探す。
    private static let candidates: [Language: (ids: [String], lang: String)] = [
        .english: (["com.apple.keylayout.ABC", "com.apple.keylayout.US"], "en"),
        .japanese: (["com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                     "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese"], "ja"),
        .korean: (["com.apple.inputmethod.Korean.2SetKorean"], "ko"),
    ]

    private static func enabledSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        return list as? [TISInputSource] ?? []
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }

    @discardableResult
    static func select(_ language: Language) -> Bool {
        guard let spec = candidates[language] else { return false }
        let sources = enabledSources()
        let byID = spec.ids.lazy.compactMap { id in
            sources.first { string($0, kTISPropertyInputSourceID) == id }
        }.first
        let byLang = sources.first {
            languages($0).first == spec.lang
                && (language != .english || string($0, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String)
        }
        guard let target = byID ?? byLang else {
            fputs("kotokoto-im: \(language) の入力ソースが有効になっていません (システム設定 > キーボード > 入力ソース)\n", stderr)
            return false
        }
        return TISSelectInputSource(target) == noErr
    }

    /// 有効な入力ソース ID を表示する (`--list`)。
    static func printEnabled() {
        for s in enabledSources() {
            print(string(s, kTISPropertyInputSourceID) ?? "?", languages(s).first ?? "-", separator: "\t")
        }
    }
}
