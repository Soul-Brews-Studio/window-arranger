// Full route surface — port of server.ts routes + Routes.swift resolve()/handle().
// Guard order (critical): resolve route FIRST (unmatched POST → plain 404, no
// guard/audit) → loopback check → public-queue allowlist + kill-switch + audit →
// dispatch. Window-mutating routes read at write-grade freshness (force_refresh).
use crate::arranger;
use crate::displays;
use crate::engine;
use crate::http::{Request, Response};
use crate::idle;
use crate::layout::Mode;
use crate::models::{conf_dir, repo_root};
use crate::pins;
use crate::profile;
use crate::timeutil;
use crate::who;
use crate::yabai;
use serde_json::{json, Map, Value};
use std::sync::atomic::{AtomicBool, Ordering};

static SHADOW: AtomicBool = AtomicBool::new(false);

pub fn set_shadow(v: bool) {
    SHADOW.store(v, Ordering::SeqCst);
}
fn is_shadow() -> bool {
    SHADOW.load(Ordering::SeqCst)
}

const SIGNPOST: &str = include_str!("signpost.html");

fn remote_off_path() -> String {
    conf_dir()
        .join("remote-control.off")
        .to_string_lossy()
        .to_string()
}
fn audit_path() -> String {
    conf_dir().join("audit.jsonl").to_string_lossy().to_string()
}

fn err(message: &str, status: u16) -> Response {
    Response::json(status, json!({ "error": message }).to_string())
}

fn body_json(req: &Request) -> Value {
    serde_json::from_slice(&req.body).unwrap_or(Value::Null)
}
fn body_str<'a>(b: &'a Value, k: &str) -> Option<&'a str> {
    b.get(k).and_then(|v| v.as_str())
}
fn body_true(b: &Value, k: &str) -> bool {
    b.get(k).and_then(|v| v.as_bool()) == Some(true)
}

// OPT-IN via WA_DISPLAY_MAP_PUBLISH. Unset means the feature is off and nothing
// is spawned. Previously a hardcoded absolute path into a private repo, which
// spawned a nonexistent path every 60s on any machine but the author's, with
// stdout and stderr discarded.
fn publish_display_map() {
    if is_shadow() {
        return;
    }
    let script = match std::env::var("WA_DISPLAY_MAP_PUBLISH") {
        Ok(s) if !s.is_empty() => s,
        _ => return,
    };
    let _ = std::process::Command::new("bun")
        .arg(script)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

pub fn publish_display_map_public() {
    publish_display_map();
}

fn public_allowed(path: &str) -> bool {
    if path == "/api/arrange-profile" || path == "/api/snapshot-profile" || path == "/api/park" {
        return true;
    }
    let parts: Vec<&str> = path.split('/').filter(|p| !p.is_empty()).collect();
    parts.len() == 4
        && parts[0] == "api"
        && parts[1] == "space"
        && !parts[2].is_empty()
        && parts[2].chars().all(|c| c.is_ascii_digit())
        && (parts[3] == "apply" || parts[3] == "focus")
}

fn audit(path: &str, source: &str, blocked: &Option<String>) {
    let mut m = Map::new();
    m.insert("ts".into(), json!(timeutil::iso_now()));
    m.insert("path".into(), json!(path));
    m.insert("source".into(), json!(source));
    m.insert("allowed".into(), json!(blocked.is_none()));
    if let Some(b) = blocked {
        m.insert("blocked".into(), json!(b));
    }
    let line = Value::Object(m).to_string() + "\n";
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(audit_path())
    {
        let _ = f.write_all(line.as_bytes());
    }
}

enum Route {
    Signpost,
    Legacy,
    State,
    Who,
    PinsStatus,
    PinsToggle,
    Park,
    GatherToMain,
    RefreshDisplays,
    SnapshotProfile,
    ArrangeProfile,
    Preview(String),
    Current(String),
    Apply(i64),
    Focus(i64),
    Layout(i64),
    SpacePin(i64),
}

fn resolve(req: &Request) -> Option<Route> {
    let parts: Vec<&str> = req.path.split('/').filter(|p| !p.is_empty()).collect();
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/") => return Some(Route::Signpost),
        ("GET", "/legacy") => return Some(Route::Legacy),
        ("GET", "/api/state") => return Some(Route::State),
        ("GET", "/api/who") => return Some(Route::Who),
        ("GET", "/api/pins") => return Some(Route::PinsStatus),
        ("POST", "/api/pins/toggle") => return Some(Route::PinsToggle),
        ("POST", "/api/park") => return Some(Route::Park),
        ("POST", "/api/gather-to-main") => return Some(Route::GatherToMain),
        ("POST", "/api/refresh-displays") => return Some(Route::RefreshDisplays),
        ("POST", "/api/snapshot-profile") => return Some(Route::SnapshotProfile),
        ("POST", "/api/arrange-profile") => return Some(Route::ArrangeProfile),
        _ => {}
    }
    if parts.len() == 3 && parts[0] == "api" && parts[1] == "preview" && req.method == "GET" {
        return Some(Route::Preview(parts[2].to_string()));
    }
    if parts.len() == 3 && parts[0] == "api" && parts[1] == "current" && req.method == "GET" {
        return Some(Route::Current(parts[2].to_string()));
    }
    if parts.len() == 4 && parts[0] == "api" && parts[1] == "space" && req.method == "POST" {
        if let Ok(space) = parts[2].parse::<i64>() {
            match parts[3] {
                "apply" => return Some(Route::Apply(space)),
                "focus" => return Some(Route::Focus(space)),
                "layout" => return Some(Route::Layout(space)),
                "pin" => return Some(Route::SpacePin(space)),
                _ => {}
            }
        }
    }
    None
}

