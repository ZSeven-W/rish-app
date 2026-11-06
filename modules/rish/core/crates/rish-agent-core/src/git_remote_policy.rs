//! Shared remote-address policy; native hosts retain transport and credential IO.
//!
//! HTTP(S) preserves the origin's path escapes and explicit port, lowercases
//! scheme/host, and percent-encodes raw path bytes outside URI path characters
//! like Foundation.
//! SSH preserves `url` verbatim, as the existing iOS adapter
//! does; `canonical_url` is its separate credential-comparison representation.
//! This deliberately parses a restricted grammar instead of normalizing away
//! dot segments or default ports before the policy has examined them.

use std::net::IpAddr;

use serde_json::{json, Value};

use crate::{strict_json::parse_arguments, workspace_tool::path_control_or_format};

const MAX_URL_UNITS: usize = 4096;
const MAX_PATH_UNITS: usize = 2048;

/// Exact `{ "url": string }`, or `{ "url": string, "form": true }`.
/// Form input alone trims surrounding Unicode whitespace and has the existing
/// 2048 UTF-8 byte form limit; persisted origins must already be canonical input.
pub fn reduce_json(input: &str) -> String {
    let value = (|| {
        if input.len() > 32 * 1024 {
            return None;
        }
        let request = parse_arguments(input)?;
        let form = request.get("form");
        if (request.len() != 1 && !(request.len() == 2 && form == Some(&Value::Bool(true))))
            || (form.is_some() && form != Some(&Value::Bool(true)))
        {
            return None;
        }
        let url = request.get("url")?.as_str()?;
        let url = if form.is_some() {
            let trimmed = url.trim();
            if trimmed.len() > 2048 {
                return None;
            }
            trimmed
        } else {
            url
        };
        parse_remote(url)
    })();
    match value {
        Some(value) => json!({"ok": true, "value": value}).to_string(),
        None => json!({"ok": false, "error": "E_PROJECT_INVALID"}).to_string(),
    }
}

fn parse_remote(input: &str) -> Option<Value> {
    if input.is_empty()
        || input.encode_utf16().count() > MAX_URL_UNITS
        || input.contains('\\')
        || input
            .chars()
            .any(|c| c.is_whitespace() || path_control_or_format(c))
    {
        return None;
    }
    // A literal SCP path may itself contain "://". Only a supported prefix
    // selects URI syntax; an unsupported URI still fails SCP user/host checks.
    let url_parts = input.split_once("://").filter(|(scheme, _)| {
        matches!(
            scheme.to_ascii_lowercase().as_str(),
            "https" | "http" | "ssh"
        )
    });
    if let Some((scheme, rest)) = url_parts {
        let scheme = scheme.to_ascii_lowercase();
        if !matches!(scheme.as_str(), "https" | "http" | "ssh") || rest.contains(['?', '#']) {
            return None;
        }
        let slash = rest.find('/')?;
        let authority = &rest[..slash];
        let raw_path = &rest[slash..];
        let path = decoded_path(raw_path, true)?;
        if scheme == "ssh" {
            let (raw_user, server) = authority.split_once('@')?;
            let user = decode(raw_user)?;
            if !valid_user(&user) || server.contains('@') {
                return None;
            }
            let (host, port, _) = server_parts(server, 22)?;
            if !ssh_host(&host) {
                return None;
            }
            Some(ssh_value(input, &host, port, &user, &path, false))
        } else {
            if authority.contains('@') || path.trim_matches('/').is_empty() {
                return None;
            }
            let default_port = if scheme == "https" { 443 } else { 80 };
            let (host, port, written_port) = server_parts(authority, default_port)?;
            let valid = if scheme == "https" {
                public_dns(&host) && port == 443
            } else {
                private_literal(&host)
            };
            if !valid {
                return None;
            }
            let port_suffix = written_port.map(|p| format!(":{p}")).unwrap_or_default();
            let path_url = encode_path(raw_path);
            let url = format!("{scheme}://{}{port_suffix}{path_url}", bracket_host(&host));
            // Persisted origins are validated again before transport. Encoding
            // can expand a valid form value past that same URL budget; refuse
            // it here instead of returning an origin that cannot be reopened.
            if url.encode_utf16().count() > MAX_URL_UNITS {
                return None;
            }
            Some(json!({"url": url, "canonical_url": url, "scheme": scheme,
                "host": host, "port": port, "username": null, "path": path, "scp": false}))
        }
    } else {
        // Existing SCP syntax requires a username and cannot spell an IPv6
        // literal: its first colon separates the host from the remote path.
        let (user, rest) = input.split_once('@')?;
        let (host, path) = rest.split_once(':')?;
        if rest.contains('@') || !valid_user(user) {
            return None;
        }
        let host = host.to_ascii_lowercase();
        if !ssh_host(&host) {
            return None;
        }
        // SCP paths are literal, not URI percent escapes.
        if !valid_path(path, false) {
            return None;
        }
        Some(ssh_value(input, &host, 22, user, path, true))
    }
}

