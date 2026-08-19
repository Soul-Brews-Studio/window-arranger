// Snapshot cache — the Rust twin of lib/engine.ts / ServerEngine.swift. One
// sample yields BOTH the raw yabai JSON text (for /api/state passthrough) and
// the typed views (for who/layout/pins math), so the two can never disagree.
use crate::models::{parse_displays, parse_spaces, parse_windows, Config, Display, Space, Window};
use crate::yabai;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone)]
pub struct Sample {
    pub ts_ms: f64,
    pub raw_displays: String,
    pub raw_spaces: String,
    pub displays: Vec<Display>,
    pub spaces: Vec<Space>,
    pub windows: Vec<Window>,
    pub config: Config,
}

struct State {
    sample: Option<Sample>,
    writes_in_flight: i64,
    last_config: Option<Config>,
}

static STATE: OnceLock<Mutex<State>> = OnceLock::new();

fn state() -> &'static Mutex<State> {
    STATE.get_or_init(|| {
        Mutex::new(State {
            sample: None,
            writes_in_flight: 0,
            last_config: None,
        })
    })
}

fn now_ms() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

fn refresh(reuse_config: bool) -> Option<Sample> {
    if !yabai::is_available() {
        return None;
    }
    let raw_displays = yabai::query_raw("--displays")?;
    let raw_spaces = yabai::query_raw("--spaces")?;
    let raw_windows = yabai::query_raw("--windows")?;
    let displays = parse_displays(&raw_displays);
    let spaces = parse_spaces(&raw_spaces);
    let windows = parse_windows(&raw_windows);
    let cached = state().lock().unwrap().last_config;
    let config = if reuse_config {
        cached.unwrap_or_else(yabai::global_config)
    } else {
        yabai::global_config()
    };
    let s = Sample {
        ts_ms: now_ms(),
        raw_displays,
        raw_spaces,
        displays,
        spaces,
        windows,
        config,
    };
    let mut st = state().lock().unwrap();
    st.sample = Some(s.clone());
    st.last_config = Some(config);
    Some(s)
}

pub fn force_refresh() -> Option<Sample> {
    refresh(false)
}

pub fn snapshot() -> Option<Sample> {
    state().lock().unwrap().sample.clone()
}

pub fn current() -> Option<Sample> {
    snapshot().or_else(force_refresh)
}

pub fn begin_write() {
    state().lock().unwrap().writes_in_flight += 1;
}

pub fn end_write() {
    let mut st = state().lock().unwrap();
    st.writes_in_flight = (st.writes_in_flight - 1).max(0);
}

pub fn start(interval_ms: u64) {
    force_refresh();
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_millis(interval_ms));
        let busy = state().lock().unwrap().writes_in_flight > 0;
        if !busy {
            refresh(true);
        }
    });
}
