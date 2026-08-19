// The single yabai exec choke point (mirrors WindowArrangerCore/YabaiClient.swift
// + lib/yabai.ts). Queries read live compositor state; writes tolerate benign
// "no-op" failures (a window/space that vanished mid-flight). YABAI_BIN points
// the conformance suite at the fake binary so every implementation sees one world.
use crate::models::Config;
use std::process::Command;

fn binary_path() -> Option<String> {
    if let Ok(o) = std::env::var("YABAI_BIN") {
        if !o.is_empty() {
            return Some(o);
        }
    }
    for c in ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"] {
        if std::fs::metadata(c).map(|m| m.is_file()).unwrap_or(false) {
            return Some(c.to_string());
        }
    }
    None
}

struct RunResult {
    stdout: String,
    stderr: String,
    code: i32,
}

fn run(args: &[&str]) -> Option<RunResult> {
    let bin = binary_path()?;
    let out = Command::new(bin).args(args).output().ok()?;
    Some(RunResult {
        stdout: String::from_utf8_lossy(&out.stdout).to_string(),
        stderr: String::from_utf8_lossy(&out.stderr).to_string(),
        code: out.status.code().unwrap_or(-1),
    })
}

pub fn is_available() -> bool {
    binary_path().is_some()
}

// Raw query output for /api/state passthrough.
pub fn query_raw(what: &str) -> Option<String> {
    run(&["-m", "query", what]).map(|r| r.stdout)
}

pub fn query_config(key: &str) -> f64 {
    run(&["-m", "config", key])
        .and_then(|r| r.stdout.trim().parse::<f64>().ok())
        .unwrap_or(0.0)
}

pub fn global_config() -> Config {
    Config {
        top: query_config("top_padding"),
        bottom: query_config("bottom_padding"),
        left: query_config("left_padding"),
        right: query_config("right_padding"),
        gap: query_config("window_gap"),
    }
}

// --- writes (best-effort; benign no-op failures tolerated) ---

fn mutate(args: &[&str]) {
    let _ = run(args);
}

// JS Math.round = floor(x + 0.5) — half toward +∞. Rust's round() is
// half-away-from-zero, which drifts 1px on negative .5 coords (portrait display).
pub fn js_round(x: f64) -> i64 {
    (x + 0.5).floor() as i64
}

pub fn move_window_abs(id: i64, x: f64, y: f64) {
    mutate(&[
        "-m",
        "window",
        &id.to_string(),
        "--move",
        &format!("abs:{}:{}", js_round(x), js_round(y)),
    ]);
}

pub fn resize_window_abs(id: i64, w: f64, h: f64) {
    mutate(&[
        "-m",
        "window",
        &id.to_string(),
        "--resize",
        &format!("abs:{}:{}", js_round(w), js_round(h)),
    ]);
}

pub fn set_layout(space_index: i64, layout: &str) {
    mutate(&["-m", "space", &space_index.to_string(), "--layout", layout]);
}

pub fn move_window_to_display(id: i64, display: i64) {
    mutate(&[
        "-m",
        "window",
        &id.to_string(),
        "--display",
        &display.to_string(),
    ]);
}

pub fn move_window_to_space(id: i64, selector: &str) {
    mutate(&["-m", "window", &id.to_string(), "--space", selector]);
}

pub fn set_grid(id: i64, grid: &str) {
    mutate(&["-m", "window", &id.to_string(), "--grid", grid]);
}

pub fn label_space(index: i64, label: &str) {
    mutate(&["-m", "space", &index.to_string(), "--label", label]);
}

// Checked focus — returns None on success or a tolerated no-op, else stderr text.
pub fn focus_space_checked(index: i64) -> Option<String> {
    let r = match run(&["-m", "space", "--focus", &index.to_string()]) {
        Some(r) => r,
        None => return Some("yabai binary not found".to_string()),
    };
    if r.code == 0 {
        return None;
    }
    let stderr = r.stderr.trim().to_string();
    if is_noop(&stderr) {
        return None;
    }
    if stderr.is_empty() {
        Some(format!("yabai exited {}", r.code))
    } else {
        Some(stderr)
    }
}

fn is_noop(stderr: &str) -> bool {
    let s = stderr.to_lowercase();
    s.contains("already")
        || s.contains("could not find")
        || s.contains("could not locate")
        || s.contains("does not exist")
}