pub fn handle(req: &Request) -> Response {
    let route = match resolve(req) {
        Some(r) => r,
        None => return Response::new(404, "text/plain", b"NOT_FOUND".to_vec()),
    };

    if req.method == "POST" {
        if !req.loopback {
            return err(
                "writes are loopback-only (run this from the machine itself)",
                403,
            );
        }
        let source = req
            .headers
            .get("x-arrange-source")
            .cloned()
            .unwrap_or_else(|| "local".to_string());
        let mut blocked: Option<String> = None;
        if source == "public-queue" {
            if std::path::Path::new(&remote_off_path()).exists() {
                blocked = Some("remoteControl is off (remove remote-control.off to re-enable)".into());
            } else if !public_allowed(&req.path) {
                blocked = Some("action not in the phase-1 public allowlist".into());
            }
            if blocked.is_none() {
                idle::note_remote_human_action();
            }
        }
        audit(&req.path, &source, &blocked);
        if let Some(b) = blocked {
            return err(&b, 403);
        }
    }

    dispatch(route, req)
}

fn dispatch(route: Route, req: &Request) -> Response {
    match route {
        Route::Signpost => {
            let mut r = Response::new(200, "text/html", SIGNPOST.as_bytes().to_vec());
            r.extra_headers.push(("Cache-Control".into(), "no-store".into()));
            r
        }
        Route::Legacy => match std::fs::read(format!("{}/public/index.html", repo_root())) {
            Ok(data) => {
                let mut r = Response::new(200, "text/html", data);
                r.extra_headers.push(("Cache-Control".into(), "no-store".into()));
                r
            }
            Err(_) => Response::new(404, "text/plain", b"legacy UI not found".to_vec()),
        },
        Route::State => state(),
        Route::Who => match engine::current() {
            Some(s) => Response::json(200, who::report(&s).to_string()),
            None => err("no snapshot", 500),
        },
        Route::PinsStatus => Response::json(
            200,
            json!({ "enabled": pins::enabled(), "rules": pins::rule_count() }).to_string(),
        ),
        Route::Preview(space_raw) => preview(&space_raw, req),
        Route::Current(space_raw) => current(&space_raw),
        Route::Apply(space) => apply(space, req),
        Route::Focus(space) => focus(space, req),
        Route::Layout(space) => layout_route(space, req),
        Route::SpacePin(space) => space_pin(space, req),
        Route::GatherToMain => gather_to_main(),
        Route::Park => park(),
        Route::PinsToggle => {
            let new_state = pins::set_enabled(!pins::enabled());
            Response::json(
                200,
                json!({ "ok": true, "enabled": new_state, "rules": pins::rule_count() }).to_string(),
            )
        }
        Route::RefreshDisplays => refresh_displays(),
        Route::SnapshotProfile => snapshot_profile(),
        Route::ArrangeProfile => arrange_profile(),
    }
}

