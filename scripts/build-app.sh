#!/usr/bin/env bash
# 构建 MeetingASR.app（仅 macOS / Apple Silicon）。
#
#   scripts/build-app.sh                       # ad-hoc 签名，本机使用
#   SIGN_IDENTITY="Developer ID Application: XXX (TEAMID)" scripts/build-app.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=<notarytool keychain profile> scripts/build-app.sh   # 签名 + 公证
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ "$(uname -s)" == "Darwin" ]] || { echo "需要在 macOS 上构建" >&2; exit 1; }

IDENTITY="${SIGN_IDENTITY:--}"
APP="$ROOT/dist/MeetingASR.app"

scripts/fetch-sherpa-onnx.sh
scripts/fetch-models.sh

swift build -c release --arch arm64 --product MeetingASR
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MeetingASR"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/MeetingASR"
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/models "$APP/Contents/Resources/models"
cp -a Vendor/sherpa-onnx/lib/*.dylib "$APP/Contents/Frameworks/"

# 依赖统一从 @rpath 加载
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  [[ -L "$lib" ]] && continue
  install_name_tool -id "@rpath/$(basename "$lib")" "$lib" 2>/dev/null || true
done
for dep in $(otool -L "$APP/Contents/MacOS/MeetingASR" | awk '/sherpa-onnx|onnxruntime/ {print $1}'); do
  install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$APP/Contents/MacOS/MeetingASR"
done
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  [[ -L "$lib" ]] && continue
  for dep in $(otool -L "$lib" | tail -n +2 | awk '/onnxruntime|sherpa-onnx/ {print $1}'); do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null || true
  done
done

# 签名：先库后 App，启用 Hardened Runtime
for lib in "$APP"/Contents/Frameworks/*.dylib; do
  [[ -L "$lib" ]] && continue
  codesign --force --timestamp=none --options runtime --sign "$IDENTITY" "$lib"
done
TS="--timestamp"; [[ "$IDENTITY" == "-" ]] && TS="--timestamp=none"
codesign --force $TS --options runtime --entitlements App/MeetingASR.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
  ZIP="$ROOT/dist/MeetingASR.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Notarized: $ZIP"
fi
