#!/bin/sh
# 阶段 2 差分门禁：Swift harness 产出事件流 → Rust 侧同 fixture 执行并对比。
# 全程 fake 数据 + 隔离临时目录；app-executor 场景只 spawn /bin/sleep。
set -eu

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== Swift 差分 harness =="
rm -f rust/target/differential/swift-events.json
swift test --filter DifferentialHarnessTests

echo "== Rust 差分对比 =="
cargo test --manifest-path rust/Cargo.toml --test differential -- --nocapture