fn state() -> Response {
    let s = match engine::current() {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    let names = displays::names();
    let mut displays_val: Value = serde_json::from_str(&s.raw_displays).unwrap_or(Value::Array(vec![]));
    if let Value::Array(items) = &mut displays_val {
        for item in items.iter_mut() {
            if let Value::Object(map) = item {
                let id = map
                    .get("id")
                    .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)));
                let name = id
                    .and_then(|i| names.get(&i.to_string()).cloned())
                    .map(Value::String)
                    .unwrap_or(Value::Null);
                map.insert("name".into(), name);
            }
        }
    }
    let spaces_val: Value = serde_json::from_str(&s.raw_spaces).unwrap_or(Value::Array(vec![]));
    let out = json!({ "displays": displays_val, "spaces": spaces_val });
    Response::json(200, out.to_string())
}

fn preview(space_raw: &str, req: &Request) -> Response {
    let s = match engine::current() {
        Some(s) => s,
        None => return err("bad space", 500),
    };
    let space = match space_raw.parse::<i64>() {
        Ok(v) => v,
        Err(_) => return err("bad space", 500),
    };
    let mode = Mode::parse(req.query.get("mode").map(|s| s.as_str()));
    let active = matches!(req.query.get("active").map(|s| s.as_str()), Some("1") | Some("true"));
    match arranger::render_preview_svg(&s, space, mode, active) {
        Ok(svg) => Response::new(200, "image/svg+xml", svg.into_bytes()),
        Err(e) => err(&e, 500),
    }
}

fn current(space_raw: &str) -> Response {
    let s = match engine::current() {
        Some(s) => s,
        None => return err("bad space", 500),
    };
    let space = match space_raw.parse::<i64>() {
        Ok(v) => v,
        Err(_) => return err("bad space", 500),
    };
    match arranger::render_current_svg(&s, space) {
        Ok(svg) => Response::new(200, "image/svg+xml", svg.into_bytes()),
        Err(e) => err(&e, 500),
    }
}

