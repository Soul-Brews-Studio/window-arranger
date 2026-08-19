// active-first ordering — port of lib/bsp.ts orderByHumanRecency (cross-checked
// against Recency.swift). Orders windows by "where the human is working": the
// last HUMAN-typed message timestamp in each oracle's Claude Code session log
// (~/.claude/projects/<repo>/*.jsonl, tail-scanned), focused window = most recent.
use crate::models::{wa_home, Window};
use serde_json::Value;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::time::UNIX_EPOCH;

fn project_base() -> std::path::PathBuf {
    wa_home().join(".claude/projects")
}

// title → dir key: lowercase, collapse whitespace runs to '-' (JS /\s+/g).
fn normalize_title(title: &str) -> String {
    let mut out = String::new();
    let mut in_ws = false;
    for ch in title.chars() {
        if ch.is_whitespace() {
            if !in_ws {
                out.push('-');
                in_ws = true;
            }
        } else {
            out.extend(ch.to_lowercase());
            in_ws = false;
        }
    }
    out
}

fn dir_for_title(title: &str, dirs: &[String]) -> Option<String> {
    let t = normalize_title(title);
    let suffix1 = format!("-{}", t);
    let suffix2 = format!("-{}-oracle", t);
    dirs.iter()
        .find(|name| {
            let l = name.to_lowercase();
            l.ends_with(&suffix1) || l.ends_with(&suffix2)
        })
        .cloned()
}

fn list_dirs(base: &std::path::Path) -> Vec<String> {
    match fs::read_dir(base) {
        Ok(rd) => rd
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .collect(),
        Err(_) => vec![],
    }
}

fn mtime_ms(path: &std::path::Path) -> f64 {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

fn latest_jsonl(dir: &std::path::Path) -> Option<std::path::PathBuf> {
    let mut best: Option<std::path::PathBuf> = None;
    let mut best_m = f64::NEG_INFINITY;
    for e in fs::read_dir(dir).ok()?.flatten() {
        let p = e.path();
        if p.extension().and_then(|x| x.to_str()) != Some("jsonl") {
            continue;
        }
        let m = mtime_ms(&p);
        if m > best_m {
            best_m = m;
            best = Some(p);
        }
    }
    best
}

fn human_text(v: &Value) -> Option<String> {
    if v.get("type").and_then(|x| x.as_str()) != Some("user") {
        return None;
    }
    let content = v.get("message").and_then(|m| m.get("content"))?;
    if let Some(s) = content.as_str() {
        if s.trim().is_empty() {
            return None;
        }
        return Some(s.to_string());
    }
    if let Some(arr) = content.as_array() {
        for item in arr {
            if item.get("type").and_then(|x| x.as_str()) == Some("text") {
                if let Some(t) = item.get("text").and_then(|x| x.as_str()) {
                    if !t.trim().is_empty() {
                        return Some(t.to_string());
                    }
                }
                break;
            }
        }
    }
    None
}

// Scan the tail (last `window` bytes) for the newest qualifying human message.
// Returns 0.0 when nothing qualifies.
fn last_typed_time(path: &std::path::Path, window: u64) -> f64 {
    let mut file = match fs::File::open(path) {
        Ok(f) => f,
        Err(_) => return 0.0,
    };
    let size = file.seek(SeekFrom::End(0)).unwrap_or(0);
    let start = if size > window { size - window } else { 0 };
    if file.seek(SeekFrom::Start(start)).is_err() {
        return 0.0;
    }
    let mut buf = Vec::new();
    if file.read_to_end(&mut buf).is_err() {
        return 0.0;
    }
    let text = String::from_utf8_lossy(&buf);
    for line in text.split('\n').rev() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let v: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if human_text(&v).is_none() {
            continue;
        }
        if let Some(ts) = v.get("timestamp").and_then(|x| x.as_str()) {
            if let Some(ms) = parse_rfc3339_ms(ts) {
                return ms;
            }
        }
    }
    0.0
}

fn last_human_time(path: &std::path::Path) -> f64 {
    let t = last_typed_time(path, 65536);
    if t > 0.0 {
        return t;
    }
    mtime_ms(path)
}

pub fn order(windows: &[Window]) -> Vec<Window> {
    let base = project_base();
    let dirs = list_dirs(&base);
    let mut scored: Vec<(usize, Window, f64)> = windows
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let t = if w.has_focus {
                f64::INFINITY
            } else {
                match dir_for_title(&w.title, &dirs) {
                    Some(d) => match latest_jsonl(&base.join(d)) {
                        Some(j) => last_human_time(&j),
                        None => 0.0,
                    },
                    None => 0.0,
                }
            };
            (i, w.clone(), t)
        })
        .collect();
    // Stable sort descending by time (ties keep original order — matches JS
    // Array.sort stability, which the conformance fixtures rely on).
    scored.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
    scored.into_iter().map(|(_, w, _)| w).collect()
}

// Minimal RFC3339 → epoch milliseconds. Handles "…Z", "±HH:MM", and optional
// fractional seconds. Hand-rolled epoch math (no chrono), per the port spec.
fn parse_rfc3339_ms(s: &str) -> Option<f64> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let year: i64 = s.get(0..4)?.parse().ok()?;
    if bytes[4] != b'-' {
        return None;
    }
    let month: i64 = s.get(5..7)?.parse().ok()?;
    if bytes[7] != b'-' {
        return None;
    }
    let day: i64 = s.get(8..10)?.parse().ok()?;
    if bytes[10] != b'T' && bytes[10] != b't' && bytes[10] != b' ' {
        return None;
    }
    let hour: i64 = s.get(11..13)?.parse().ok()?;
    let min: i64 = s.get(14..16)?.parse().ok()?;
    let sec: i64 = s.get(17..19)?.parse().ok()?;

    let mut idx = 19;
    let mut frac_ms = 0.0f64;
    if idx < bytes.len() && bytes[idx] == b'.' {
        idx += 1;
        let mut frac_str = String::new();
        while idx < bytes.len() && bytes[idx].is_ascii_digit() {
            frac_str.push(bytes[idx] as char);
            idx += 1;
        }
        if !frac_str.is_empty() {
            let denom = 10f64.powi(frac_str.len() as i32);
            let numer: f64 = frac_str.parse().ok()?;
            frac_ms = numer / denom * 1000.0;
        }
    }

    // timezone offset
    let mut offset_secs: i64 = 0;
    if idx < bytes.len() {
        match bytes[idx] {
            b'Z' | b'z' => {}
            b'+' | b'-' => {
                let sign = if bytes[idx] == b'-' { -1 } else { 1 };
                let oh: i64 = s.get(idx + 1..idx + 3)?.parse().ok()?;
                let om: i64 = s.get(idx + 4..idx + 6)?.parse().ok()?;
                offset_secs = sign * (oh * 3600 + om * 60);
            }
            _ => {}
        }
    }

    let days = days_from_civil(year, month, day);
    let total_secs = days * 86400 + hour * 3600 + min * 60 + sec - offset_secs;
    Some(total_secs as f64 * 1000.0 + frac_ms)
}

// Howard Hinnant's days_from_civil (proleptic Gregorian, days since 1970-01-01).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}
