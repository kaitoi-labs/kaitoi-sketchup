#!/usr/bin/env bash
# Package the extension as a .rbz for Window > Extension Manager.
# An .rbz is a zip; SketchUp unpacks it into the user's Plugins folder, so the
# archive must hold the registration file and its folder at the top level.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(ruby -e "require './kaitoi_sketchup/version'; print Kaitoio::VERSION")
OUT="build/kaitoi_sketchup-${VERSION}.rbz"

rm -rf build
mkdir -p build
zip -qr "$OUT" kaitoi_sketchup.rb kaitoi_sketchup -x '*.DS_Store' -x '__MACOSX*'

echo "built $OUT"
echo "contents:"
unzip -Z1 "$OUT" | head -4 | sed 's/^/  /'
echo "  ... $(unzip -Z1 "$OUT" | wc -l | tr -d ' ') entries"
