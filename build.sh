#!/bin/bash
# Собирает ClaudeHUD.app под этот Мак (UNIVERSAL=1 — под Apple Silicon + Intel).
# Использование: ./build.sh            → build/ClaudeHUD.app
#                ./build.sh install    → ещё и копирует в /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/ClaudeHUD.app
VERSION="${VERSION:-0.1.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # Под Apple Silicon и Intel сразу (используется в GitHub Actions).
  # Собираем каждую архитектуру отдельно и склеиваем — так не нужен полный Xcode.
  for ARCH in arm64 x86_64; do
    swift build -c release --triple "$ARCH-apple-macosx13.0"
  done
  lipo -create \
    ".build/arm64-apple-macosx13.0/release/ClaudeHUD" \
    ".build/x86_64-apple-macosx13.0/release/ClaudeHUD" \
    -output "$APP/Contents/MacOS/ClaudeHUD"
else
  # Только под этот Мак — работает с одними Command Line Tools
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/ClaudeHUD" "$APP/Contents/MacOS/ClaudeHUD"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeHUD</string>
  <key>CFBundleDisplayName</key><string>Claude HUD</string>
  <key>CFBundleIdentifier</key><string>io.github.claudehud</string>
  <key>CFBundleExecutable</key><string>ClaudeHUD</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc подпись, чтобы macOS вообще согласилась запустить
codesign --force --deep --sign - "$APP"
echo "✓ Собрано: $APP"

if [[ "${1:-}" == "install" ]]; then
  rm -rf /Applications/ClaudeHUD.app
  cp -R "$APP" /Applications/
  echo "✓ Установлено в /Applications"
  open /Applications/ClaudeHUD.app
fi
