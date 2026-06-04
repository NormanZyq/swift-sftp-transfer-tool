#!/bin/bash
# 构建 release 二进制并组装成可双击的原生 .app。
# 自用：ad-hoc 签名即可；本机编译的程序无 quarantine 标记，Gatekeeper 不拦。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="SSH 文件传输"
APP="$APP_NAME.app"
EXEC="SFTPTransfer"
BUNDLE_ID="local.shyulatte.sftptransfer"
VERSION="1.0"
ICON="Resources/AppIcon.icns"

echo "→ 编译 release …"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$EXEC"
if [ ! -x "$BIN" ]; then
    echo "✗ 未找到二进制: $BIN" >&2
    exit 1
fi

echo "→ 组装 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXEC</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSUIElement</key><false/>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.shyulatte.sftptransfer.remote-item</string>
            <key>UTTypeDescription</key><string>SFTP remote item reference</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key><dict/>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "APPL????" > "$APP/Contents/PkgInfo"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"

if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "⚠ アイコン未検出: $ICON（Resources/make-icon.sh で生成できます）" >&2
fi

echo "→ ad-hoc 签名 …"
codesign --force --sign - "$APP"

echo "✓ 完成: $SCRIPT_DIR/$APP"
echo "  双击运行，或拖到 /Applications。"
