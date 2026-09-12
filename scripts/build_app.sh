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
DIST_DIR="${TUNNELPAD_DIST_DIR:-$PROJECT_ROOT/dist}"
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

# Step 1: 构建 Rust Core 动态库
echo "==> Rust Core 构建 (release)..."
cd "$PROJECT_ROOT"
cargo build --release --manifest-path "$PROJECT_ROOT/rust/Cargo.toml"
RUST_DYLIB_SRC="$PROJECT_ROOT/rust/target/release/libtunnelpad_core.dylib"
test -f "$RUST_DYLIB_SRC"
# Cargo 默认把 cdylib 的 install name 写成工作树绝对路径；发布包必须自包含。
install_name_tool -id "@rpath/libtunnelpad_core.dylib" "$RUST_DYLIB_SRC"
echo "✓ Rust 动态库: $RUST_DYLIB_SRC"

# Step 2: 测试
if $SKIP_TESTS; then
    echo "==> 跳过测试"
else
    echo "==> 运行测试..."
    cd "$PROJECT_ROOT"
    swift test
    echo "✓ 测试通过"
fi

# Step 3: Swift Release 构建
echo "==> SwiftPM 构建 (release)..."
cd "$PROJECT_ROOT"
swift build -c release --product "$EXECUTABLE_NAME"
echo "✓ 构建完成"

# Step 4: 准备 .app 目录结构
echo "==> 生成 $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Step 5: 复制二进制与 Rust 动态库
BINARY_SRC="$PROJECT_ROOT/.build/$BUILD_TRIPLE/release/$EXECUTABLE_NAME"
cp "$BINARY_SRC" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
echo "  ✓ 二进制: $BINARY_SRC → Contents/MacOS/"
cp "$RUST_DYLIB_SRC" "$APP_BUNDLE/Contents/Frameworks/"
chmod +x "$APP_BUNDLE/Contents/Frameworks/libtunnelpad_core.dylib"
echo "  ✓ Rust 动态库: $RUST_DYLIB_SRC → Contents/Frameworks/"

# Step 6: 复制 Info.plist 与图标
cp "$INFO_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
echo "  ✓ Info.plist (LSUIElement)"
cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
echo "  ✓ 应用图标"
cp "$PROJECT_ROOT/scripts/update-ecs-ssh-ip" "$APP_BUNDLE/Contents/Resources/update-ecs-ssh-ip"
chmod +x "$APP_BUNDLE/Contents/Resources/update-ecs-ssh-ip"
cp "$PROJECT_ROOT/rust/target/release/tunnelpad-preflight" "$APP_BUNDLE/Contents/Resources/tunnelpad-preflight"
chmod +x "$APP_BUNDLE/Contents/Resources/tunnelpad-preflight"
echo "  ✓ ECS SSH 公网 IP 同步脚本"

# Step 7: PkgInfo + ad-hoc 签名 + 校验
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
