// 📌 Pin system — port of lib/oracle-profile.ts's pins (cross-checked against
// Pins.swift). Rules are kept as raw JSON Values so unknown fields (note, future
// keys) survive rewrites. pins.json is hand-edited live — re-read every tick.
use crate::models::{conf_dir, Display, Space, Window};
use crate::profile;
use crate::yabai;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

pub const SYNTH_LABEL_PREFIX: &str = "⭐";

fn file_lock() -> &'static Mutex<()> {
    static L: OnceLock<Mutex<()>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(()))
}

pub fn pins_path() -> String {
    conf_dir().join("pins.json").to_string_lossy().to_string()
}
pub fn pins_off_path() -> String {
    conf_dir().join("pins.json.off").to_string_lossy().to_string()
}

fn exists(p: &str) -> bool {
    std::path::Path::new(p).exists()
}

pub fn stamp() -> String {
    // ISO8601-ish UTC with colons/dots → dashes. Only used for backup filenames
    // (never compared by the suite), so uniqueness is all that matters.
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    format!("{}", ms)
}

// --- rule accessors on a raw Value ---
fn r_str<'a>(r: &'a Value, k: &str) -> Option<&'a str> {
    r.get(k).and_then(|v| v.as_str())
}
fn r_int(r: &Value, k: &str) -> Option<i64> {
    r.get(k)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}
fn r_bool(r: &Value, k: &str) -> bool {
    r.get(k).and_then(|v| v.as_bool()).unwrap_or(false)
}
fn r_match(r: &Value) -> &str {
    r_str(r, "match").unwrap_or("")
}

pub fn is_synthetic_label(l: &str) -> bool {
    l.starts_with(SYNTH_LABEL_PREFIX)
}

// JS "".includes("") === true — empty needle matches everything.
pub fn has(haystack: &str, needle: &str) -> bool {
    needle.is_empty() || haystack.contains(needle)
}

pub fn matches(w: &Window, pin: &Value) -> bool {
    let title = w.title.trim();
    if let Some(app) = r_str(pin, "app") {
        return has(&w.app.to_lowercase(), &app.to_lowercase())
            && has(&title.to_lowercase(), &r_match(pin).to_lowercase());
    }
    w.app == "WezTerm"
        && !title.is_empty()
        && has(&title.to_lowercase(), &r_match(pin).to_lowercase())
}

pub fn enabled() -> bool {
    exists(&pins_path())
}

fn active_file() -> String {
    if exists(&pins_path()) || !exists(&pins_off_path()) {
        pins_path()
    } else {
        pins_off_path()
    }
}

fn read_array(path: &str) -> Vec<Value> {
    match std::fs::read_to_string(path) {
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(Value::Array(a)) => a,
            _ => vec![],
        },
        Err(_) => vec![],
    }
}

// Active rules from pins.json ONLY (matches loadPins). Missing/parse-error → [].
pub fn load() -> Vec<Value> {
    read_array(&pins_path())
}

pub fn rule_count() -> i64 {
    let path = if exists(&pins_path()) {
        pins_path()
    } else {
        pins_off_path()
    };
    read_array(&path).len() as i64
}

fn write_rules(rules: &[Value], path: &str) {
    if let Ok(text) = serde_json::to_string_pretty(&Value::Array(rules.to_vec())) {
        let _ = std::fs::write(path, text + "\n");
    }
}

pub fn set_enabled(on: bool) -> bool {
    let _g = file_lock().lock().unwrap();
    let p = pins_path();
    let off = pins_off_path();
    if on {
        if !exists(&p) && exists(&off) {
            let _ = std::fs::rename(&off, &p);
        }
    } else if exists(&p) {
        if exists(&off) {
            let _ = std::fs::rename(&off, format!("{}.bak.{}", off, stamp()));
        }
        let _ = std::fs::rename(&p, &off);
    }
    enabled()
}

const SHELLS: [&str; 5] = ["zsh", "sh", "-zsh", "bash", "-bash"];
fn is_shell(t: &str) -> bool {
    SHELLS.contains(&t)
}

fn space_pin_tag(label: &str) -> String {
    format!("space-pin:{}", label)
}

