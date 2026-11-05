#!/bin/zsh
# 构建 WindowDeck.app 到 build/ 目录。
#   CONFIG=debug|release（默认 release）
#   SIGN_IDENTITY：codesign 签名身份，默认 "WindowDeck Signing"（钥匙串中的自签名代码签名证书，
#     公钥证书备份在 certs/，私钥只在钥匙串中）。传 "-" 使用 ad-hoc 签名。
#     ad-hoc 签名每次构建后签名都会变，系统会把它当成新应用，辅助功能 / 屏幕录制权限需要重新授权。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-WindowDeck Signing}"
cd "$ROOT"

if [[ "$SIGN_IDENTITY" != "-" ]] && ! security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\""; then
  echo "error: 钥匙串中找不到代码签名身份 \"$SIGN_IDENTITY\"（需要证书 + 私钥）。" >&2
  echo "       可改用 SIGN_IDENTITY=- 进行 ad-hoc 签名。" >&2
  exit 1
fi

# CommandLineTools 工具链下新的 swift-build 后端无法初始化，使用 native 后端。
swift build --build-system native -c "$CONFIG" --product WindowDeck
BIN_DIR="$(swift build --build-system native -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/WindowDeck.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN_DIR/WindowDeck" "$APP/Contents/MacOS/WindowDeck"
cp -f "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# 本地化资源（*.lproj）。源码中的文案即简体中文，en.lproj 提供英文翻译。
cp -R "$ROOT/Support/Resources/." "$APP/Contents/Resources/"

codesign --force --options runtime \
  --entitlements "$ROOT/Support/WindowDeck.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (config=$CONFIG, identity=$SIGN_IDENTITY)"
