#!/bin/bash
# 一键打包成 GzhWriter.app（需要 Xcode 或 Command Line Tools：xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

# UNIVERSAL=1 ./build.sh 可同时编译 Apple 芯片 + Intel（需要完整 Xcode）
FLAGS=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/GzhWriter"

APP="build/GzhWriter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GzhWriter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 由 1024px PNG 生成 .icns 图标
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) Resources/AppIcon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# 固定签名要求：只认 Bundle ID，覆盖安装新版后钥匙串里的 API Key 仍可读取
codesign --force --deep --sign - \
    --identifier com.keovi.GzhWriter \
    -r='designated => identifier "com.keovi.GzhWriter"' \
    "$APP"

echo "✅ 已生成 $APP"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/GzhWriter.app
    cp -R "$APP" /Applications/
    echo "✅ 已安装到 /Applications，正在启动…"
    open /Applications/GzhWriter.app
fi
