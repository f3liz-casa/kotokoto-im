#!/bin/bash
# kotokoto-im.app を作る。ターミナルの子プロセスではなく独立したアプリとして動かすため
# (アクセシビリティ等の許可がターミナルではなくこのアプリに付く / Dock に出ない)。
#
#   scripts/bundle.sh                 # release ビルド → build/kotokoto-im.app
#   CONFIG=debug scripts/bundle.sh    # debug ビルド (確認用。ビルドが速い)
#   CODESIGN_IDENTITY="Apple Development: ..." scripts/bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/kotokoto-im.app"

# SWIFT_BUILD_FLAGS: Homebrew のサンドボックス内では --disable-sandbox が要る (SwiftPM が入れ子で sandbox-exec を使えないため)
# shellcheck disable=SC2086
swift build -c "$CONFIG" ${SWIFT_BUILD_FLAGS:-}
# shellcheck disable=SC2086
BIN="$(swift build -c "$CONFIG" ${SWIFT_BUILD_FLAGS:-} --show-bin-path)/kotokoto-im"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/kotokoto-im"
cp packaging/Info.plist "$APP/Contents/Info.plist"
# メニューに出すビルド番号。どのコミットから作ったかが分かるように git の短いハッシュを入れる
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD 2>/dev/null || echo dev)" "$APP/Contents/Info.plist"

# 署名しないと権限の許可が安定しない。指定が無ければ ad-hoc 署名。
# designated requirement を識別子だけにしておくと、再ビルドしても同じアプリと見なされ、許可が引き継がれる
# (cdhash ではなく識別子で照合されるため)。CODESIGN_IDENTITY を渡すと、その証明書で署名する。
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --sign - --identifier casa.f3liz.kotokoto-im \
        -r='designated => identifier "casa.f3liz.kotokoto-im"' "$APP"
else
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier casa.f3liz.kotokoto-im "$APP"
fi

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "注意: ad-hoc 署名です (designated requirement は識別子 casa.f3liz.kotokoto-im のみ)。"
    echo "      許可が効かなくなったときは、設定の一覧から kotokoto-im を削除(−)して追加し直すか、次を実行:"
    echo "        tccutil reset Accessibility casa.f3liz.kotokoto-im"
    echo "      (README 参照)"
fi
echo "できました: $APP"
echo "起動: open $APP"
