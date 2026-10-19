#!/bin/zsh
# xcodebuild 로 패키지를 빌드한 뒤 최소 .app 번들로 감싸서 실행한다.
# - swift build 는 .xcassets 를 컴파일하지 않아 라이브러리 글자색이 전부 비어 보인다.
# - 번들 없는 실행 파일은 Dock·메뉴·접근성 인벤토리에 정상 노출되지 않는다.
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -scheme MarkdownSpike -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode -skipMacroValidation -quiet build

BUILD_DIR=".build/xcode/Build/Products/Debug"
APP_DIR="$BUILD_DIR/MarkdownSpike.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/MarkdownSpike" "$APP_DIR/Contents/MacOS/MarkdownSpike"

# 리소스 번들을 Contents/Resources 로 복사한다. Bundle.module 은 Bundle.main.resourceURL 을 먼저 본다.
for bundle in "$BUILD_DIR"/*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MarkdownSpike</string>
  <key>CFBundleIdentifier</key><string>com.lavumi.galpi.markdownspike</string>
  <key>CFBundleName</key><string>MarkdownSpike</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# open 대신 직접 실행해 환경 변수(SPIKE_AUTOSTART 등)와 stderr 로그를 그대로 넘긴다.
exec "$APP_DIR/Contents/MacOS/MarkdownSpike"
