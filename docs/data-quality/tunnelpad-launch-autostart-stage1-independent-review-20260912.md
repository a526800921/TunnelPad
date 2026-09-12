# 阶段 1 独立复核：autoStart 配置契约

- 日期：2026-09-12；复核者：独立只读复核（未参与实现与测试编写，ZCode 子代理）
- 方式/风险：独立 / 高影响（公共配置契约，Rust owner + Swift 双侧）
- 受审范围：阶段 1 全部改动（TunnelConfig 双侧、apple_json、差分 fixture、表单、差分 harness 事件流）

## 逐项结论（8/8 通过）

1. **解码语义对齐 — 通过**：Swift `decodeIfPresent ?? false` 与 Rust `#[serde(default)]` 对齐；缺字段=false、显式值保留、非法类型 `"yes"` 双侧均按损坏配置拒绝（Swift 走 ConfigStore 损坏留档，Rust 映射 `INVALID_JSON`）；差分 `auto-start-bad-type` 两端 recoveredFrom 实测一致。信息性疑问：显式 `null` 时 Swift 视为 false、Rust 拒绝——属既有 keepAlive 同形模式，生产加载走 Rust owner，不在本阶段范围。
2. **apple_json 字节格式 — 通过**：`"autoStart" : <bool>` 为 tunnel 首键（字母序），6 空格缩进、`" : "` 分隔，与 Swift `JSONEncoder(.prettyPrinted + .sortedKeys)` 字节一致；差分 saveContent 字节级比较端到端通过。
3. **旧配置兼容 — 通过**：旧 App 读新配置忽略未知字段；新 App 读旧配置缺省 false。
4. **表单回路 — 通过**：`init(tunnel:)` 回填、`makeTunnel` 携带、两弹窗 Toggle 共用同一 form 字段；新增隧道默认 false，「新增不自动启动」语义未变。
5. **API 泄漏 — 通过**：API backend 手工挑字段，模型固定字段集，autoStart 不出现。
6. **差分 fixture 与 C0–C3 — 通过**：四个新用例与基线证据定义逐字对应；C4 由既有 bad-version 承载。
7. **回归面扫查 — 通过**：全仓构造点/序列化链路/legacy/migration 无漏改第二处；旧测试 JSON 断言均非穷举键集。
8. **不变量 — 通过**：version 保持 1；plist 渲染不含 autoStart；新增不自动启动语义保持。

## 总体结论

**PASS**。无必须修复项；1 项信息性疑问（显式 null 不对称，既有模式）。

## 复核声明

复核者复跑 `swift test`（146/146，当时代码态）、`cargo test`、`bash rust/scripts/differential.sh`，全部通过；字节级 parity 由差分 saveContent 实证。
