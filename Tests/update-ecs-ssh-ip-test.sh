#!/bin/bash

set -eu

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT_DIR/scripts/update-ecs-ssh-ip"
FIXTURE_DIR="$ROOT_DIR/Tests/fixtures/update-ecs-ssh-ip"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/tunnelpad-ecs-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

JQ_BIN=${JQ_BIN:-$(command -v jq)}
SHASUM_BIN=${SHASUM_BIN:-$(command -v shasum)}
export JQ_BIN SHASUM_BIN

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (expected=$1 actual=$2)"
}

assert_contains() {
  printf '%s\n' "$1" | grep -Fq "$2" || fail "$3"
}

assert_not_contains() {
  if printf '%s\n' "$1" | grep -Fq "$2"; then
    fail "$3"
  fi
}

write_state() {
  printf '%s\n' "$1" >"$STATE_FILE"
}

prepare_case() {
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR"
  STATE_FILE="$CASE_DIR/state.json"
  CALL_LOG="$CASE_DIR/calls.log"
  CONFIG_FILE="$CASE_DIR/ecs-ssh-ip.env"
  ALIYUN_CONFIG="$CASE_DIR/aliyun.json"
  LOG_FILE="$CASE_DIR/sync.log"
  LOCK_DIR="$CASE_DIR/lock"
  : >"$CALL_LOG"
  : >"$ALIYUN_CONFIG"
  printf '%s\n' \
    "TUNNELPAD_ALIYUN_CONFIG=$ALIYUN_CONFIG" \
    'ALIBABA_PROFILE=tunnelpad-ecs-sync' \
    'ALIBABA_REGION_ID=cn-fixture-1' \
    'ECS_SECURITY_GROUP_ID=sg-fixture' \
    'TUNNELPAD_IP_ENDPOINT_1=https://endpoint-one.test' \
    'TUNNELPAD_IP_ENDPOINT_2=https://endpoint-two.test' \
    >"$CONFIG_FILE"
  export STATE_FILE CALL_LOG CONFIG_FILE ALIYUN_CONFIG LOG_FILE LOCK_DIR
  export FAKE_STATE_FILE="$STATE_FILE" FAKE_CALL_LOG="$CALL_LOG"
  export TUNNELPAD_CONFIG_FILE="$CONFIG_FILE"
  export TUNNELPAD_LOG_FILE="$LOG_FILE"
  export TUNNELPAD_LOCK_DIR="$LOCK_DIR"
  export TUNNELPAD_PREFLIGHT_STATE_DIR="$CASE_DIR/preflight"
  export CURL_BIN="$FIXTURE_DIR/fake-curl"
  export ALIYUN_BIN="$FIXTURE_DIR/fake-aliyun"
  export UUIDGEN_BIN="$FIXTURE_DIR/fake-uuidgen"
  export FAKE_IP_1=45.67.89.101 FAKE_IP_2=45.67.89.101
  unset FAKE_CURL_FAIL FAKE_DESCRIBE_FAIL FAKE_AUTHORIZE_FAIL FAKE_AUTHORIZE_ERROR_AFTER_APPLY FAKE_REVOKE_FAIL FAKE_REVOKE_ERROR_AFTER_APPLY
}

run_update() {
  set +e
  OUTPUT=$("$SCRIPT" "$@" 2>&1)
  RC=$?
  set -e
}

count_calls() {
  grep -c "^$1 " "$CALL_LOG" 2>/dev/null || true
}

current_rule='{"Description":"tunnelpad-dynamic-ssh-managed","Direction":"ingress","IpProtocol":"TCP","PortRange":"22/22","Policy":"Accept","NicType":"intranet","SourceCidrIp":"45.67.89.101/32","SecurityGroupRuleId":"sgr-current"}'
old_rule='{"Description":"tunnelpad-dynamic-ssh-managed","Direction":"ingress","IpProtocol":"TCP","PortRange":"22/22","Policy":"Accept","NicType":"intranet","SourceCidrIp":"45.67.89.100/32","SecurityGroupRuleId":"sgr-old"}'
other_rule='{"Description":"createdByEcsWorkbench","Direction":"ingress","IpProtocol":"TCP","PortRange":"22/22","Policy":"Accept","NicType":"intranet","SourceCidrIp":"0.0.0.0/0","SecurityGroupRuleId":"sgr-other"}'