fn apply(space: i64, req: &Request) -> Response {
    let b = body_json(req);
    let mode = Mode::parse(body_str(&b, "mode"));
    let active_first = body_true(&b, "activeFirst");
    let s = match engine::force_refresh() {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    engine::begin_write();
    let result = arranger::apply_layout(&s, space, mode, active_first);
    engine::force_refresh();
    engine::end_write();
    publish_display_map();
    match result {
        Ok(moved) => Response::json(
            200,
            json!({
                "ok": true, "space": space, "mode": mode.name(),
                "activeFirst": active_first, "moved": moved
            })
            .to_string(),
        ),
        Err(e) => err(&e, 500),
    }
}

fn focus(space: i64, req: &Request) -> Response {
    let b = body_json(req);
    let keep_mouse = body_true(&b, "keepMouse");
    if let Some(failure) = yabai::focus_space_checked(space) {
        return Response::json(
            200,
            json!({ "ok": false, "space": space, "error": failure }).to_string(),
        );
    }
    engine::force_refresh();
    Response::json(
        200,
        json!({ "ok": true, "space": space, "keepMouse": keep_mouse }).to_string(),
    )
}

fn layout_route(space: i64, req: &Request) -> Response {
    let b = body_json(req);
    if body_str(&b, "layout") != Some("float") {
        return err("only float is applied via yabai layout; use /apply for tiling", 400);
    }
    engine::begin_write();
    yabai::set_layout(space, "float");
    engine::force_refresh();
    engine::end_write();
    Response::json(
        200,
        json!({ "ok": true, "space": space, "layout": "float" }).to_string(),
    )
}

fn gather_to_main() -> Response {
    let s = match engine::force_refresh() {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    engine::begin_write();
    let r = arranger::gather_to_main(&s);
    engine::force_refresh();
    engine::end_write();
    publish_display_map();
    Response::json(
        200,
        json!({
            "ok": true, "moved": r.moved, "mainIndex": r.main_index, "total": r.total
        })
        .to_string(),
    )
}

fn park() -> Response {
    let enabled = pins::enabled();
    let s = match engine::force_refresh() {
        Some(s) => s,
        None => {
            return Response::json(
                200,
                json!({ "ok": false, "pinsEnabled": enabled, "error": "no snapshot" }).to_string(),
            )
        }
    };
    engine::begin_write();
    let names = displays::names();
    let result = pins::park_now(&s.windows, &s.spaces, &s.displays, &names);
    let mut retiled: Vec<i64> = vec![];
    if !result.moved_from.is_empty() {
        if let Some(fresh) = engine::force_refresh() {
            let mut spaces_sorted: Vec<i64> = result.moved_from.clone();
            spaces_sorted.sort();
            spaces_sorted.dedup();
            for sp in spaces_sorted {
                arranger::retile_space(&fresh, sp);
                retiled.push(sp);
            }
        }
    }
    engine::force_refresh();
    engine::end_write();
    publish_display_map();
    Response::json(
        200,
        json!({
            "ok": true,
            "pinsEnabled": enabled,
            "moved": result.moved,
            "retiled": retiled
        })
        .to_string(),
    )
}

fn space_pin(space: i64, req: &Request) -> Response {
    let s = match engine::current() {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    let sp = match s.spaces.iter().find(|x| x.index == space) {
        Some(sp) => sp.clone(),
        None => {
            return Response::json(
                400,
                json!({ "ok": false, "error": format!("no space with index {}", space) })
                    .to_string(),
            )
        }
    };
    let b = body_json(req);
    let pinned = body_true(&b, "pinned");
    engine::begin_write();
    let mut label = sp.label.clone().unwrap_or_default().trim().to_string();
    if pinned && label.is_empty() {
        label = format!("{}{}", pins::SYNTH_LABEL_PREFIX, space);
        yabai::label_space(space, &label);
    }
    let windows: Vec<_> = s
        .windows
        .iter()
        .filter(|w| w.space == Some(space))
        .cloned()
        .collect();
    let count = pins::set_space_pin(&label, &windows, pinned);
    if !pinned && pins::is_synthetic_label(&label) {
        yabai::label_space(space, "");
    }
    let resp = json!({
        "ok": true, "space": space, "pinned": pinned,
        "count": count, "pinsEnabled": pins::enabled()
    })
    .to_string();
    engine::force_refresh();
    engine::end_write();
    Response::json(200, resp)
}

fn refresh_displays() -> Response {
    match displays::refresh() {
        Ok(names) => {
            let mut m = Map::new();
            for (k, v) in &names {
                m.insert(k.clone(), Value::String(v.clone()));
            }
            Response::json(
                200,
                json!({ "ok": true, "config": displays::config_path(), "names": Value::Object(m) })
                    .to_string(),
            )
        }
        Err(e) => err(&e, 500),
    }
}

fn snapshot_profile() -> Response {
    let s = match engine::force_refresh().or_else(engine::current) {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    let rules = profile::snapshot_rules(&s.windows);
    match profile::save(&rules) {
        Ok(backup) => Response::json(
            200,
            json!({
                "ok": true,
                "saved": rules.len(),
                "backup": backup.map(Value::String).unwrap_or(Value::Null)
            })
            .to_string(),
        ),
        Err(e) => err(&e, 500),
    }
}

fn arrange_profile() -> Response {
    let rules = profile::load();
    if rules.is_empty() {
        return Response::json(
            200,
            json!({ "ok": false, "error": "no profile saved — snapshot one first" }).to_string(),
        );
    }
    let s = match engine::force_refresh() {
        Some(s) => s,
        None => return err("no snapshot", 500),
    };
    engine::begin_write();
    let (moved, matched) = profile::arrange_by_profile(&s.windows, &rules);
    engine::force_refresh();
    engine::end_write();
    publish_display_map();
    Response::json(
        200,
        json!({
            "ok": true, "rules": rules.len(), "matched": matched, "moved": moved
        })
        .to_string(),
    )
}
