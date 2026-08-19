// /api/who — the FROZEN v1.4 contract (census polls at 1 Hz + republishes it).
// Port of lib/who.ts computeWhoReport. Wire key order matches the TS return
// literal: ts, fleet, windows, displays, spaces, profile, idle.
use crate::displays;
use crate::engine::Sample;
use crate::idle;
use crate::pins;
use crate::profile;
use serde_json::{json, Map, Value};

const SHELLS: [&str; 5] = ["zsh", "sh", "-zsh", "bash", "-bash"];

fn obj(pairs: Vec<(&str, Value)>) -> Value {
    let mut m = Map::new();
    for (k, v) in pairs {
        m.insert(k.to_string(), v);
    }
    Value::Object(m)
}

fn is_shell(t: &str) -> bool {
    SHELLS.contains(&t.to_lowercase().as_str())
}

pub fn report(s: &Sample) -> Value {
    let names = displays::names();
    let pin_rules = pins::load();

    let name_of = |id: i64, index: i64| -> String {
        names
            .get(&id.to_string())
            .cloned()
            .unwrap_or_else(|| format!("display {}", index))
    };
    let display_name_for = |idx: i64| -> Option<String> {
        s.displays
            .iter()
            .find(|d| d.index == idx)
            .map(|d| name_of(d.id, d.index))
    };

    // fleet — WezTerm roster (TS: requires w.display present, uses it directly).
    struct Seed {
        title: String,
        id: i64,
        display: i64,
        space: i64,
        focus: bool,
    }
    let mut seeds: Vec<Seed> = vec![];
    for w in &s.windows {
        if w.app != "WezTerm" {
            continue;
        }
        let title = w.title.trim().to_string();
        if title.is_empty() || w.space.is_none() || w.display.is_none() {
            continue;
        }
        seeds.push(Seed {
            title,
            id: w.id,
            display: w.display.unwrap(),
            space: w.space.unwrap(),
            focus: w.has_focus,
        });
    }
    let mut dup_count: std::collections::HashMap<String, i64> = std::collections::HashMap::new();
    for s0 in &seeds {
        *dup_count.entry(s0.title.to_lowercase()).or_insert(0) += 1;
    }
    let fleet: Vec<Value> = seeds
        .iter()
        .map(|f| {
            obj(vec![
                ("title", json!(f.title)),
                ("app", json!("WezTerm")),
                ("id", json!(f.id)),
                ("display", json!(f.display)),
                ("space", json!(f.space)),
                ("focus", json!(f.focus)),
                ("dup", json!(dup_count.get(&f.title.to_lowercase()).cloned().unwrap_or(1))),
                (
                    "displayName",
                    display_name_for(f.display).map(Value::String).unwrap_or(Value::Null),
                ),
                ("isShell", json!(is_shell(&f.title))),
            ])
        })
        .collect();

    // windows — v1.2 mini-map: all apps, all spaces, real frames only.
    let windows: Vec<Value> = s
        .windows
        .iter()
        .filter_map(|w| {
            let title = w.title.trim().to_string();
            if w.space.is_none() || w.display.is_none() || title.is_empty() {
                return None;
            }
            let frame = w.frame?;
            if frame.w < 80.0 || frame.h < 60.0 {
                return None;
            }
            let pinned = pin_rules.iter().any(|p| pins::matches(w, p));
            let idle_only = pin_rules
                .iter()
                .any(|p| p.get("whenIdleOnly").and_then(|v| v.as_bool()).unwrap_or(false) && pins::matches(w, p));
            Some(obj(vec![
                ("id", json!(w.id)),
                ("app", json!(w.app)),
                ("title", json!(title)),
                ("space", json!(w.space.unwrap())),
                ("display", json!(w.display.unwrap())),
                ("focus", json!(w.has_focus)),
                ("pinned", json!(pinned)),
                ("whenIdleOnly", json!(idle_only)),
                (
                    "frame",
                    obj(vec![
                        ("x", json!(frame.x)),
                        ("y", json!(frame.y)),
                        ("w", json!(frame.w)),
                        ("h", json!(frame.h)),
                    ]),
                ),
            ]))
        })
        .collect();

    let displays_json: Vec<Value> = s
        .displays
        .iter()
        .map(|d| {
            obj(vec![
                ("index", json!(d.index)),
                ("name", json!(name_of(d.id, d.index))),
                (
                    "frame",
                    obj(vec![
                        ("x", json!(d.frame.x)),
                        ("y", json!(d.frame.y)),
                        ("w", json!(d.frame.w)),
                        ("h", json!(d.frame.h)),
                    ]),
                ),
            ])
        })
        .collect();

    let spaces_json: Vec<Value> = s
        .spaces
        .iter()
        .map(|sp| {
            let pinned = pin_rules.iter().any(|p| {
                let ps = p.get("space").and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)));
                let pl = p.get("label").and_then(|v| v.as_str());
                ps == Some(sp.index) || (pl.is_some() && pl == sp.label.as_deref())
            });
            obj(vec![
                ("index", json!(sp.index)),
                ("display", json!(sp.display)),
                ("isVisible", json!(sp.is_visible)),
                ("hasFocus", json!(sp.has_focus)),
                ("pinned", json!(pinned)),
            ])
        })
        .collect();

    let profile_status = profile_status(s);

    let idle_secs = idle::effective_seconds(false);
    let seconds: Value = match idle_secs {
        Some(v) => json!(idle::THRESHOLD_SEC.min((v / 10.0).floor() * 10.0)),
        None => Value::Null,
    };
    let armed = idle_secs.map(|v| v >= idle::THRESHOLD_SEC).unwrap_or(false)
        && pin_rules
            .iter()
            .any(|p| p.get("whenIdleOnly").and_then(|v| v.as_bool()).unwrap_or(false));
    let idle_json = obj(vec![
        ("seconds", seconds),
        ("threshold", json!(idle::THRESHOLD_SEC)),
        ("visibleThreshold", json!(idle::THRESHOLD_SEC * idle::VISIBLE_MULTIPLIER)),
        ("armed", json!(armed)),
    ]);

    obj(vec![
        ("ts", json!(s.ts_ms)),
        ("fleet", Value::Array(fleet)),
        ("windows", Value::Array(windows)),
        ("displays", Value::Array(displays_json)),
        ("spaces", Value::Array(spaces_json)),
        ("profile", profile_status),
        ("idle", idle_json),
    ])
}

