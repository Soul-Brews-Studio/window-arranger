// Snapshot → plan → apply pipeline + SVG renderers. Port of lib/bsp.ts's
// server-facing surface (cross-checked against Arranger.swift). The SVG template
// strings are byte-identical to bsp.ts svgFromItems — the conformance suite
// compares SVG bodies verbatim, so every newline/indent/number here is load-bearing.
use crate::engine::Sample;
use crate::layout::{self, Mode};
use crate::models::{Frame, Window};
use crate::yabai;

const PALETTE: [&str; 10] = [
    "#e94560", "#0f3460", "#16213e", "#53354a", "#903749", "#e3b23c", "#2b7a78", "#5c6b73",
    "#a06cd5", "#f26430",
];

// JS number → string: whole values print as integers, else shortest round-trip
// (Rust's {} for f64 matches JS Number.toString for the SVG's coordinate range).
pub fn js_num(v: f64) -> String {
    if v.is_finite() && v == v.floor() && v.abs() < 1e15 {
        return (v as i64).to_string();
    }
    format!("{}", v)
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

// `${w.app}${w.title ? ": " + w.title.slice(0, 22) : ""}` — slice counts UTF-16
// code units (an emoji costs 2), NOT grapheme clusters. No ellipsis (matches TS).
fn win_label(w: &Window) -> String {
    if w.title.is_empty() {
        return w.app.clone();
    }
    let units: Vec<u16> = w.title.encode_utf16().take(22).collect();
    let cut = String::from_utf16_lossy(&units);
    format!("{}: {}", w.app, cut)
}

// Byte-matches bsp.ts svgFromItems.
fn svg_from_items(display_frame: Frame, items: &[(Frame, String)], title: &str) -> String {
    let margin = 8.0;
    let label_h = 26.0;
    let canvas_w = 1000.0;
    let scale = (canvas_w - margin * 2.0) / display_frame.w;
    let draw_h = display_frame.h * scale;
    let canvas_h = yabai::js_round(draw_h + margin * 2.0 + label_h) as f64;
    let offset_x = margin;
    let offset_y = margin + label_h;

    let mut rects = String::new();
    for (i, (rect, label)) in items.iter().enumerate() {
        let x = offset_x + (rect.x - display_frame.x) * scale;
        let y = offset_y + (rect.y - display_frame.y) * scale;
        let w = rect.w * scale;
        let h = rect.h * scale;
        let color = PALETTE[i % PALETTE.len()];
        rects.push_str(&format!(
            "<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"{}\" stroke=\"#fff\" stroke-width=\"1.5\" opacity=\"0.85\"/>\n      <text x=\"{}\" y=\"{}\" fill=\"white\" font-family=\"monospace\" font-size=\"11\">{}</text>",
            js_num(x), js_num(y), js_num(w), js_num(h), color,
            js_num(x + 6.0), js_num(y + 16.0), esc(label)
        ));
    }

    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{cw}\" height=\"{ch}\" viewBox=\"0 0 {cw} {ch}\">\n    <rect width=\"{cw}\" height=\"{ch}\" fill=\"#0a0e14\"/>\n    <text x=\"{margin}\" y=\"18\" fill=\"#8fd3ff\" font-family=\"monospace\" font-size=\"14\">{title}</text>\n    <rect x=\"{ox}\" y=\"{oy}\" width=\"{fw}\" height=\"{dh}\" fill=\"none\" stroke=\"#444\" stroke-dasharray=\"4,4\"/>\n    {rects}\n  </svg>",
        cw = js_num(canvas_w),
        ch = js_num(canvas_h),
        margin = js_num(margin),
        title = esc(title),
        ox = js_num(offset_x),
        oy = js_num(offset_y),
        fw = js_num(display_frame.w * scale),
        dh = js_num(draw_h),
        rects = rects,
    )
}

struct Computed {
    space_index: i64,
    display_index: i64,
    display_frame: Frame,
    leaves: Vec<layout::Placement>,
    total: usize,
}

