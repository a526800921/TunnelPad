#!/bin/bash
#
# build_app.sh — TunnelPad .app 构建脚本
#
# 用法:
#   ./scripts/build_app.sh                # 测试 + release 构建 + 打包
#   ./scripts/build_app.sh --skip-tests   # 跳过测试
#   ./scripts/build_app.sh --run          # 打包后自动启动
#
# 参照 ModelPad scripts/build_app.sh。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="TunnelPad"
EXECUTABLE_NAME="tunnelpad"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ARCH="$(uname -m)"
BUILD_TRIPLE="${ARCH}-apple-macosx"
INFO_PLIST_SRC="$PROJECT_ROOT/App/Resources/Info.plist"
ICON_SRC="$PROJECT_ROOT/App/Resources/TunnelPad.icns"

SKIP_TESTS=false
DO_RUN=false

for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
        --run)        DO_RUN=true ;;
        *)            echo "未知参数: $arg"; exit 1 ;;
    esac
done

echo "==> 项目: $PROJECT_ROOT"
echo "==> 架构: $ARCH"

# Step 1: 测试
if $SKIP_TESTS; then
    echo "==> 跳过测试"
else
    echo "==> 运行测试..."
    cd "$PROJECT_ROOT"
    swift test
    echo "✓ 测试通过"
fi

# Step 2: Release 构建
echo "==> SwiftPM 构建 (release)..."
cd "$PROJECT_ROOT"
swift build -c release --product "$EXECUTABLE_NAME"
echo "✓ 构建完成"

# Step 3: 准备 .app 目录结构
echo "==> 生成 $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Step 4: 复制二进制
BINARY_SRC="$PROJECT_ROOT/.build/$BUILD_TRIPLE/release/$EXECUTABLE_NAME"
cp "$BINARY_SRC" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
echo "  ✓ 二进制: $BINARY_SRC → Contents/MacOS/"

# Step 5: 复制 Info.plist 与图标
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
echo "  ✓ Info.plist (LSUIElement)"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
echo "  ✓ 应用图标"

# Step 6: PkgInfo + ad-hoc 签名 + 校验
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"
echo "  ✓ PkgInfo"

echo "==> 签名..."
codesign --force --deep --sign - "$APP_BUNDLE"
echo "  ✓ Ad-hoc 签名完成"

echo "==> 校验..."
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --verify --deep --strict "$APP_BUNDLE" && echo "  ✓ 签名校验通过"

echo ""
echo "====== 构建完成 ======"
echo "App: $APP_BUNDLE"
echo "启动: open '$APP_BUNDLE'"

if $DO_RUN; then
    echo ""
    echo "==> 启动 App..."
    open "$APP_BUNDLE"
fi
