//! 状态探针判定（Swift `ProbeService` 对等）。
//! 只判定结果三态；HTTP 传输注入，真实网络留待阶段 4。

use crate::ProbeConfig;
use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "case", rename_all = "camelCase")]
pub enum ProbeOutcome {
    Satisfied { status: i32 },
    Unexpected { status: i32 },
    Failed { reason: String },
}

/// 返回 HTTP 状态码；Err 视为失败。可注入便于测试。
pub trait ProbePerforming: Send + Sync {
    fn perform(&self, url: &str) -> Result<i32, String>;
}

pub struct ProbeService {
    pub performer: Option<Box<dyn ProbePerforming>>,
}

impl ProbeService {
    pub fn with_performer(performer: Box<dyn ProbePerforming>) -> Self {
        ProbeService { performer: Some(performer) }
    }

    pub fn check(&self, probe: &ProbeConfig) -> ProbeOutcome {
        if !is_valid_url(&probe.url) {
            return ProbeOutcome::Failed { reason: format!("非法探针 URL：{}", probe.url) };
        }
        match self.performer.as_ref() {
            Some(performer) => match performer.perform(&probe.url) {
                Ok(status) => {
                    if probe.expected_statuses.contains(&status) {
                        ProbeOutcome::Satisfied { status }
                    } else {
                        ProbeOutcome::Unexpected { status }
                    }
                }
                Err(reason) => ProbeOutcome::Failed { reason },
            },
            None => ProbeOutcome::Failed { reason: "未配置探针传输".into() },
        }
    }
}

/// Swift `URL(string:)` 的宽松近似：空串或含空白/控制字符非法；
/// 其余（含无 scheme 的相对串）按 Swift 语义视为可构造。
fn is_valid_url(url: &str) -> bool {
    !url.is_empty()
        && !url
            .chars()
            .any(|c| c.is_whitespace() || (c as u32) < 0x20 || c == '<' || c == '>' || c == '"')
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct FakePerformer {
        results: Mutex<Vec<Result<i32, String>>>,
    }

    impl ProbePerforming for FakePerformer {
        fn perform(&self, _url: &str) -> Result<i32, String> {
            self.results.lock().unwrap().pop().expect("脚本结果已耗尽")
        }
    }

    fn probe(url: &str, statuses: Vec<i32>) -> ProbeConfig {
        serde_json::from_value(serde_json::json!({
            "url": url,
            "expectedStatuses": statuses
        }))
        .unwrap()
    }

    #[test]
    fn three_states_match_swift() {
        let service = ProbeService::with_performer(Box::new(FakePerformer {
            results: Mutex::new(vec![Err("连接被拒绝".into()), Ok(502), Ok(200)]),
        }));
        assert_eq!(
            service.check(&probe("http://127.0.0.1/health", vec![200])),
            ProbeOutcome::Satisfied { status: 200 }
        );
        assert_eq!(
            service.check(&probe("http://127.0.0.1/health", vec![200])),
            ProbeOutcome::Unexpected { status: 502 }
        );
        assert_eq!(
            service.check(&probe("http://127.0.0.1/health", vec![200])),
            ProbeOutcome::Failed { reason: "连接被拒绝".into() }
        );
    }

    #[test]
    fn invalid_url_fails_without_performing() {
        let service = ProbeService::with_performer(Box::new(FakePerformer {
            results: Mutex::new(vec![]),
        }));
        assert_eq!(
            service.check(&probe("", vec![200])),
            ProbeOutcome::Failed { reason: "非法探针 URL：".into() }
        );
        assert_eq!(
            service.check(&probe("http://x y", vec![200])),
            ProbeOutcome::Failed { reason: "非法探针 URL：http://x y".into() }
        );
    }

    #[test]
    fn multiple_expected_statuses() {
        let service = ProbeService::with_performer(Box::new(FakePerformer {
            results: Mutex::new(vec![Ok(204)]),
        }));
        assert_eq!(
            service.check(&probe("http://x/health", vec![200, 204])),
            ProbeOutcome::Satisfied { status: 204 }
        );
    }
}