// ⭐ space-pin: one origin-tagged rule per unique window on the space.
pub fn set_space_pin(label: &str, windows: &[Window], pinned: bool) -> i64 {
    let _g = file_lock().lock().unwrap();
    let tag = space_pin_tag(label);
    let file = active_file();
    let rest: Vec<Value> = read_array(&file)
        .into_iter()
        .filter(|r| r_str(r, "origin") != Some(tag.as_str()))
        .collect();
    let mut added: Vec<Value> = vec![];
    if pinned {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        for w in windows {
            let title = w.title.trim();
            if title.is_empty() || is_shell(&title.to_lowercase()) {
                continue;
            }
            let key = format!("{}|{}", w.app, title.to_lowercase());
            if seen.contains(&key) {
                continue;
            }
            seen.insert(key);
            let mut rule = serde_json::Map::new();
            rule.insert("match".into(), json!(title));
            rule.insert("label".into(), json!(label));
            rule.insert("origin".into(), json!(tag));
            if w.app != "WezTerm" {
                rule.insert("app".into(), json!(w.app));
            }
            added.push(Value::Object(rule));
        }
    }
    let mut out = rest;
    let count = added.len() as i64;
    out.extend(added);
    write_rules(&out, &file);
    count
}

pub struct EnforceResult {
    pub moved: Vec<String>,
    pub moved_from: Vec<i64>,
}

const IDLE_THRESHOLD: f64 = 300.0;
const IDLE_VISIBLE_MULT: f64 = 3.0;

pub fn enforce(
    windows: &[Window],
    spaces: &[Space],
    displays: &[Display],
    names: &BTreeMap<String, String>,
    pins: &[Value],
    idle: Option<f64>,
) -> EnforceResult {
    let mut result = EnforceResult {
        moved: vec![],
        moved_from: vec![],
    };
    let idle_gate_ok = |pin: &Value, w: &Window| -> bool {
        if !r_bool(pin, "whenIdleOnly") {
            return true;
        }
        let idle = match idle {
            Some(v) => v,
            None => return false,
        };
        let visible = spaces
            .iter()
            .find(|s| Some(s.index) == w.space)
            .map(|s| s.is_visible)
            .unwrap_or(false);
        let need = IDLE_THRESHOLD * if visible { IDLE_VISIBLE_MULT } else { 1.0 };
        idle >= need
    };
    for pin in pins {
        if r_str(pin, "displayName").is_some() || r_int(pin, "display").is_some() {
            let target_disp: Option<i64> = if let Some(want_name) = r_str(pin, "displayName") {
                names
                    .iter()
                    .find(|(_, v)| v.as_str() == want_name)
                    .and_then(|(k, _)| k.parse::<i64>().ok())
                    .and_then(|id| displays.iter().find(|d| d.id == id).map(|d| d.index))
            } else {
                r_int(pin, "display")
            };
            let disp = match target_disp {
                Some(d) if displays.iter().any(|x| x.index == d) => d,
                _ => continue,
            };
            for w in windows.iter().filter(|w| matches(w, pin)) {
                let from = displays
                    .iter()
                    .find(|d| w.space.map(|s| d.spaces.contains(&s)).unwrap_or(false))
                    .map(|d| d.index);
                if from == Some(disp) {
                    continue;
                }
                if !idle_gate_ok(pin, w) {
                    continue;
                }
                if let Some(s) = w.space {
                    result.moved_from.push(s);
                }
                yabai::move_window_to_display(w.id, disp);
                if let Some(grid) = r_str(pin, "grid") {
                    yabai::set_grid(w.id, grid);
                }
                result
                    .moved
                    .push(format!("{} (d{}→d{})", w.title.trim(), from.unwrap_or(-1), disp));
            }
            continue;
        }
        let target: Option<i64> = if let Some(label) = r_str(pin, "label") {
            spaces.iter().find(|s| s.label.as_deref() == Some(label)).map(|s| s.index)
        } else {
            r_int(pin, "space")
        };
        let dst = match target {
            Some(d) if spaces.iter().any(|s| s.index == d) => d,
            _ => continue,
        };
        for w in windows.iter().filter(|w| matches(w, pin)) {
            if w.space == Some(dst) {
                continue;
            }
            if !idle_gate_ok(pin, w) {
                continue;
            }
            if let Some(s) = w.space {
                result.moved_from.push(s);
            }
            yabai::move_window_to_space(w.id, &dst.to_string());
            result
                .moved
                .push(format!("{} (s{}→s{})", w.title.trim(), w.space.unwrap_or(-1), dst));
        }
    }
    result
}

