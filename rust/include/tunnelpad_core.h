#ifndef TUNNELPAD_CORE_H
#define TUNNELPAD_CORE_H

#include <stdint.h>

/*
 * tunnelpad-core C ABI（阶段 1 冻结，tp_abi_version() == 1）。
 *
 * 所有权规则：
 * 1. 所有 tp_* 返回的 char* 由 Rust 分配，调用方必须用 tp_string_free 释放，
 *    禁止用 free()；只能释放一次。
 * 2. 传入的 const char* 必须是 NUL 结尾的合法 UTF-8；Rust 只在调用期间借用。
 * 3. 返回 NULL 表示失败，此时 tp_last_error() 返回最近一次错误的 JSON
 *    （{"code":N,"message":"..."}）；错误随下一次 tp_* 调用更新，成功即清除。
 * 4. 旧 tp_* 兼容函数不持有跨调用状态；阶段 5 的 tp_core_* owner 另有
 *    长期 handle，并通过 generation 命令拒绝迟到生命周期操作。
 */

uint32_t tp_abi_version(void);

/* 解析 config.json；成功返回规范化 JSON，失败返回 NULL。 */
char *tp_config_parse(const char *input);

/* TunnelStatus：case 0=running（has_pid!=0 携带 pid，否则 "pid":null）、
 * 1=notRunning、2=notLoaded、3=other（state 必填）。 */
char *tp_status_encode(uint32_t status_case, int32_t has_pid, int32_t pid, const char *state);

/* ProbeResult：kind 0=satisfied、1=unexpected（携带 status）、2=failed（reason 必填）。 */
char *tp_probe_result_encode(uint32_t kind, int32_t status, const char *reason);

/* 最近一次失败的错误 JSON；无则返回 NULL。 */
char *tp_last_error(void);

/* 释放 tp_* 返回的字符串；NULL 是合法输入。 */
void tp_string_free(char *s);

/*
 * 阶段 5 owner 扩展（tp_core_abi_version() == 1）。
 *
 * 该扩展使用长期 opaque handle + UTF-8 JSON 命令。owner 命令的业务失败
 * 仍返回 {"ok":false,...} JSON；只有参数/传输错误返回 NULL，并通过
 * tp_core_last_error() 取得错误。返回字符串统一由 tp_string_free() 释放。
 */
typedef struct TpCoreHandle TpCoreHandle;

uint32_t tp_core_abi_version(void);
TpCoreHandle *tp_core_create(const char *home);
char *tp_core_command(TpCoreHandle *handle, const char *command);
char *tp_core_shutdown(TpCoreHandle *handle);
void tp_core_destroy(TpCoreHandle *handle);
char *tp_core_last_error(void);

#endif /* TUNNELPAD_CORE_H */
