#!/bin/zsh
# project.yml 로 Xcode 프로젝트를 만들고(필요할 때만) Galpi.app 을 빌드해 실행한다.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-Debug}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen 이 필요합니다: brew install xcodegen" >&2
  exit 1
fi
if [[ ! -d Galpi.xcodeproj || project.yml -nt Galpi.xcodeproj ]]; then
  xcodegen generate --quiet
fi

BUILD_LOG="$(mktemp -t galpi-xcodebuild.XXXXXX)"
if ! xcodebuild -project Galpi.xcodeproj -scheme Galpi -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode \
  -skipMacroValidation -quiet build >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG"
  rm -f "$BUILD_LOG"
  exit 1
fi
rm -f "$BUILD_LOG"

APP_DIR=".build/xcode/Build/Products/$CONFIG/Galpi.app"

if [[ "${GALPI_NO_LAUNCH:-}" == "1" ]]; then
  echo "built: $APP_DIR"
  exit 0
fi

# 같은 번들의 앱이 이미 실행 중이면 macOS 가 두 번째 직접 실행을 SIGKILL 할 수 있다.
# 기존 인스턴스를 활성화하고 새 프로세스는 만들지 않는다.
if pgrep -f -x "$PWD/$APP_DIR/Contents/MacOS/Galpi" >/dev/null 2>&1; then
  open "$APP_DIR"
  echo "already running: $APP_DIR"
  exit 0
fi
exec "$APP_DIR/Contents/MacOS/Galpi"
