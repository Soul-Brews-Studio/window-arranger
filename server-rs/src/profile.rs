// Oracle profile — "assign each oracle to a space". Port of the profile half of
// lib/oracle-profile.ts (snapshotProfile / arrangeByProfile / saveProfile /
// loadProfile). Rules kept as raw Values so unknown keys survive.
use crate::models::{conf_dir, Window};
use crate::pins;
use crate::yabai;
use serde_json::{json, Value};
use std::collections::BTreeSet;

pub fn path() -> String {
    conf_dir()
        .join("oracle-profile.json")
        .to_string_lossy()
        .to_string()
}

pub fn load() -> Vec<Value> {
    match std::fs::read_to_string(path()) {
        Ok(text) => match serde_json::from_str::<Value>(&text) {
            Ok(Value::Array(a)) => a,
            _ => vec![],
        },
        Err(_) => vec![],
    }
}

const SHELLS: [&str; 5] = ["zsh", "sh", "-zsh", "bash", "-bash"];

// Build a profile from live positions: each fleet oracle → its space. Dedup by
// lowercased title (first wins). Spaced titles (status panes) are skipped.
pub fn snapshot_rules(windows: &[Window]) -> Vec<Value> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut rules: Vec<Value> = vec![];
    for w in windows {
        if w.app != "WezTerm" || w.space.is_none() {
            continue;
        }
        let title = w.title.trim();
        let key = title.to_lowercase();
        if title.is_empty() || SHELLS.contains(&key.as_str()) || seen.contains(&key) {
            continue;
        }
        if title.contains(' ') {
            continue;
        }
        seen.insert(key);
        rules.push(json!({ "match": title, "space": w.space.unwrap() }));
    }
    rules
}

// Overwrite the profile, backing up any existing one first. Returns backup path.
pub fn save(rules: &[Value]) -> Result<Option<String>, String> {
    let p = path();
    std::fs::create_dir_all(conf_dir()).map_err(|e| e.to_string())?;
    let mut backup: Option<String> = None;
    if std::path::Path::new(&p).exists() {
        let b = format!("{}.bak.{}", p, pins::stamp());
        let _ = std::fs::copy(&p, &b);
        backup = Some(b);
    }
    let text = serde_json::to_string_pretty(&Value::Array(rules.to_vec()))
        .map_err(|e| e.to_string())?;
    std::fs::write(&p, text + "\n").map_err(|e| e.to_string())?;
    Ok(backup)
}

// Restore: move each matched window to its rule's target (label > space > display).
// First matching rule wins (file order). matched counts any rule match; moved
// counts only windows with a resolvable target.
pub fn arrange_by_profile(windows: &[Window], rules: &[Value]) -> (i64, i64) {
    let mut moved = 0;
    let mut matched = 0;
    for w in windows {
        let title = w.title.to_lowercase();
        let app = w.app.to_lowercase();
        let rule = rules.iter().find(|r| {
            let m = r
                .get("match")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_lowercase();
            pins::has(&title, &m) || pins::has(&app, &m)
        });
        let rule = match rule {
            Some(r) => r,
            None => continue,
        };
        matched += 1;
        let label = rule.get("label").and_then(|v| v.as_str());
        let space = rule
            .get("space")
            .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)));
        let display = rule
            .get("display")
            .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)));
        let grid = rule.get("grid").and_then(|v| v.as_str());
        if let Some(label) = label {
            yabai::move_window_to_space(w.id, label);
        } else if let Some(space) = space {
            yabai::move_window_to_space(w.id, &space.to_string());
        } else if let Some(display) = display {
            yabai::move_window_to_display(w.id, display);
            if let Some(grid) = grid {
                yabai::set_grid(w.id, grid);
            }
        } else {
            continue;
        }
        moved += 1;
    }
    (moved, matched)
}
