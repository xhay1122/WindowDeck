#!/bin/zsh
# 运行 WindowDeckCore 单元测试（Swift Testing）。
# 使用 CommandLineTools 工具链时，新的 swift-build 后端无法初始化，native 后端又找不到 Testing.framework，
# 这里显式指定框架路径。使用完整 Xcode 时这些参数无害。
set -euo pipefail
cd "$(dirname "$0")/../Packages/WindowDeckCore"
DEV_DIR="$(xcode-select -p)"
FW="$DEV_DIR/Library/Developer/Frameworks"
[[ -d "$FW" ]] || FW="$DEV_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
LIB="$DEV_DIR/Library/Developer/usr/lib"
exec swift test --build-system native \
  -Xswiftc -F"$FW" -Xlinker -F"$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
