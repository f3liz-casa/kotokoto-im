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

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/kotokoto-im"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/kotokoto-im"
cp packaging/Info.plist "$APP/Contents/Info.plist"

# 署名しないと権限の許可が安定しない。指定が無ければ ad-hoc 署名 (ビルドごとに署名が変わるので、
# 再ビルド後は許可をやり直す必要がある。固定したい場合は自分の証明書名を CODESIGN_IDENTITY に)。
codesign --force --sign "${CODESIGN_IDENTITY:--}" --identifier casa.f3liz.kotokoto-im "$APP"

echo "できました: $APP"
echo "起動: open $APP"