fn compute_layout(
    s: &Sample,
    space_index: i64,
    mode: Mode,
    active_first: bool,
) -> Result<Computed, String> {
    let space = s
        .spaces
        .iter()
        .find(|sp| sp.index == space_index)
        .ok_or_else(|| format!("space {} not in snapshot", space_index))?;
    let display = s
        .displays
        .iter()
        .find(|d| d.index == space.display)
        .ok_or_else(|| format!("display {} not in snapshot", space.display))?;
    let windows: Vec<Window> = s
        .windows
        .iter()
        .filter(|w| w.space == Some(space_index) && layout::is_tileable(w))
        .cloned()
        .collect();
    let (_outer, leaves) =
        layout::compute_leaves(&windows, display.frame, &s.config, mode, active_first);
    Ok(Computed {
        space_index: space.index,
        display_index: space.display,
        display_frame: display.frame,
        leaves,
        total: windows.len(),
    })
}

fn in_place(f: &Option<Frame>, r: &Frame) -> bool {
    match f {
        Some(f) => {
            (f.x - r.x).abs() < 2.0
                && (f.y - r.y).abs() < 2.0
                && (f.w - r.w).abs() < 2.0
                && (f.h - r.h).abs() < 2.0
        }
        None => false,
    }
}

pub fn apply_layout(
    s: &Sample,
    space_index: i64,
    mode: Mode,
    active_first: bool,
) -> Result<i64, String> {
    let layout = compute_layout(s, space_index, mode, active_first)?;
    let todo: Vec<&layout::Placement> = layout
        .leaves
        .iter()
        .filter(|p| !in_place(&p.win.frame, &p.rect))
        .collect();
    if todo.is_empty() {
        return Ok(0);
    }
    if let Some(space) = s.spaces.iter().find(|sp| sp.index == space_index) {
        if space.type_ != "float" {
            yabai::set_layout(space_index, "float");
        }
    }
    for p in &todo {
        yabai::move_window_abs(p.win.id, p.rect.x, p.rect.y);
        yabai::resize_window_abs(p.win.id, p.rect.w, p.rect.h);
    }
    Ok(todo.len() as i64)
}

pub fn retile_space(s: &Sample, space_index: i64) {
    let _ = apply_layout(s, space_index, Mode::Flip, true);
}

pub fn main_display_index(s: &Sample) -> i64 {
    s.displays
        .iter()
        .find(|d| d.frame.x == 0.0 && d.frame.y == 0.0)
        .map(|d| d.index)
        .or_else(|| s.displays.iter().map(|d| d.index).min())
        .unwrap_or(1)
}

pub struct GatherResult {
    pub moved: i64,
    pub main_index: i64,
    pub total: i64,
}

pub fn gather_to_main(s: &Sample) -> GatherResult {
    let main = main_display_index(s);
    let tileable: Vec<&Window> = s.windows.iter().filter(|w| layout::is_tileable(w)).collect();
    let mut moved = 0;
    for w in &tileable {
        // TS uses `w.display !== mainIndex` directly on the window's display field.
        if w.display != Some(main) {
            yabai::move_window_to_display(w.id, main);
            moved += 1;
        }
    }
    GatherResult {
        moved,
        main_index: main,
        total: tileable.len() as i64,
    }
}

pub fn render_preview_svg(
    s: &Sample,
    space_index: i64,
    mode: Mode,
    active_first: bool,
) -> Result<String, String> {
    let layout = compute_layout(s, space_index, mode, active_first)?;
    let tag = if active_first { " · active-first" } else { "" };
    let title = format!(
        "{}{} · space {} / display {} · {} windows",
        mode.label(),
        tag,
        layout.space_index,
        layout.display_index,
        layout.total
    );
    let items: Vec<(Frame, String)> = layout
        .leaves
        .iter()
        .map(|p| (p.rect, win_label(&p.win)))
        .collect();
    Ok(svg_from_items(layout.display_frame, &items, &title))
}

pub fn render_current_svg(s: &Sample, space_index: i64) -> Result<String, String> {
    let space = s
        .spaces
        .iter()
        .find(|sp| sp.index == space_index)
        .ok_or_else(|| format!("space {} not in snapshot", space_index))?;
    let display = s
        .displays
        .iter()
        .find(|d| d.index == space.display)
        .ok_or_else(|| format!("display {} not in snapshot", space.display))?;
    let items: Vec<(Frame, String)> = s
        .windows
        .iter()
        .filter(|w| w.space == Some(space_index) && layout::is_tileable(w) && w.frame.is_some())
        .map(|w| (w.frame.unwrap(), win_label(w)))
        .collect();
    let title = format!(
        "CURRENT arrangement · space {} / display {} · {} windows",
        space.index,
        space.display,
        items.len()
    );
    Ok(svg_from_items(display.frame, &items, &title))
}
