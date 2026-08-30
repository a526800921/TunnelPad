// 阶段 1 Swift 兼容调用样本：链接 Rust 静态库，逐项断言 5 项原型门槛中的
// 表达完整性（门槛 1）、所有权规则（门槛 2）与 Swift 兼容调用（门槛 3）。
// 由 rust/scripts/smoke.sh 用 swiftc 直接编译，不涉及 Package.swift。
import CTunnelpadCore
import Foundation

var failures: [String] = []

func expectTrue(_ condition: Bool, _ label: String) {
    if condition {
        print("ok - \(label)")
    } else {
        failures.append(label)
        print("FAIL - \(label)")
    }
}

func takeString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    defer { tp_string_free(pointer) }
    return String(cString: pointer)
}

func lastErrorCode() -> UInt32 {
    guard let pointer = tp_last_error() else { return 0 }
    defer { tp_string_free(pointer) }
    guard let data = String(cString: pointer).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let code = object["code"] as? NSNumber else { return 0 }
    return code.uint32Value
}

// 门槛 3：加载与基本调用。
expectTrue(tp_abi_version() == 1, "tp_abi_version == 1")

// 门槛 1 + 2：完整 config 解析 round-trip（Swift JSONEncoder 形状）。
let fullConfig = """
{"version":1,"tunnels":[{"id":"admin-tunnel","name":"管理隧道","command":["/usr/bin/ssh","-N","-L","8080:127.0.0.1:80","host"],"executor":"launchd","keepAlive":true,"throttleInterval":10,"probe":{"url":"http://127.0.0.1:8080/health","expectedStatuses":[200,204]}}]}
"""
let fullPointer = fullConfig.withCString { tp_config_parse($0) }
if let output = takeString(fullPointer) {
    expectTrue(output.contains("\"id\":\"admin-tunnel\""), "完整配置保留 id")
    expectTrue(output.contains("\"probe\":{\"url\":\"http://127.0.0.1:8080/health\",\"expectedStatuses\":[200,204]}"), "probe 保留且键序一致")
    expectTrue(output.hasPrefix("{\"version\":1,\"tunnels\":["), "键序与 Swift CodingKeys 一致")
} else {
    expectTrue(false, "完整配置解析成功（lastError=\(lastErrorCode())）")
}

// 缺省字段补全：手写配置省略 executor/keepAlive/throttleInterval。
let minimalConfig = "{\"version\":1,\"tunnels\":[{\"id\":\"web\",\"name\":\"web\",\"command\":[\"/usr/bin/ssh\",\"-N\"]}]}"
let minimalPointer = minimalConfig.withCString { tp_config_parse($0) }
if let output = takeString(minimalPointer) {
    expectTrue(output.contains("\"executor\":\"launchd\""), "缺省 executor 补为 launchd")
    expectTrue(output.contains("\"keepAlive\":true"), "缺省 keepAlive 补为 true")
    expectTrue(output.contains("\"throttleInterval\":10"), "缺省 throttleInterval 补为 10")
    expectTrue(!output.contains("probe"), "缺省 probe 省略")
} else {
    expectTrue(false, "最小配置解析成功（lastError=\(lastErrorCode())）")
}

// 错误分类（门槛 1 的错误分类部分）。
expectTrue(takeString("{{".withCString { tp_config_parse($0) }) == nil, "非法 JSON 返回 NULL")
expectTrue(lastErrorCode() == 1, "非法 JSON → code 1")

expectTrue(takeString("{\"version\":2,\"tunnels\":[]}".withCString { tp_config_parse($0) }) == nil, "version=2 返回 NULL")
expectTrue(lastErrorCode() == 2, "schema version → code 2")

expectTrue(takeString("{\"version\":1,\"tunnels\":[{\"id\":\"Bad ID\",\"name\":\"x\",\"command\":[\"/bin/true\"]}]}".withCString { tp_config_parse($0) }) == nil, "非法 id 返回 NULL")
expectTrue(lastErrorCode() == 3, "非法 id → code 3")

expectTrue(takeString("{\"version\":1,\"tunnels\":[{\"id\":\"ok\",\"name\":\"x\",\"command\":[]}]}".withCString { tp_config_parse($0) }) == nil, "空 command 返回 NULL")
expectTrue(lastErrorCode() == 4, "空 command → code 4")

// TunnelStatus 四个 case。
let running = takeString(tp_status_encode(0, 1, 1234, nil))
expectTrue(running == "{\"case\":\"running\",\"pid\":1234}", "running(pid) 编码")
let runningNoPid = takeString(tp_status_encode(0, 0, 0, nil))
expectTrue(runningNoPid == "{\"case\":\"running\",\"pid\":null}", "running(pid=nil) 编码")
expectTrue(takeString(tp_status_encode(1, 0, 0, nil)) == "{\"case\":\"notRunning\"}", "notRunning 编码")
expectTrue(takeString(tp_status_encode(2, 0, 0, nil)) == "{\"case\":\"notLoaded\"}", "notLoaded 编码")
let other = "weird-state".withCString { tp_status_encode(3, 0, 0, $0) }
expectTrue(takeString(other) == "{\"case\":\"other\",\"state\":\"weird-state\"}", "other(state) 编码")
expectTrue(takeString(tp_status_encode(3, 0, 0, nil)) == nil, "other 缺 state 返回 NULL")
expectTrue(lastErrorCode() == 5, "other 缺 state → code 5")

// ProbeResult 三个 case。
expectTrue(takeString(tp_probe_result_encode(0, 200, nil)) == "{\"case\":\"satisfied\",\"status\":200}", "satisfied 编码")
expectTrue(takeString(tp_probe_result_encode(1, 502, nil)) == "{\"case\":\"unexpected\",\"status\":502}", "unexpected 编码")
let failed = "连接被拒绝".withCString { tp_probe_result_encode(2, 0, $0) }
expectTrue(takeString(failed) == "{\"case\":\"failed\",\"reason\":\"连接被拒绝\"}", "failed(reason) 编码")
expectTrue(takeString(tp_probe_result_encode(2, 0, nil)) == nil, "failed 缺 reason 返回 NULL")
expectTrue(lastErrorCode() == 5, "failed 缺 reason → code 5")

// 成功调用清除错误状态。
if let ok = minimalConfig.withCString({ tp_config_parse($0) }) {
    _ = takeString(ok)
}
expectTrue(tp_last_error() == nil, "成功调用后 last-error 清空")

// 所有权规则：tp_string_free(NULL) 安全（门槛 2 的释放侧约定）。
tp_string_free(nil)
print("ok - tp_string_free(NULL) 安全")

if failures.isEmpty {
    print("SWIFT SMOKE: 全部通过")
    exit(0)
} else {
    print("SWIFT SMOKE: \(failures.count) 项失败")
    exit(1)
}
