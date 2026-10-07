# kotokoto-im

macOS の入力ソースを 1 キーで切り替える常駐ツール。
[gksdud](https://github.com/codingnoye/gksdud)(Caps Lock の差し替え)と
[cmd-eikana](https://github.com/dominion525/cmd-eikana)(⌘ 単独タップ)の方式を組み合わせたもの。

| キー | 動作 |
| --- | --- |
| Caps Lock | 韓国語 |
| 左 ⌘ 単独タップ | 英語 |
| 右 ⌘ 単独タップ | 日本語 |

⌘+C などのショートカット、⌘+クリック、長押し(0.5 秒超)、両⌘同時押しでは切り替わりません。

## 仕組み

- Caps Lock は起動時に `hidutil` で F18 に差し替え、イベントタップで F18 を検出して消費します(遅延・取りこぼし対策。終了時に元へ戻します)。
- ⌘ は `flagsChanged` の左右別ビットで押下/解放を追い、間に他の入力が無ければタップとみなします(`Sources/KotokotoCore`)。
- 切り替えは Text Input Source Services (`TISSelectInputSource`) で行います。

## 使い方

```sh
swift build -c release
.build/release/kotokoto-im            # 起動 (メニューバーに「言」)
.build/release/kotokoto-im --list     # 有効な入力ソース ID の確認
swift test                            # TapDetector のテスト
```

初回起動時に **アクセシビリティ**(必要なら **入力監視**)の許可が必要です。
システム設定 > キーボード > 入力ソース で、英語(ABC/US)・日本語(ローマ字入力)・韓国語(2 セット)を追加しておいてください。

注意: 終了時に `hidutil` の `UserKeyMapping` を空にするため、他で設定した独自のキー割り当ては消えます。
