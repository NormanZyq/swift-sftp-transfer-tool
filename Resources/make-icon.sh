#!/bin/bash
# icon.swift でアイコンを描画し、各サイズを生成して AppIcon.icns にまとめる。
# 出力: Resources/AppIcon.icns（make-app.sh がこれをバンドルに入れる）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PNG="$(mktemp -t appicon).png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "→ アイコンを描画 …"
swift icon.swift "$PNG"

echo "→ 各サイズを生成 …"
sips -z 16 16     "$PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$PNG" "$ICONSET/icon_512x512@2x.png"

echo "→ icns にまとめる …"
iconutil -c icns "$ICONSET" -o "$SCRIPT_DIR/AppIcon.icns"

rm -f "$PNG"
rm -rf "$(dirname "$ICONSET")"
echo "✓ 完成: $SCRIPT_DIR/AppIcon.icns"
