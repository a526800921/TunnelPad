//! 阶段 4 的真实 ABI 不兼容动态库 fixture。
//!
//! 只导出版本号，故意返回 ABI v2；Swift shadow bridge 应在解析其他符号前拒绝它。

#[no_mangle]
pub extern "C" fn tp_abi_version() -> u32 {
    2
}
