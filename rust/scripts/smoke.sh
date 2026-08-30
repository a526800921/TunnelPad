#!/bin/sh
# 阶段 1 smoke：构建 Rust 静态库 → swiftc 编译兼容样本 → ad-hoc 签名并校验 → 运行断言。
# 覆盖原型门槛 1/2/3/5；门槛 4（取消/退出映射）由计划中的契约章节承载。
# 全程只使用 fake 数据，不执行 launchctl/SSH/真实隧道操作。
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== cargo build --release =="
cargo build --release --manifest-path rust/Cargo.toml

echo "== cargo test =="
cargo test --manifest-path rust/Cargo.toml --quiet

echo "== swiftc 编译兼容样本 =="
SMOKE_DIR="rust/target/smoke"
mkdir -p "$SMOKE_DIR"
swiftc \
    -I rust/include \
    -L rust/target/release \
    -ltunnelpad_core \
    -o "$SMOKE_DIR/rust_bridge_smoke" \
    rust/smoke/main.swift

echo "== ad-hoc 签名与校验（门槛 5）=="
codesign --force --sign - "$SMOKE_DIR/rust_bridge_smoke"
codesign --verify --strict "$SMOKE_DIR/rust_bridge_smoke"
codesign -dv "$SMOKE_DIR/rust_bridge_smoke" 2>&1 | sed -n '1p'

echo "== arm64 产物核对 =="
file "$SMOKE_DIR/rust_bridge_smoke" | sed 's/^/  /'
lipo -archs "$SMOKE_DIR/rust_bridge_smoke" | sed 's/^/  archs: /'

echo "== 运行 Swift 兼容断言（门槛 3）=="
"$SMOKE_DIR/rust_bridge_smoke"
