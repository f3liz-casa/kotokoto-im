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

    /// 「かな」キー (JIS キーボードのかなキー、kVK_JIS_Kana) を送る。
    /// 日本語入力が有効なときだけ送ること。入力ソースが日本語入力でないと、キーは消費されず
    /// アプリに制御文字 (U+0010) として入力されてしまう。
    static func postKanaKey() {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 104, keyDown: isDown) else { return }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }
    }

    /// 入力ソースの有効/無効が変わったら呼ばれる (システム設定での追加・削除)。
    static func observeChanges() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { _ in invalidate() }
    }

    /// 切り替えが「着く」までの時間を、遷移ごとに測る (`--bench`)。
    /// 選択の呼び出しから (a) システムの切り替え通知、(b) 現在の入力ソースが狙いになるまで、を ms で出す。
    /// 入力先アプリの入力メソッドが実際に使えるようになるまでは測れない (通知より遅れることがある)。
    /// 測定中は入力ソースが何度も切り替わる。終わると元の入力ソースに戻す。
    static func bench(runs: Int = 10) {
        let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        var notified = false
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: nil) { _ in notified = true }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        func elapsed(since t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        /// 実行ループを回しながら、条件が満たされるまで待つ。満たされた時刻 (t0 からの ms)、時間切れなら nil。
        func wait(since t0: UInt64, limit: Double, until done: () -> Bool) -> Double? {
            while true {
                if done() { return elapsed(since: t0) }
                if elapsed(since: t0) > limit { return nil }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }
        func settle(_ ms: Double) { _ = wait(since: DispatchTime.now().uptimeNanoseconds, limit: ms) { false } }
        func stats(_ values: [Double]) -> String {
            guard !values.isEmpty else { return "-" }
            let v = values.sorted()
            let p95 = v[min(v.count - 1, Int((Double(v.count) * 0.95).rounded(.up)) - 1)]
            return String(format: "最小 %.0f / 中央 %.0f / p95 %.0f / 最大 %.0f", v[0], v[v.count / 2], p95, v[v.count - 1])
        }

        let languages = Language.allCases.filter { resolve($0, preferred: []) != nil }
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) / \(runs) 回ずつ / 単位 ms")
        for l in languages { print("  \(l.displayName): \(string(resolve(l, preferred: [])!, kTISPropertyInputSourceID) ?? "?")") }
        var worstNotify = 0.0
        for from in languages {
            for to in languages where to != from {
                var notify: [Double] = [], arrive: [Double] = [], misses = 0
                guard let toSource = resolve(to, preferred: []), let toID = string(toSource, kTISPropertyInputSourceID) else { continue }
                for _ in 0..<runs {
                    _ = select(from)
                    settle(400) // 前の切り替えが落ち着くのを待つ
                    notified = false
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = select(to)
                    if let n = wait(since: t0, limit: 1000, until: { notified }) { notify.append(n) } else { misses += 1 }
                    if let a = wait(since: t0, limit: 1000, until: { currentID() == toID }) { arrive.append(a) }
                }
                if let w = notify.max() { worstNotify = max(worstNotify, w) }
                print("\(from.displayName)→\(to.displayName)")
                print("  通知      : \(stats(notify))" + (misses > 0 ? "  (通知なし \(misses) 回)" : ""))
                print("  現在に反映: \(stats(arrive))")
            }
        }
        TISSelectInputSource(original)
        if worstNotify > 0 {
            print(String(format: "通知の最大 %.0f ms。余裕 30 ms を足すと、約 %.0f ms 待てばこの環境では全遷移で着く計算です。",
                         worstNotify, ((worstNotify + 30) / 10).rounded(.up) * 10))
        }
    }

    /// 有効な入力ソース ID を表示する (`--list`)。
    static func printEnabled() {
        for s in enabledSources() {
            print(string(s, kTISPropertyInputSourceID) ?? "?", languages(s).first ?? "-", separator: "\t")
        }
    }
}
