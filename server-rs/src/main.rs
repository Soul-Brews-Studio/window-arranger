// Native Rust port of server.ts (third implementation alongside Bun + Swift).
//   window-arranger-server              → port 8900, loops ON (authoritative)
//   window-arranger-server --shadow     → port 8901, loops OFF (diff vs others)
//   window-arranger-server --port N      → explicit port
// Shadow mode: background loops off so it can run next to another authoritative
// server without two pin-enforcers fighting. The conformance suite runs --shadow.
mod arranger;
mod displays;
mod engine;
mod http;
mod idle;
mod layout;
mod models;
mod pins;
mod profile;
mod recency;
mod routes;
mod timeutil;
mod who;
mod yabai;

use std::time::Duration;

fn main() {
    let mut port: u16 = 8900;
    let mut shadow = false;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--shadow" => {
                shadow = true;
                if port == 8900 {
                    port = 8901;
                }
            }
            "--port" => {
                if let Some(p) = args.next().and_then(|s| s.parse::<u16>().ok()) {
                    port = p;
                }
            }
            other => {
                eprintln!("unknown arg: {}", other);
                std::process::exit(2);
            }
        }
    }
    routes::set_shadow(shadow);

    engine::start(1500);

    // Display-name refresh: skipped in shadow (matches server.ts, which guards it
    // behind !SHADOW so the conformance instance never forks system_profiler).
    if !shadow {
        let _ = displays::refresh();
    }

    if !shadow {
        start_loops();
    }

    eprintln!(
        "window-arranger-server listening on 127.0.0.1:{}{}",
        port,
        if shadow { " (shadow — loops off)" } else { "" }
    );
    http::serve(port, routes::handle);
}

fn start_loops() {
    // 📌 pin enforcement — every 10s with fresh idle.
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(10));
        let pins = pins::load();
        if pins.is_empty() {
            continue;
        }
        let s = match engine::snapshot() {
            Some(s) => s,
            None => continue,
        };
        let names = displays::names();
        let result = pins::enforce(
            &s.windows,
            &s.spaces,
            &s.displays,
            &names,
            &pins,
            idle::effective_seconds(true),
        );
        if !result.moved.is_empty() {
            engine::begin_write();
            engine::force_refresh();
            engine::end_write();
            routes::publish_display_map_public();
        }
    });

    // 🩹 auto-heal — every 60s.
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(60));
        if let Some(s) = engine::snapshot() {
            pins::auto_heal(&s.windows, &s.spaces);
        }
    });

    // 🗺️ display-map publish — every 60s.
    std::thread::spawn(|| loop {
        std::thread::sleep(Duration::from_secs(60));
        routes::publish_display_map_public();
    });
}