prepare_case current
write_state "{\"Permissions\":{\"Permission\":[$current_rule,$other_rule]}}"
run_update
assert_eq 0 "$RC" '当前规则应幂等成功'
assert_eq 1 "$(count_calls DescribeSecurityGroupAttribute)" '当前规则只需一次读取'
assert_eq 0 "$(count_calls AuthorizeSecurityGroup)" '当前规则不应新增'
assert_eq 0 "$(count_calls RevokeSecurityGroup)" '当前规则不应撤销'
assert_not_contains "$(cat "$LOG_FILE")" '45.67.89.101' '日志不得包含原始 IP'
printf '%s\n' 'PASS current-managed-rule'

prepare_case mismatch
write_state "{\"Permissions\":{\"Permission\":[$current_rule]}}"
FAKE_IP_2=45.67.89.102
export FAKE_IP_2
run_update
assert_eq 3 "$RC" '端点不一致应停止'
assert_eq 0 "$(wc -l <"$CALL_LOG" | tr -d ' ')" '端点不一致不应调用云端'
printf '%s\n' 'PASS endpoint-mismatch'

prepare_case invalid-ip
write_state "{\"Permissions\":{\"Permission\":[$current_rule]}}"
FAKE_IP_1=10.1.2.3
FAKE_IP_2=10.1.2.3
export FAKE_IP_1 FAKE_IP_2
run_update
assert_eq 3 "$RC" '私网 IPv4 应停止'
assert_eq 0 "$(wc -l <"$CALL_LOG" | tr -d ' ')" '私网 IPv4 不应调用云端'
printf '%s\n' 'PASS invalid-private-ip'

prepare_case first-sync
write_state "{\"Permissions\":{\"Permission\":[$other_rule]}}"
run_update
assert_eq 0 "$RC" '没有受管规则时应新增并确认'
assert_eq 1 "$(count_calls AuthorizeSecurityGroup)" '首次同步应新增一次'
assert_eq 0 "$(count_calls RevokeSecurityGroup)" '首次同步不应撤销规则'
assert_eq 1 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '首次同步后应存在一条受管规则'
printf '%s\n' 'PASS first-sync-without-managed-rule'

prepare_case authorize-uncertain
write_state "{\"Permissions\":{\"Permission\":[$other_rule]}}"
FAKE_AUTHORIZE_ERROR_AFTER_APPLY=1
export FAKE_AUTHORIZE_ERROR_AFTER_APPLY
run_update
assert_eq 0 "$RC" '新增响应异常但规则已落云时应重新查询收敛'
assert_eq 1 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '响应异常收敛后应保留当前规则'
printf '%s\n' 'PASS authorize-uncertain-converged'

prepare_case rotate
write_state "{\"Permissions\":{\"Permission\":[$old_rule,$other_rule]}}"
run_update
assert_eq 0 "$RC" '旧规则轮换应成功'
assert_eq 3 "$(count_calls DescribeSecurityGroupAttribute)" '轮换应读取初始、新增确认和最终状态'
assert_eq 1 "$(count_calls AuthorizeSecurityGroup)" '轮换应新增一次'
assert_eq 1 "$(count_calls RevokeSecurityGroup)" '轮换应撤销一次'
assert_contains "$(cat "$CALL_LOG")" 'AuthorizeSecurityGroup source=45.67.89.101/32 rule= token=present' '新增必须携带 ClientToken'
assert_contains "$(cat "$CALL_LOG")" 'RevokeSecurityGroup source= rule=sgr-old token=present' '撤销必须携带 ClientToken 和旧规则 ID'
assert_eq 1 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '轮换后只保留一条受管规则'
assert_contains "$(cat "$STATE_FILE")" '45.67.89.101/32' '轮换后应保留当前来源'
assert_contains "$(cat "$STATE_FILE")" 'createdByEcsWorkbench' '非受管规则必须保留'
printf '%s\n' 'PASS old-rule-rotation'

prepare_case authorize-fail
write_state "{\"Permissions\":{\"Permission\":[$old_rule]}}"
FAKE_AUTHORIZE_FAIL=1
export FAKE_AUTHORIZE_FAIL
run_update
assert_eq 5 "$RC" '新增失败应返回 5'
assert_eq 0 "$(count_calls RevokeSecurityGroup)" '新增失败不得撤销旧规则'
assert_contains "$(cat "$STATE_FILE")" '45.67.89.100/32' '新增失败应保留旧规则'
printf '%s\n' 'PASS authorize-failure'

prepare_case revoke-fail
write_state "{\"Permissions\":{\"Permission\":[$old_rule]}}"
FAKE_REVOKE_FAIL=1
export FAKE_REVOKE_FAIL
run_update
assert_eq 6 "$RC" '撤销失败应返回 6'
assert_eq 2 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '撤销失败应保留新旧规则'
assert_contains "$(cat "$STATE_FILE")" '45.67.89.100/32' '撤销失败应保留旧规则'
assert_contains "$(cat "$STATE_FILE")" '45.67.89.101/32' '撤销失败应保留新规则'
printf '%s\n' 'PASS revoke-failure'

