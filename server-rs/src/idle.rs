// Fleet-shared human-idle clock — port of lib/idle.ts / Idle.swift. Calls
// CGEventSource directly (min over 5 event types, rounded). null = cannot prove
// idle → whenIdleOnly pins sit out (fail safe). effective = min(local, since
// last remote human action). NOTE: /api/who clamps + scrubs this, so the exact
// value never affects conformance — threshold/visibleThreshold constants do.
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const THRESHOLD_SEC: f64 = 300.0;
pub const VISIBLE_MULTIPLIER: f64 = 3.0;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventSourceSecondsSinceLastEventType(state_id: i32, event_type: u32) -> f64;
}

// mouseMoved=5, leftMouseDown=1, rightMouseDown=3, keyDown=10, scrollWheel=22.
const EVENT_TYPES: [u32; 5] = [5, 1, 3, 10, 22];
const STATE_ID: i32 = 0; // kCGEventSourceStateCombinedSessionState — what Idle.swift uses (1 is HIDSystemState)

struct IdleState {
    cache_val: Option<f64>,
    cache_at: Option<Instant>,
    last_remote_ms: f64,
}

fn state() -> &'static Mutex<IdleState> {
    static S: OnceLock<Mutex<IdleState>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(IdleState {
            cache_val: None,
            cache_at: None,
            last_remote_ms: 0.0,
        })
    })
}

fn sample() -> Option<f64> {
    let mut min = f64::INFINITY;
    for &t in &EVENT_TYPES {
        let s = unsafe { CGEventSourceSecondsSinceLastEventType(STATE_ID, t) };
        if s < min {
            min = s;
        }
    }
    if min.is_finite() {
        Some(min.round())
    } else {
        None
    }
}

pub fn note_remote_human_action() {
    let mut st = state().lock().unwrap();
    st.last_remote_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
}

pub fn effective_seconds(fresh: bool) -> Option<f64> {
    let mut st = state().lock().unwrap();
    let local = if !fresh
        && st
            .cache_at
            .map(|a| a.elapsed() < Duration::from_secs(2))
            .unwrap_or(false)
    {
        st.cache_val
    } else {
        let v = sample();
        st.cache_val = v;
        st.cache_at = Some(Instant::now());
        v
    };
    let local = local?;
    if st.last_remote_ms <= 0.0 {
        return Some(local);
    }
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0);
    let since_remote = (now_ms - st.last_remote_ms) / 1000.0;
    Some(local.min(since_remote))
}