fn server_parts(server: &str, default_port: u16) -> Option<(String, u16, Option<&str>)> {
    let (host, port) = if let Some(v6) = server.strip_prefix('[') {
        let end = v6.find(']')?;
        let host = &v6[..end];
        if !matches!(host.parse::<IpAddr>(), Ok(IpAddr::V6(_))) {
            return None;
        }
        let suffix = &v6[end + 1..];
        let port = if suffix.is_empty() {
            None
        } else {
            Some(suffix.strip_prefix(':')?)
        };
        (host, port)
    } else {
        if server.contains(['[', ']']) {
            return None;
        }
        match server.split_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (server, None),
        }
    };
    if host.is_empty() || host.len() > 253 {
        return None;
    }
    let effective = match port {
        Some(value) if !value.is_empty() && value.bytes().all(|c| c.is_ascii_digit()) => {
            let parsed = value.parse::<u16>().ok()?;
            if parsed == 0 {
                return None;
            }
            parsed
        }
        Some(_) => return None,
        None => default_port,
    };
    Some((host.to_ascii_lowercase(), effective, port))
}

fn dns_name(host: &str) -> bool {
    host.len() <= 253
        && host.contains('.')
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
}

fn public_dns(host: &str) -> bool {
    dns_name(host)
        && host.parse::<IpAddr>().is_err()
        // Numeric alternate IPv4 spellings are not public DNS identities.
        && !host.bytes().all(|c| c.is_ascii_digit() || c == b'.')
        && ![".local", ".internal", ".localhost"].iter().any(|suffix| host.ends_with(suffix))
}

fn ssh_host(host: &str) -> bool {
    host != "localhost" && (host.parse::<IpAddr>().is_ok() || dns_name(host))
}

fn private_literal(host: &str) -> bool {
    if host == "localhost" {
        return true;
    }
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
        Ok(IpAddr::V6(ip)) => {
            ip.is_loopback() || ip.is_unicast_link_local() || ip.is_unique_local()
        }
        Err(_) => false,
    }
}

fn valid_user(user: &str) -> bool {
    !user.is_empty()
        && user.encode_utf16().count() <= 255
        && !user.contains(['/', '@', '\\', ':'])
        && !user
            .chars()
            .any(|c| c.is_whitespace() || path_control_or_format(c))
}

fn valid_path(path: &str, absolute: bool) -> bool {
    !path.is_empty()
        && path.encode_utf16().count() <= MAX_PATH_UNITS
        && (!absolute || path.starts_with('/'))
        && !path.contains('\\')
        && !path.chars().any(path_control_or_format)
        && !path.split('/').any(|part| matches!(part, "." | ".."))
}

fn decoded_path(raw: &str, absolute: bool) -> Option<String> {
    let path = decode(raw)?;
    valid_path(&path, absolute).then_some(path)
}

/// Foundation's absolute HTTP URL preserves RFC 3986 path characters and
/// encodes everything else, including raw Unicode and ASCII `<>"{}|^[]`.
/// Percent escapes have already been validated; retain their original case.
fn encode_path(raw: &str) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut output = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(
                byte,
                b'-' | b'.'
                    | b'_'
                    | b'~'
                    | b'!'
                    | b'$'
                    | b'&'
                    | b'\''
                    | b'('
                    | b')'
                    | b'*'
                    | b'+'
                    | b','
                    | b';'
                    | b'='
                    | b':'
                    | b'@'
                    | b'/'
                    | b'%'
            )
        {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push(HEX[(byte >> 4) as usize] as char);
            output.push(HEX[(byte & 0xf) as usize] as char);
        }
    }
    output
}

/// URI decoding is only for validation/projection, never rewriting an origin.
fn decode(raw: &str) -> Option<String> {
    let mut bytes = Vec::with_capacity(raw.len());
    let mut input = raw.bytes();
    while let Some(byte) = input.next() {
        if byte == b'%' {
            let hi = (input.next()? as char).to_digit(16)?;
            let lo = (input.next()? as char).to_digit(16)?;
            bytes.push((hi * 16 + lo) as u8);
        } else {
            bytes.push(byte);
        }
    }
    String::from_utf8(bytes).ok()
}

fn bracket_host(host: &str) -> String {
    if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_owned()
    }
}

fn ssh_value(input: &str, host: &str, port: u16, user: &str, path: &str, scp: bool) -> Value {
    let port_suffix = if port == 22 {
        String::new()
    } else {
        format!(":{port}")
    };
    let canonical = format!(
        "ssh://{user}@{}{port_suffix}/{}",
        bracket_host(host),
        path.strip_prefix('/').unwrap_or(path)
    );
    json!({"url": input, "canonical_url": canonical, "scheme": "ssh", "host": host,
        "port": port, "username": user, "path": path, "scp": scp})
}

#[cfg(test)]
#[path = "git_remote_policy_tests.rs"]
mod tests;