# 阶段 0 反证：外部临时撤销故障已解除，旧脚本仍会因双规则拒绝重试。
# 无人值守实现后应以可信事务恢复的目标断言替换，未知多规则仍 fail-closed。
unset FAKE_REVOKE_FAIL
revoke_calls_before_retry=$(count_calls RevokeSecurityGroup)
run_update
assert_eq 0 "$RC" '撤销故障解除后应从可信事务收敛'
assert_eq "$((revoke_calls_before_retry + 1))" "$(count_calls RevokeSecurityGroup)" '只续作原精确撤销'
assert_eq 1 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '应只保留新规则'
printf '%s\n' 'PASS retry-after-revoke-failure-converges'

prepare_case revoke-uncertain
write_state "{\"Permissions\":{\"Permission\":[$old_rule]}}"
FAKE_REVOKE_ERROR_AFTER_APPLY=1
export FAKE_REVOKE_ERROR_AFTER_APPLY
run_update
assert_eq 0 "$RC" '撤销响应异常但旧规则已删除时应重新查询收敛'
assert_eq 1 "$("$JQ_BIN" '[.Permissions.Permission[] | select(.Description == "tunnelpad-dynamic-ssh-managed")] | length' "$STATE_FILE")" '撤销响应异常收敛后应只保留当前规则'
assert_contains "$(cat "$STATE_FILE")" '45.67.89.101/32' '撤销响应异常收敛后应保留新规则'
printf '%s\n' 'PASS revoke-uncertain-converged'

prepare_case ambiguous
ambiguous_a="$old_rule"
ambiguous_b='{"Description":"tunnelpad-dynamic-ssh-managed","Direction":"ingress","IpProtocol":"TCP","PortRange":"22/22","Policy":"Accept","NicType":"intranet","SourceCidrIp":"45.67.89.99/32","SecurityGroupRuleId":"sgr-ambiguous"}'
write_state "{\"Permissions\":{\"Permission\":[$ambiguous_a,$ambiguous_b]}}"
run_update
assert_eq 4 "$RC" '多条受管规则应返回 4'
assert_eq 1 "$(count_calls DescribeSecurityGroupAttribute)" '歧义时只读取一次'
assert_eq 0 "$(count_calls AuthorizeSecurityGroup)" '歧义时不得新增'
printf '%s\n' 'PASS ambiguous-managed-rules'

prepare_case describe-failure
write_state "{\"Permissions\":{\"Permission\":[$current_rule]}}"
FAKE_DESCRIBE_FAIL=1
export FAKE_DESCRIBE_FAIL
run_update
assert_eq 4 "$RC" '云端读取失败应返回 4'
assert_eq 1 "$(count_calls DescribeSecurityGroupAttribute)" '云端读取失败不应重复写入'
assert_eq 0 "$(count_calls AuthorizeSecurityGroup)" '云端读取失败不得新增'
assert_eq 0 "$(count_calls RevokeSecurityGroup)" '云端读取失败不得撤销'
printf '%s\n' 'PASS describe-failure'

prepare_case lock
write_state "{\"Permissions\":{\"Permission\":[$current_rule]}}"
mkdir "$LOCK_DIR"
run_update
assert_eq 7 "$RC" '锁冲突应返回 7'
assert_eq 0 "$(wc -l <"$CALL_LOG" | tr -d ' ')" '锁冲突不得探测或调用云端'
printf '%s\n' 'PASS lock-contention'

prepare_case missing-config
printf '%s\n' 'ALIBABA_REGION_ID=cn-fixture-1' 'ECS_SECURITY_GROUP_ID=sg-fixture' >"$CONFIG_FILE"
run_update
assert_eq 2 "$RC" '缺少 profile 配置应返回 2'
assert_eq 0 "$(wc -l <"$CALL_LOG" | tr -d ' ')" '配置错误不得调用外部命令'
printf '%s\n' 'PASS missing-profile-config'

prepare_case check-only
write_state "{\"Permissions\":{\"Permission\":[$old_rule]}}"
run_update --check
assert_eq 0 "$RC" '--check 应只读成功'
assert_eq 1 "$(count_calls DescribeSecurityGroupAttribute)" '--check 应只读取一次'
assert_eq 0 "$(count_calls AuthorizeSecurityGroup)" '--check 不应新增'
assert_eq 0 "$(count_calls RevokeSecurityGroup)" '--check 不应撤销'
printf '%s\n' 'PASS check-only'

printf '%s\n' '全部 update-ecs-ssh-ip fixture 测试通过。'