// computeProfileStatus — rebuilds the (title, space) fleet view from the sample.
fn profile_status(s: &Sample) -> Value {
    // Rebuild fleet (title, space) from the sample — WezTerm windows with a
    // non-empty title (matches computeProfileStatus's input, which is the fleet
    // rows; isShell computed here).
    let profile = profile::load();
    if profile.is_empty() {
        return Value::Null;
    }
    let mut reasons: Vec<String> = vec![];

    let live_labels: std::collections::BTreeSet<String> = s
        .spaces
        .iter()
        .filter_map(|sp| sp.label.clone())
        .filter(|l| !l.is_empty())
        .collect();
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut lost: Vec<String> = vec![];
    for p in pins::load() {
        if let Some(l) = p.get("label").and_then(|v| v.as_str()) {
            if !l.is_empty()
                && !live_labels.contains(l)
                && !pins::is_synthetic_label(l)
                && seen.insert(l.to_string())
            {
                lost.push(l.to_string());
            }
        }
    }
    if !lost.is_empty() {
        reasons.push(format!("pin label(s) lost after reboot: {}", lost.join(", ")));
    }

    let match_rule = |title_lower: &str| -> Option<&Value> {
        profile.iter().find(|r| {
            let m = r.get("match").and_then(|v| v.as_str()).unwrap_or("").to_lowercase();
            pins::has(title_lower, &m) || pins::has(&m, title_lower)
        })
    };

    let mut mismatched = 0;
    for w in &s.windows {
        if w.app != "WezTerm" {
            continue;
        }
        let title = w.title.trim();
        if title.is_empty() || w.space.is_none() {
            continue;
        }
        let tl = title.to_lowercase();
        if is_shell(&tl) {
            continue;
        }
        if title.contains(' ') {
            continue;
        }
        if let Some(rule) = match_rule(&tl) {
            if let Some(want) = rule
                .get("space")
                .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
            {
                if Some(want) != w.space {
                    mismatched += 1;
                }
            }
        }
    }
    if mismatched >= 2 {
        reasons.push(format!(
            "{} oracle(s) off their profile space (likely space renumber)",
            mismatched
        ));
    }

    if reasons.is_empty() {
        obj(vec![("stale", json!(false))])
    } else {
        obj(vec![("stale", json!(true)), ("reason", json!(reasons.join("; ")))])
    }
}
