import Carbon
import Foundation
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

    /// 言語ごとの解決済み入力ソース。キー押下のたびに全入力ソースを列挙・照会すると遅いので覚えておく。
    /// 入力ソースの有効/無効が変わったとき・設定を読み直したときに `invalidate()` する。
    private static var cache: [Language: TISInputSource] = [:]

    static func invalidate() {
        cache.removeAll()
    }

    private static func resolve(_ language: Language, preferred: [String]) -> TISInputSource? {
        if let hit = cache[language] { return hit }
        guard let spec = candidates[language] else { return nil }
        let sources = enabledSources()
        let byID = (preferred + spec.ids).lazy.compactMap { id in
            sources.first { string($0, kTISPropertyInputSourceID) == id }
        }.first
        let byLang = sources.first {
            languages($0).first == spec.lang
                && (language != .english || string($0, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String)
        }
        let target = byID ?? byLang
        if let target = target { cache[language] = target } // 見つからなかった結果は覚えない (後から追加されうる)
        return target
    }

    private static func currentID() -> String? {
        string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }

    /// 入力ソースを選ぶ。成功なら nil、失敗なら利用者向けの説明を返す。
    /// `preferred` は設定ファイルで指定された ID (既定の候補より先に探す)。
    /// メインスレッドから呼ぶこと (TIS の要件)。
    static func select(_ language: Language, preferred: [String] = []) -> String? {
        guard candidates[language] != nil else { return nil }
        guard let target = resolve(language, preferred: preferred) else {
            return "\(language.displayName)の入力ソースが有効ではありません。システム設定 > キーボード > 入力ソース で追加してください。"
        }
        // すでにそれなら何もしない (無駄な切り替え処理を避ける)
        if let id = string(target, kTISPropertyInputSourceID), id == currentID() { return nil }
        if TISSelectInputSource(target) == noErr { return nil }
        invalidate() // 古い参照かもしれないので次回は引き直す
        return "\(language.displayName)への切り替えに失敗しました。"
    }

    /// 入力ソースの有効/無効が変わったら呼ばれる (システム設定での追加・削除)。
    static func observeChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { _ in invalidate() }
    }

    /// 切り替え時間を測る (`--bench`)。キャッシュ無し(初回)と有り(2回目以降)を比べる。終わると元の入力ソースに戻す。
    static func bench() {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        func ms(_ body: () -> Void) -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        for lang in [Language.english, .japanese, .korean, .english, .japanese, .korean] {
            // 毎回別の入力ソースへ切り替わるよう、順に回す
            var err: String?
            let cold = ms { invalidate(); err = select(lang) }
            if let err = err { print("\(lang.displayName): \(err)"); continue }
            invalidate(); _ = resolve(lang, preferred: [])
            let resolveWarm = ms { _ = resolve(lang, preferred: []) }
            print("\(lang.displayName): 切り替え(キャッシュ無し) \(String(format: "%.2f", cold)) ms / 引き当て(キャッシュ有り) \(String(format: "%.3f", resolveWarm)) ms")
        }
        TISSelectInputSource(original)
    }

    /// 有効な入力ソース ID を表示する (`--list`)。
    static func printEnabled() {
        for s in enabledSources() {
            print(string(s, kTISPropertyInputSourceID) ?? "?", languages(s).first ?? "-", separator: "\t")
        }
    }
}
