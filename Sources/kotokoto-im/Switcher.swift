import Carbon
import Foundation
import KotokotoCore

/// 切り替え要求を、実際の切り替えにする。
///
/// 1. 間隔が近い要求はまとめる (続けて 2 回選ぶと、最初の選択が落ちることがあるため)。
/// 2. 設定に従い、キー (英数 / かな) か入力ソースの選択で切り替える。
/// 3. 切り替えが入力先に届くまで、打たれたキーを `EventTap` に預からせる。
/// 4. 少し待って、狙いの入力ソースになっているか確かめ、なっていなければ選び直す。
///
/// 入力ソース (TIS) の操作は、メインスレッドで行う。
final class Switcher {
    var config = Config()
    /// 動いているタップ (キーを預かるために使う)。持ち主は `Controller`。
    weak var tap: EventTap?
    /// 切り替えの結果の警告 (成功なら nil)。
    var onWarning: (String?) -> Void = { _ in }

    private let settleInterval = 0.08  // これより短い間隔の要求はまとめる (秒)
    private let verifyDelay = 0.06     // 切り替え後にこの時間待って確認する (秒)
    private let landingDelay = 0.03    // 切り替えの通知から、入力先が使えるようになるまでの余裕 (秒)
    private let holdTimeout = 0.3      // 通知が来なくても、キーを預かるのはこの時間まで (秒)

    private var lastSwitchAt = DispatchTime(uptimeNanoseconds: 0)
    private var pendingSwitch: DispatchWorkItem?
    private var switchGeneration = 0   // 切り替えのたびに進める。古い確認を無効にする
    private var holdGeneration = 0     // キーを預かるたびに進める。古い時間切れを無効にする
    private var holdTarget: (language: Language, preferred: [String])?

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.inputSourceChanged() }
    }

    /// 切り替え要求。間隔が空いているときは、待たずに即座に切り替える。
    func request(_ language: Language) {
        pendingSwitch?.cancel()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - lastSwitchAt.uptimeNanoseconds) / 1e9
        Trace.log("要求 \(language.displayName) (前の切り替えから \(Int(elapsed * 1000)) ms\(elapsed >= settleInterval ? "" : "、待って実行"))")
        if elapsed >= settleInterval {
            perform(language)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.perform(language) }
        pendingSwitch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (settleInterval - elapsed), execute: work)
    }

    /// 待っている処理をすべて取り消し、預かっているキーを返す (タップを止める前に呼ぶ)。
    func cancelAll() {
        pendingSwitch?.cancel()
        pendingSwitch = nil
        switchGeneration += 1
        holdGeneration += 1
        holdTarget = nil
        tap?.endHold()
    }

    // MARK: - 切り替え

    private func perform(_ language: Language) {
        lastSwitchAt = DispatchTime.now()
        switchGeneration += 1
        let token = switchGeneration
        let preferred = config.inputSources[language.rawValue] ?? []
        let willChange = !InputSources.isCurrent(language, preferred: preferred)
        Trace.log("実行 \(language.displayName): 現在=\(InputSources.currentID() ?? "?") 切り替わる=\(willChange)")

        let failure = switchNow(language, preferred: preferred, willChange: willChange)
        onWarning(failure)
        guard failure == nil else { return }
        if willChange { holdKeys(until: language, preferred: preferred) }
        verify(language, preferred: preferred, token: token)
    }

    /// 切り替えを実行する。成功なら nil、失敗なら利用者向けの説明を返す。
    private func switchNow(_ language: Language, preferred: [String], willChange: Bool) -> String? {
        // 入力ソースが有効でないときは、キーを送らずに入力ソースを選んで、利用者向けの説明を出す
        if config.method(for: language) == .key && InputSources.isAvailable(language, preferred: preferred) {
            // すでに狙いの入力ソースなら何もしない (処理されないキーは文字として入力されるため)
            if willChange {
                InputSources.postKey(language == .english ? 102 : 104)
                Trace.log("キー送信: \(language == .english ? "英数" : "かな")")
            }
            return nil
        }
        let failure = InputSources.select(language, preferred: preferred)
        Trace.log("select 結果: \(failure ?? "OK") 現在=\(InputSources.currentID() ?? "?")")
        return failure
    }

    /// 少し待って、狙いの入力ソースになっているか確かめる。なっていなければ、一度だけ選び直す
    /// (キー方式では、macOS が切り替えなかったときの代わりにもなる)。間に別の切り替えが入っていたら何もしない。
    private func verify(_ language: Language, preferred: [String], token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay) { [weak self] in
            guard let self = self, self.switchGeneration == token else { return }
            let ok = InputSources.isCurrent(language, preferred: preferred)
            Trace.log("確認 (+\(Int(self.verifyDelay * 1000)) ms): 現在=\(InputSources.currentID() ?? "?") 一致=\(ok)")
            guard !ok else { return }
            // 覚えていた参照が古くて効いていない可能性があるので、引き直してから選び直す
            InputSources.invalidate()
            let retry = InputSources.select(language, preferred: preferred)
            Trace.log("選び直し: \(retry ?? "OK")")
        }
    }

    // MARK: - 切り替え中のキーの預かり

    /// macOS は切り替えを通知してから、入力先アプリの入力メソッドが使えるようになるまで少し間があり、
    /// その間のキーは切り替え前の入力ソースに届く。通知を待ち、`landingDelay` だけ余裕をみて返す。
    /// 通知が来なくても `holdTimeout` で必ず返す。
    private func holdKeys(until language: Language, preferred: [String]) {
        tap?.beginHold()
        Trace.log("キーを預かり始める")
        holdTarget = (language, preferred)
        holdGeneration += 1
        let token = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + holdTimeout) { [weak self] in
            guard let self = self, self.holdGeneration == token else { return }
            self.releaseHeldKeys("時間切れ")
        }
    }

    /// 預かったキーを返す。
    private func releaseHeldKeys(_ reason: String) {
        guard holdTarget != nil else { return } // 二重に呼ばれても一度だけ
        holdTarget = nil
        let count = tap?.endHold() ?? 0
        Trace.log("キーを返す (\(reason)): \(count) 件")
    }

    /// 入力ソースが切り替わった通知。狙いどおりなら、入力先の準備を少し待ってから預かったキーを返す。
    private func inputSourceChanged() {
        Trace.log("通知: 入力ソース変更 現在=\(InputSources.currentID() ?? "?")")
        guard let target = holdTarget,
              InputSources.isCurrent(target.language, preferred: target.preferred) else { return }
        let token = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + landingDelay) { [weak self] in
            guard let self = self, self.holdGeneration == token else { return }
            self.releaseHeldKeys("切り替え確認")
        }
    }
}
