#!/bin/zsh
# 由 Support/AppIcon/ 下的 SVG 生成图标资源：
#   AppIcon.svg     -> Support/Resources/AppIcon.icns（应用图标）
#   MenuBarIcon.svg -> Support/Resources/MenuBarIcon.pdf（菜单栏模板图标，矢量）
# 依赖：rsvg-convert（brew install librsvg）、iconutil（系统自带）。
# 生成的资源已入库，日常构建不需要运行此脚本；只有修改 SVG 后才需要重新生成。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Support/AppIcon/AppIcon.svg"
OUT="$ROOT/Support/Resources/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null; then
  echo "error: 找不到 rsvg-convert，请先 brew install librsvg。" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" -h "$((size * 2))" "$SRC" -o "$ICONSET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICONSET" -o "$OUT"
echo "Generated $OUT"

MENU_SRC="$ROOT/Support/AppIcon/MenuBarIcon.svg"
MENU_OUT="$ROOT/Support/Resources/MenuBarIcon.pdf"
rsvg-convert -f pdf "$MENU_SRC" -o "$MENU_OUT"
echo "Generated $MENU_OUT"
