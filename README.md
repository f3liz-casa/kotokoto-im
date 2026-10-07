# kotokoto-im

macOS の入力ソースを 1 キーで切り替える、メニューバー常駐ツール。
[gksdud](https://github.com/codingnoye/gksdud)(Caps Lock の差し替え)と
[cmd-eikana](https://github.com/dominion525/cmd-eikana)(⌘ 単独タップ)の方式を組み合わせたもの。

| キー(既定) | 動作 |
| --- | --- |
| Caps Lock | 韓国語 |
| 左 ⌘ 単独タップ | 英語 |
| 右 ⌘ 単独タップ | 日本語 |

⌘+C などのショートカット、⌘+クリック、長押し(既定 0.5 秒超)、両⌘同時押しでは切り替わりません。

## 親切とは

このツールで「親切」は次の意味で使い、設計の判断基準にします。

- 安定して使える。
- 存在を気にせず、自然に使える。
- 必要なときは自分を隠さない。
- 必要な情報は説明し、必要ない情報は言わない。
- 何かを変えたいとき、人に聞きやすくなっている。

これが実装でどうなっているか:

| 基準 | 実装 |
| --- | --- |
| 安定 | イベントタップが動いてから Caps Lock を差し替える(動かないのに Caps Lock だけ死なない)。正常終了・Ctrl-C・kill・ログアウトで元に戻す。強制終了で残っても `--reset` で戻せる。システムにタップを止められたら自動で復帰する。 |
| 自然 | 普段は「言」とだけ表示し、通知もダイアログも出さない。権限の許可後は再起動不要(自動で検知)。 |
| 隠さない | 問題があるときだけ「言⚠」になり、メニューに理由と次の一手(設定画面を開く、入力ソースを追加する、など)を出す。 |
| 情報の出し方 | 正常時のメニューは現在の割り当てを 1 行だけ。ログや統計は出さない。 |
| 変えやすさ | 設定は JSON 1 ファイル。メニューの「設定ファイルを開く」で既定値入りの雛形が作られ、「設定を再読み込み」で反映される。 |

## 使い方

```sh
scripts/bundle.sh                     # build/kotokoto-im.app を作る (Dock に出ないアプリとして動く)
open build/kotokoto-im.app            # 起動 (メニューバーに「言」)
CONFIG=debug scripts/bundle.sh        # 確認用の debug ビルド (速い)
```

コマンドライン用の操作は .app の中の実行ファイルで行います(`swift build` した `.build/release/kotokoto-im` でも同じ)。

```sh
APP=build/kotokoto-im.app/Contents/MacOS/kotokoto-im
$APP --list     # 有効な入力ソース ID の確認
$APP --bench    # 切り替えが着くまでの時間を遷移ごとに測る (docs/ime-delay.md)
$APP --reset    # 強制終了で残った Caps Lock の割り当てを戻す
swift test
```

`scripts/bundle.sh` は ad-hoc 署名をするので、再ビルドすると許可をやり直すことがあります(`CODESIGN_IDENTITY` に自分の証明書名を渡すと固定できます)。

### 再ビルドしたら許可が効かなくなったとき

macOS は許可を「アプリの署名」に結び付けています。ad-hoc 署名は再ビルドのたびに変わるので、設定の一覧でオンのままでも、新しいビルドは許可されていない扱いになります。

1. システム設定 > プライバシーとセキュリティ > アクセシビリティ で kotokoto-im を削除(−)し、`build/kotokoto-im.app` を追加し直す。
   または `tccutil reset Accessibility casa.f3liz.kotokoto-im` を実行してから起動する。
2. 繰り返したくない場合は、自分用のコード署名証明書を作って署名を固定する。
   キーチェーンアクセス > 証明書アシスタント > 証明書を作成… で、種類を「コード署名」にして作り、`CODESIGN_IDENTITY="作った証明書の名前" scripts/bundle.sh` でビルドする。

初回起動時に **アクセシビリティ**(場合により **入力監視**)の許可が必要です。メニューのリンクから設定画面を開けます。
システム設定 > キーボード > 入力ソース で、英語(ABC/US)・日本語(ローマ字入力、または Mozc / Google 日本語入力)・韓国語(2 セット)を追加しておいてください。日本語の入力ソースを複数入れている場合は、標準の日本語入力 → Mozc → Google 日本語入力の順に使います。Mozc を優先したいときは設定の `inputSources` で指定します(下記)。

## 速さ

Caps Lock を押してから切り替わるまでの経路で、次のことをしています。

- Caps Lock を F18 に差し替え、OS の Caps Lock 特有の遅延(短押しの無視など)を通らない。
- 押すたびに入力ソースを全部列挙して照会するのをやめ、言語ごとに解決した入力ソースを覚える。有効な入力ソースが変わったとき・設定を読み直したときに引き直す。
- 切り替え直後〜入力先が使えるようになるまでの短い間(通知から約 30 ms、最長 0.3 秒)に打ったキーを預かり、準備ができてから元の順序で送り直す。macOS は入力ソースの切り替えを通知してから、入力先アプリの入力メソッドが実際に使えるようになるまで少し間があり、その間のキーは切り替え前の入力ソースに届くため(gksdud と同じ対策)。
- 切り替え要求の経路ではメニュー更新などをしない(警告が変わったときだけ更新)。

切り替えが着くまでの時間は `--bench` で遷移ごとに測れます。OS 側の切り替え(`TISSelectInputSource`)自体の時間はこのツールでは縮められません。遅延の調査メモは [docs/ime-delay.md](docs/ime-delay.md)。

## 設定

`~/.config/kotokoto-im/config.json`(無くても既定値で動きます。書かない項目は既定値)

```json
{
  "capsLock": "korean",
  "leftCommand": "english",
  "rightCommand": "japanese",
  "maxTapDuration": 0.5,
  "inputSources": { "japanese": ["org.mozc.inputmethod.Japanese.base"] },
  "trace": false
}
```

- `capsLock` / `leftCommand` / `rightCommand`: `english` `japanese` `korean` `none`。`capsLock` を `none` にすると Caps Lock の差し替え自体を行いません。
- `maxTapDuration`: ⌘ をこの秒数より長く押すとタップとみなしません。
- `inputSources`: 言語ごとに優先する入力ソース ID(`--list` で確認)。
- `englishMethod` / `japaneseMethod`(実験的、`inputSource` か `key`、既定 `inputSource`): `key` にすると、入力ソースを直接選ばず、英数 / かなキーのイベントを送って macOS に切り替えを任せます([⌘英かな](https://github.com/dominion525/cmd-eikana) と同じ方式)。すでに狙いの入力ソースのときは何も送りません。60 ms 経っても切り替わっていなければ、入力ソースを直接選び直します。英数キーは、日本語入力(Mozc など)が処理して「直接入力」になるだけで、キー配列(Dvorak など)の入力ソースには変わらないことがあるため、`englishMethod` は様子を見てから使ってください。
- `trace`(診断用、既定 `false`): 切り替えの要求・実行・通知・確認の時刻と現在の入力ソース、およびキー入力の時刻と入力ソース(どのキーかは記録しません)を `~/Library/Logs/kotokoto-im.log` に書きます。「表示と入力がずれる」ような問題の報告に使えます。設定を再読み込みすると有効になります。

## 仕組み

- Caps Lock は `hidutil` で F18 に差し替え、イベントタップで F18 を検出して消費します(遅延・取りこぼし対策)。
- ⌘ は `flagsChanged` の左右別ビットで押下/解放を追い、間に他の入力が無ければタップとみなします(`Sources/KotokotoCore`)。
- 切り替えは `TISSelectInputSource` で行います。

注意: 差し替えの解除は `hidutil` の `UserKeyMapping` を空にするため、他で設定した独自のキー割り当ては消えます。