pub fn park_now(
    windows: &[Window],
    spaces: &[Space],
    displays: &[Display],
    names: &BTreeMap<String, String>,
) -> EnforceResult {
    let park_pins: Vec<Value> = load()
        .into_iter()
        .filter(|p| r_bool(p, "whenIdleOnly"))
        .collect();
    if park_pins.is_empty() {
        return EnforceResult {
            moved: vec![],
            moved_from: vec![],
        };
    }
    enforce(windows, spaces, displays, names, &park_pins, Some(f64::INFINITY))
}

// --- auto-heal (60s tick; never runs in --shadow) ---
pub fn auto_heal(windows: &[Window], spaces: &[Space]) {
    heal_lost_labels(windows, spaces);
    heal_pure_renumber(windows, spaces);
}

fn heal_lost_labels(windows: &[Window], spaces: &[Space]) {
    let live_labels: BTreeSet<String> = spaces
        .iter()
        .filter_map(|s| s.label.clone())
        .filter(|l| !l.is_empty())
        .collect();
    for pin in load() {
        let label = match r_str(&pin, "label") {
            Some(l) => l,
            None => continue,
        };
        if live_labels.contains(label) || r_bool(&pin, "whenIdleOnly") {
            continue;
        }
        let hits: Vec<&Window> = windows.iter().filter(|w| matches(w, &pin)).collect();
        let hit_spaces: BTreeSet<i64> = hits.iter().filter_map(|w| w.space).collect();
        if hit_spaces.len() != 1 {
            continue;
        }
        let home = *hit_spaces.iter().next().unwrap();
        yabai::label_space(home, label);
    }
}

fn heal_pure_renumber(windows: &[Window], _spaces: &[Space]) {
    let _g = file_lock().lock().unwrap();
    let profile_path = profile::path();
    let profile_raw = read_array(&profile_path);
    if profile_raw.is_empty() {
        return;
    }
    let fleet: Vec<&Window> = windows
        .iter()
        .filter(|w| w.app == "WezTerm" && !w.title.trim().is_empty())
        .collect();
    let mut mapping: BTreeMap<i64, i64> = BTreeMap::new();
    for rule in &profile_raw {
        let saved = match r_int(rule, "space") {
            Some(s) => s,
            None => continue,
        };
        let m = r_match(rule).to_lowercase();
        let members: Vec<&&Window> = fleet
            .iter()
            .filter(|w| has(&w.title.to_lowercase(), &m))
            .collect();
        let live_spaces: BTreeSet<i64> = members.iter().filter_map(|w| w.space).collect();
        if live_spaces.len() != 1 {
            continue;
        }
        let live = *live_spaces.iter().next().unwrap();
        if let Some(prior) = mapping.get(&saved) {
            if *prior != live {
                return;
            }
        }
        mapping.insert(saved, live);
    }
    let moved_groups = mapping.iter().filter(|(k, v)| k != v).count();
    if moved_groups < 2 {
        return;
    }
    let targets: Vec<i64> = mapping.values().cloned().collect();
    let unique: BTreeSet<i64> = targets.iter().cloned().collect();
    if unique.len() != targets.len() {
        return;
    }
    // Rewrite the profile (backup first), unknown keys intact.
    let remapped: Vec<Value> = profile_raw
        .iter()
        .map(|rule| {
            let mut r = rule.clone();
            if let Some(s) = r_int(rule, "space") {
                if let Some(new) = mapping.get(&s) {
                    if *new != s {
                        r["space"] = json!(*new);
                    }
                }
            }
            r
        })
        .collect();
    let _ = std::fs::copy(&profile_path, format!("{}.bak.{}", profile_path, stamp()));
    write_rules(&remapped, &profile_path);
    // Shift raw-index pin rules by the same mapping.
    let file = active_file();
    let arr = read_array(&file);
    if !arr.is_empty() {
        let mut changed = false;
        let shifted: Vec<Value> = arr
            .iter()
            .map(|rule| {
                let mut r = rule.clone();
                if let Some(s) = r_int(rule, "space") {
                    if let Some(new) = mapping.get(&s) {
                        if *new != s {
                            r["space"] = json!(*new);
                            if let Some(origin) = r_str(rule, "origin") {
                                if origin.starts_with("space-pin:") {
                                    r["origin"] = json!(format!("space-pin:s{}", new));
                                }
                            }
                            changed = true;
                        }
                    }
                }
                r
            })
            .collect();
        if changed {
            write_rules(&shifted, &file);
        }
    }
}
