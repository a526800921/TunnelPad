use super::{process, store, Config, Failure, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::io::Read;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
const DESCRIPTION: &str = "tunnelpad-dynamic-ssh-managed";
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u8,
    region: String,
    group: String,
    old: Option<Value>,
    desired: String,
    new: Option<Value>,
    authorize_token: String,
    revoke_token: String,
}
fn unsafe_rules() -> Failure {
    Failure::new(4, "unknown", "managed_ambiguous")
}
fn field<'a>(r: &'a Value, key: &str) -> &'a str {
    r[key].as_str().unwrap_or("")
}
fn safe_rule(r: &Value) -> bool {
    field(r, "Description") == DESCRIPTION
        && field(r, "Direction").eq_ignore_ascii_case("ingress")
        && field(r, "IpProtocol").eq_ignore_ascii_case("tcp")
        && field(r, "PortRange") == "22/22"
        && field(r, "Policy").eq_ignore_ascii_case("accept")
        && field(r, "NicType").eq_ignore_ascii_case("intranet")
        && !field(r, "SecurityGroupRuleId").is_empty()
        && cidr(field(r, "SourceCidrIp"))
        && [
            "SourceGroupId",
            "SourceGroupOwnerAccount",
            "Ipv6SourceCidrIp",
        ]
        .iter()
        .all(|k| field(r, k).is_empty())
}
// An unconfirmed rule can only be adopted if it matches the complete request.
fn requested_rule(r: &Value, desired: &str) -> bool {
    safe_rule(r)
        && field(r, "SourceCidrIp") == desired
        && (field(r, "Priority") == "1" || r["Priority"].as_u64() == Some(1))
        && [
            "SourcePrefixListId",
            "SourceGroupOwnerId",
            "DestCidrIp",
            "Ipv6DestCidrIp",
            "DestGroupId",
            "DestPrefixListId",
        ]
        .iter()
        .all(|key| field(r, key).is_empty())
}
fn public(ip: &str) -> bool {
    let Ok(ip) = ip.parse::<std::net::Ipv4Addr>() else {
        return false;
    };
    let [a, b, c, _] = ip.octets();
    !(a == 0
        || a == 10
        || a == 127
        || a >= 224
        || a == 100 && (64..=127).contains(&b)
        || a == 169 && b == 254
        || a == 172 && (16..=31).contains(&b)
        || a == 192 && ((b == 0 && (c == 0 || c == 2)) || b == 168)
        || a == 198 && ((18..=19).contains(&b) || b == 51 && c == 100)
        || a == 203 && b == 0 && c == 113)
}
fn cidr(s: &str) -> bool {
    s.strip_suffix("/32").is_some_and(public)
}
fn ip(body: &[u8]) -> Result<String> {
    let text = String::from_utf8_lossy(body);
    let ips: Vec<&str> = text
        .split(|c: char| !c.is_ascii_digit() && c != '.')
        .filter(|s| s.contains('.'))
        .collect();
    if ips.len() != 1 || !public(ips[0]) {
        return Err(Failure::new(3, "unknown", "probe_invalid"));
    }
    Ok(ips[0].into())
}
fn token() -> Result<String> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|_| Failure::new(2, "local", "token_unavailable"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
fn classify(body: &[u8], stage: i32) -> Failure {
    let text = String::from_utf8_lossy(body);
    let code = serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|j| {
            j.get("Code")
                .or_else(|| j.get("ErrorCode"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            text.lines().find_map(|l| {
                l.trim()
                    .strip_prefix("ErrorCode:")
                    .map(|s| s.trim().to_owned())
            })
        })
        .unwrap_or_default();
    let category = match code.as_str() {
        "InvalidAccessKeyId.NotFound"
        | "SignatureDoesNotMatch"
        | "Forbidden.RAM"
        | "Forbidden"
        | "InvalidSecurityToken.Expired"
        | "NoPermission" => "auth",
        "Throttling" | "Throttling.User" | "ServiceUnavailable" | "InternalError"
        | "RequestTimeout" => "transient",
        _ => "unknown",
    };
    Failure::new(
        stage,
        category,
        match category {
            "auth" => "cloud_auth",
            "transient" => "cloud_transient",
            _ => "cloud_unknown",
        },
    )
}
fn api(
    c: &Config,
    action: &str,
    extra: &[&str],
    parent: i32,
    deadline: Instant,
    stage: i32,
) -> Result<Value> {
    let mut args: Vec<String> = [
        "--config-path",
        &c.credentials,
        "--profile",
        &c.profile,
        "ecs",
        action,
        "--RegionId",
        &c.region,
        "--SecurityGroupId",
        &c.group,
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    args.extend(extra.iter().map(|s| (*s).into()));
    let (ok, body) = process::run(
        &c.aliyun,
        &args,
        parent,
        deadline.min(Instant::now() + Duration::from_secs(10)),
    )?;
    let parsed = serde_json::from_slice::<Value>(&body);
    if !ok
        || parsed
            .as_ref()
            .is_ok_and(|j| j.get("Code").is_some() || j.get("ErrorCode").is_some())
    {
        return Err(classify(&body, stage));
    }
    parsed.map_err(|_| classify(&body, stage))
}
fn describe(c: &Config, parent: i32, deadline: Instant) -> Result<Vec<Value>> {
    let raw = api(
        c,
        "DescribeSecurityGroupAttribute",
        &["--Direction", "ingress", "--NicType", "intranet"],
        parent,
        deadline,
        4,
    )?;
    let rules = raw["Permissions"]["Permission"]
        .as_array()
        .ok_or_else(|| Failure::new(4, "unknown", "describe_invalid"))?;
    let mut managed = Vec::new();
    for rule in rules {
        if field(rule, "Description") == DESCRIPTION {
            if !safe_rule(rule) {
                return Err(unsafe_rules());
            }
            managed.push(rule.clone());
        }
    }
    Ok(managed)
}
fn validate(j: &Journal, c: &Config, rules: &[Value]) -> Result<Option<Value>> {
    if j.version != 1
        || j.region != c.region
        || j.group != c.group
        || !cidr(&j.desired)
        || j.authorize_token.len() != 32
        || j.revoke_token.len() != 32
        || !j
            .authorize_token
            .bytes()
            .chain(j.revoke_token.bytes())
            .all(|b| b.is_ascii_hexdigit())
        || j.old
            .as_ref()
            .is_some_and(|r| !safe_rule(r) || field(r, "SourceCidrIp") == j.desired)
        || j.new
            .as_ref()
            .is_some_and(|r| !requested_rule(r, &j.desired))
    {
        return Err(unsafe_rules());
    }
    if rules.len() > 2 {
        return Err(unsafe_rules());
    }
    let mut new = None;
    for rule in rules {
        if j.old.as_ref() == Some(rule) {
            continue;
        }
        if !requested_rule(rule, &j.desired)
            || j.new.as_ref().is_some_and(|known| known != rule)
            || new.is_some()
            || j.old.as_ref().is_some_and(|old| {
                field(old, "SecurityGroupRuleId") == field(rule, "SecurityGroupRuleId")
            })
        {
            return Err(unsafe_rules());
        }
        new = Some(rule.clone());
    }
    if j.new.is_some() && new.is_none() {
        return Err(unsafe_rules());
    }
    if new.is_none() && j.old.as_ref().is_some_and(|old| !rules.contains(old)) {
        return Err(unsafe_rules());
    }
    Ok(new)
}
fn resume(
    c: &Config,
    j: &mut Journal,
    mut rules: Vec<Value>,
    parent: i32,
    deadline: Instant,
) -> Result<Vec<Value>> {
    let observed = validate(j, c, &rules)?;
    if observed.is_none() {
        // Journal has already been fsynced. Replays always use the original token.
        let authorize = api(
            c,
            "AuthorizeSecurityGroup",
            &[
                "--IpProtocol",
                "TCP",
                "--PortRange",
                "22/22",
                "--SourceCidrIp",
                &j.desired,
                "--NicType",
                "intranet",
                "--Policy",
                "accept",
                "--Priority",
                "1",
                "--Description",
                DESCRIPTION,
                "--ClientToken",
                &j.authorize_token,
            ],
            parent,
            deadline,
            5,
        );
        rules = describe(c, parent, deadline).map_err(|mut e| {
            e.exit_code = 5;
            e.stage = "authorize".into();
            e
        })?;
        let new = validate(j, c, &rules)?;
        if new.is_none() {
            return Err(authorize
                .err()
                .unwrap_or_else(|| Failure::new(5, "unknown", "authorize_unconfirmed")));
        }
        j.new = new;
        store::write(&c.path("journal"), j)?;
    } else if j.new.is_none() {
        j.new = observed;
        store::write(&c.path("journal"), j)?;
    }
    if let Some(old) = j.old.as_ref().filter(|old| rules.contains(old)) {
        // Every remaining rule is the exact recorded old/new shape; no third rule can be deleted.
        let revoke = api(
            c,
            "RevokeSecurityGroup",
            &[
                "--SecurityGroupRuleId.1",
                field(old, "SecurityGroupRuleId"),
                "--ClientToken",
                &j.revoke_token,
            ],
            parent,
            deadline,
            6,
        );
        rules = describe(c, parent, deadline).map_err(|mut e| {
            e.exit_code = 6;
            e.stage = "revoke".into();
            e
        })?;
        validate(j, c, &rules)?;
        if rules.len() != 1 || rules.first() != j.new.as_ref() {
            return Err(revoke
                .err()
                .unwrap_or_else(|| Failure::new(6, "transient", "revoke_unconfirmed")));
        }
    }
    if rules.len() != 1 || rules.first() != j.new.as_ref() {
        return Err(unsafe_rules());
    }
    store::remove(&c.path("journal"))?;
    Ok(rules)
}
fn epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub(super) fn sync(c: &Config, check: bool, parent: i32, deadline: Instant) -> Result<()> {
    let cooldown: Option<u64> = store::read(&c.path("auth"))?;
    if cooldown.is_some_and(|until| until > epoch()) {
        return Err(Failure::new(4, "auth", "auth_cooldown"));
    }
    let result = (|| {
        let mut ips = Vec::new();
        for endpoint in &c.endpoints {
            let (ok, body) = process::run(
                &c.curl,
                &[
                    "-4fsS".into(),
                    "--max-time".into(),
                    "10".into(),
                    endpoint.clone(),
                ],
                parent,
                deadline.min(Instant::now() + Duration::from_secs(10)),
            )?;
            if !ok {
                return Err(Failure::new(3, "transient", "probe_failed"));
            }
            ips.push(ip(&body)?);
        }
        if ips[0] != ips[1] {
            return Err(Failure::new(3, "transient", "probe_mismatch"));
        }
        let desired = format!("{}/32", ips[0]);
        let mut rules = describe(c, parent, deadline)?;
        // Expired authentication cooldown requires this successful read before any write.
        if cooldown.is_some() {
            store::remove(&c.path("auth"))?;
        }
        let pending: Option<Journal> = store::read(&c.path("journal"))?;
        if check {
            if let Some(j) = pending {
                validate(&j, c, &rules)?;
            } else if rules.len() > 1 {
                return Err(unsafe_rules());
            }
            return Ok(());
        }
        if let Some(mut j) = pending {
            rules = resume(c, &mut j, rules, parent, deadline)?;
        }
        if rules.len() > 1 {
            return Err(unsafe_rules());
        }
        if rules
            .first()
            .is_some_and(|r| field(r, "SourceCidrIp") == desired)
        {
            return Ok(());
        }
        let mut j = Journal {
            version: 1,
            region: c.region.clone(),
            group: c.group.clone(),
            old: rules.first().cloned(),
            desired,
            new: None,
            authorize_token: token()?,
            revoke_token: token()?,
        };
        store::write(&c.path("journal"), &j)?;
        resume(c, &mut j, rules, parent, deadline)?;
        Ok(())
    })();
    if result
        .as_ref()
        .is_err_and(|e: &Failure| e.category == "auth")
    {
        store::write(&c.path("auth"), &(epoch() + 1800))?;
    }
    result
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_reserved_and_ambiguous_addresses() {
        for s in ["10.1.2.3", "100.64.0.1", "203.0.113.2", "127.0.0.1"] {
            assert!(!public(s));
        }
        assert!(public("45.67.89.101"));
        assert!(ip(b"45.67.89.101 45.67.89.102").is_err());
    }
    #[test]
    fn classifications_never_return_raw_errors() {
        let f = classify(b"ErrorCode: Forbidden.RAM\nSECRET", 5);
        assert_eq!(f.category, "auth");
        let f = classify(b"{\"Code\":\"Forbidden.RAM\",\"Message\":\"SECRET\"}", 4);
        assert_eq!(f.category, "auth");
        assert!(!serde_json::to_string(&f).unwrap().contains("SECRET"));
    }
}
