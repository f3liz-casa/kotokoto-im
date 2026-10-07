import Carbon
import CoreGraphics
import Foundation
import KotokotoCore

/// Text Input Source Services を使った入力ソースの選択。
enum InputSources {
    /// 優先して探す入力ソース ID。見つからなければ言語コードで探す。
    /// `skipSuffixes` は言語コードで探すときに除く入力モード (日本語入力のカタカナ・英数など)。
    private static let candidates: [Language: (ids: [String], lang: String, skipSuffixes: [String])] = [
        .english: (["com.apple.keylayout.ABC", "com.apple.keylayout.US"], "en", []),
        // 日本語: 標準の「日本語 - ローマ字入力」「かな入力」、Mozc (OSS 版)、Google 日本語入力。
        // 複数入れている場合は先に書いたものが優先。変えたいときは設定の inputSources で指定する。
        .japanese: (["com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                     "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese",
                     "org.mozc.inputmethod.Japanese.base",
                     "com.google.inputmethod.Japanese.base"], "ja",
                    ["Katakana", "HalfWidthKana", "HalfWidthKatakana", "FullWidthRoman", "Roman"]),
        .korean: (["com.apple.inputmethod.Korean.2SetKorean"], "ko", []),
    ]

    static func enabledSources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else { return [] }
        return list as? [TISInputSource] ?? []
    }

    static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func languages(_ source: TISInputSource) -> [String] {
        guard let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }

    /// 言語ごとの解決済み入力ソース。キー押下のたびに全入力ソースを列挙・照会すると遅いので覚えておく。
    /// 入力ソースの有効/無効が変わったとき・設定を読み直したときに `invalidate()` する。
    private static var cache: [Language: TISInputSource] = [:]

    static func invalidate() {
        cache.removeAll()
    }

    static func resolve(_ language: Language, preferred: [String]) -> TISInputSource? {
        if let hit = cache[language] { return hit }
        guard let spec = candidates[language] else { return nil }
        let sources = enabledSources()
        let byID = (preferred + spec.ids).lazy.compactMap { id in
            sources.first { string($0, kTISPropertyInputSourceID) == id }
        }.first
        let byLang = sources.first { source in
            guard languages(source).first == spec.lang else { return false }
            let id = string(source, kTISPropertyInputSourceID) ?? ""
            if spec.skipSuffixes.contains(where: { id.hasSuffix("." + $0) }) { return false }
            return language != .english || string(source, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String
        }
        let target = byID ?? byLang
        if let target = target { cache[language] = target } // 見つからなかった結果は覚えない (後から追加されうる)
        return target
    }

    static func currentID() -> String? {
        string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }

    /// 狙いの入力ソースが有効になっているか。
    static func isAvailable(_ language: Language, preferred: [String] = []) -> Bool {
        resolve(language, preferred: preferred) != nil
    }

    /// 狙いの入力ソースが現在の入力ソースか (切り替え後の確認用)。判断できなければ true。
    static func isCurrent(_ language: Language, preferred: [String] = []) -> Bool {
        guard let target = resolve(language, preferred: preferred),
              let id = string(target, kTISPropertyInputSourceID) else { return true }
        return id == currentID()
    }

    /// 入力ソースを選ぶ。成功なら nil、失敗なら利用者向けの説明を返す。
    /// `preferred` は設定ファイルで指定された ID (既定の候補より先に探す)。
    /// メインスレッドから呼ぶこと (TIS の要件)。
    static func select(_ language: Language, preferred: [String] = []) -> String? {
        guard candidates[language] != nil else { return nil }
        guard let target = resolve(language, preferred: preferred) else {
            return "\(language.displayName)の入力ソースが有効ではありません。システム設定 > キーボード > 入力ソース で追加してください。"
        }
        // すでにその入力ソースでも選び直す (表示と実際の入力がずれたとき、もう一度押して直せるように)
        if TISSelectInputSource(target) == noErr { return nil }
        invalidate() // 古い参照かもしれないので次回は引き直す
        return "\(language.displayName)への切り替えに失敗しました。"
    }

    /// 英数 (102) / かな (104) キーを送る (⌘英かな と同じ方式)。フラグは空。
    /// 切り替えは macOS が行う。入力メソッドが処理しないモードで送ると、制御文字 (U+0010) が入力されることがある。
    /// 目印を付けて、自分のタップがキーを預かってしまうのを避ける。
    static func postKey(_ code: CGKeyCode) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: isDown) else { return }
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.replayMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// 入力ソースの有効/無効が変わったら呼ばれる (システム設定での追加・削除)。
    static func observeChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { _ in invalidate() }
    }

    /// 有効な入力ソース ID を表示する (`--list`)。
    static func printEnabled() {
        for s in enabledSources() {
            print(string(s, kTISPropertyInputSourceID) ?? "?", languages(s).first ?? "-", separator: "\t")
        }
    }
}
