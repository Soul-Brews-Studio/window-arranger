// Typed yabai views + env resolution. Mirrors WindowArrangerCore/Models.swift.
// WA_HOME overrides the config/state root so a conformance instance never
// touches the real ~/.config/window-arranger-oracle or ~/.claude/projects.
use serde_json::Value;
use std::path::PathBuf;

pub fn wa_home() -> PathBuf {
    if let Ok(h) = std::env::var("WA_HOME") {
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() {
            return PathBuf::from(h);
        }
    }
    PathBuf::from("/")
}

pub fn conf_dir() -> PathBuf {
    wa_home().join(".config/window-arranger-oracle")
}

pub fn repo_root() -> String {
    std::env::var("WA_ROOT")
        .unwrap_or_else(|_| {
            // Default to CWD, not a literal checkout path that was only ever
            // correct on one machine. Set WA_ROOT to override.
            std::env::current_dir()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| ".".into())
        })
}

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

#[derive(Clone, Copy, Debug)]
pub struct Config {
    pub top: f64,
    pub bottom: f64,
    pub left: f64,
    pub right: f64,
    pub gap: f64,
}

#[derive(Clone, Debug)]
pub struct Display {
    pub id: i64,
    pub index: i64,
    pub frame: Frame,
    pub spaces: Vec<i64>,
}

#[derive(Clone, Debug)]
pub struct Space {
    pub index: i64,
    pub type_: String,
    pub display: i64,
    pub label: Option<String>,
    pub has_focus: bool,
    pub is_visible: bool,
}

#[derive(Clone, Debug)]
pub struct Window {
    pub id: i64,
    pub app: String,
    pub title: String,
    pub space: Option<i64>,
    pub display: Option<i64>,
    pub frame: Option<Frame>,
    pub has_focus: bool,
    pub is_floating: bool,
    pub is_sticky: bool,
    pub is_minimized: bool,
    pub is_hidden: bool,
    pub can_move: Option<bool>,
    pub can_resize: Option<bool>,
}

fn num(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(0.0)
}
fn int(v: &Value, key: &str) -> i64 {
    v.get(key).and_then(|x| x.as_i64()).unwrap_or(0)
}
fn opt_int(v: &Value, key: &str) -> Option<i64> {
    v.get(key).and_then(|x| x.as_i64())
}
fn boolean(v: &Value, key: &str) -> bool {
    v.get(key).and_then(|x| x.as_bool()).unwrap_or(false)
}
fn opt_bool(v: &Value, key: &str) -> Option<bool> {
    v.get(key).and_then(|x| x.as_bool())
}
fn string(v: &Value, key: &str) -> String {
    v.get(key).and_then(|x| x.as_str()).unwrap_or("").to_string()
}
fn opt_string(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(|x| x.as_str()).map(|s| s.to_string())
}

fn frame(v: &Value, key: &str) -> Option<Frame> {
    let f = v.get(key)?;
    if !f.is_object() {
        return None;
    }
    Some(Frame {
        x: num(f, "x"),
        y: num(f, "y"),
        w: num(f, "w"),
        h: num(f, "h"),
    })
}

pub fn parse_displays(text: &str) -> Vec<Display> {
    let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let arr = match v.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    arr.iter()
        .map(|d| Display {
            id: int(d, "id"),
            index: int(d, "index"),
            frame: frame(d, "frame").unwrap_or(Frame {
                x: 0.0,
                y: 0.0,
                w: 0.0,
                h: 0.0,
            }),
            spaces: d
                .get("spaces")
                .and_then(|s| s.as_array())
                .map(|a| a.iter().filter_map(|x| x.as_i64()).collect())
                .unwrap_or_default(),
        })
        .collect()
}

pub fn parse_spaces(text: &str) -> Vec<Space> {
    let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let arr = match v.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    arr.iter()
        .map(|s| Space {
            index: int(s, "index"),
            type_: string(s, "type"),
            display: int(s, "display"),
            label: opt_string(s, "label"),
            has_focus: boolean(s, "has-focus"),
            is_visible: boolean(s, "is-visible"),
        })
        .collect()
}

pub fn parse_windows(text: &str) -> Vec<Window> {
    let v: Value = serde_json::from_str(text).unwrap_or(Value::Null);
    let arr = match v.as_array() {
        Some(a) => a,
        None => return vec![],
    };
    arr.iter()
        .map(|w| Window {
            id: int(w, "id"),
            app: string(w, "app"),
            title: string(w, "title"),
            space: opt_int(w, "space"),
            display: opt_int(w, "display"),
            frame: frame(w, "frame"),
            has_focus: boolean(w, "has-focus"),
            is_floating: boolean(w, "is-floating"),
            is_sticky: boolean(w, "is-sticky"),
            is_minimized: boolean(w, "is-minimized"),
            is_hidden: boolean(w, "is-hidden"),
            can_move: opt_bool(w, "can-move"),
            can_resize: opt_bool(w, "can-resize"),
        })
        .collect()
}
