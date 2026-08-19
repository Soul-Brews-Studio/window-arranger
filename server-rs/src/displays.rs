// Monitor names — port of lib/displays.ts. yabai display id == CGDirectDisplayID,
// so system_profiler names map by id. Cached (hand-editable) at
// WA_HOME/.config/window-arranger-oracle/displays.json — a bare {"<id>":"<name>"} map.
use crate::models::conf_dir;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::process::Command;

pub fn config_path() -> String {
    conf_dir().join("displays.json").to_string_lossy().to_string()
}

pub fn names() -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if let Ok(text) = std::fs::read_to_string(config_path()) {
        if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&text) {
            for (k, v) in map {
                if let Some(s) = v.as_str() {
                    out.insert(k, s.to_string());
                }
            }
        }
    }
    out
}

// Detect via system_profiler (id → _name). Best-effort; not exercised by the suite.
fn detect() -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let output = match Command::new("/usr/sbin/system_profiler")
        .args(["SPDisplaysDataType", "-json"])
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return out,
    };
    let root: Value = match serde_json::from_slice(&output.stdout) {
        Ok(v) => v,
        Err(_) => return out,
    };
    if let Some(gpus) = root.get("SPDisplaysDataType").and_then(|x| x.as_array()) {
        for gpu in gpus {
            if let Some(screens) = gpu.get("spdisplays_ndrvs").and_then(|x| x.as_array()) {
                for scr in screens {
                    let name = scr
                        .get("_name")
                        .and_then(|x| x.as_str())
                        .unwrap_or("Display");
                    let id = scr
                        .get("_spdisplays_displayID")
                        .or_else(|| scr.get("spdisplays_displayID"));
                    if let Some(id) = id {
                        let id_str = match id {
                            Value::Number(n) => n.to_string(),
                            Value::String(s) => s.clone(),
                            _ => continue,
                        };
                        out.insert(id_str, name.to_string());
                    }
                }
            }
        }
    }
    out
}

pub fn refresh() -> Result<BTreeMap<String, String>, String> {
    let mut merged = names();
    for (k, v) in detect() {
        merged.insert(k, v);
    }
    let dir = conf_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut map = Map::new();
    for (k, v) in &merged {
        map.insert(k.clone(), Value::String(v.clone()));
    }
    let text = serde_json::to_string_pretty(&Value::Object(map)).map_err(|e| e.to_string())?;
    std::fs::write(config_path(), text + "\n").map_err(|e| e.to_string())?;
    Ok(merged)
}
