import Carbon
import Foundation
import KotokotoCore

/// 切り替えが「着く」までの時間を遷移ごとに測る診断 (`--bench`)。
enum Bench {
    /// 選択の呼び出しから (a) システムの切り替え通知、(b) 現在の入力ソースが狙いになるまで、を ms で出す。
    /// 入力先アプリの入力メソッドが実際に使えるようになるまでは測れない (通知より遅れることがある)。
    /// 測定中は入力ソースが何度も切り替わる。終わると元の入力ソースに戻す。
    static func run(runs: Int = 10) {
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

        let languages = Language.allCases.filter { InputSources.resolve($0, preferred: []) != nil }
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString) / \(runs) 回ずつ / 単位 ms")
        for l in languages { print("  \(l.displayName): \(InputSources.string(InputSources.resolve(l, preferred: [])!, kTISPropertyInputSourceID) ?? "?")") }
        var worstNotify = 0.0
        for from in languages {
            for to in languages where to != from {
                var notify: [Double] = [], arrive: [Double] = [], misses = 0
                guard let toSource = InputSources.resolve(to, preferred: []), let toID = InputSources.string(toSource, kTISPropertyInputSourceID) else { continue }
                for _ in 0..<runs {
                    _ = InputSources.select(from)
                    settle(400) // 前の切り替えが落ち着くのを待つ
                    notified = false
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    _ = InputSources.select(to)
                    if let n = wait(since: t0, limit: 1000, until: { notified }) { notify.append(n) } else { misses += 1 }
                    if let a = wait(since: t0, limit: 1000, until: { InputSources.currentID() == toID }) { arrive.append(a) }
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
}
