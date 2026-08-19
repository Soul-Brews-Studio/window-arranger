// Pure tiling geometry — port of lib/layout-core.ts + lib/bsp.ts computeLeaves
// (cross-checked against WindowArrangerCore/Layout.swift). 6 base modes + the
// composable activeFirst reorder. ZERO I/O here (recency ordering lives in
// recency.rs, called only when activeFirst is set).
use crate::models::{Config, Frame, Window};
use crate::recency;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Spiral,
    Flip,
    Flipup,
    Grid,
    Columns,
    Rows,
}

impl Mode {
    pub fn parse(raw: Option<&str>) -> Mode {
        match raw {
            Some("spiral") => Mode::Spiral,
            Some("flip") => Mode::Flip,
            Some("flipup") => Mode::Flipup,
            Some("grid") => Mode::Grid,
            Some("columns") => Mode::Columns,
            Some("rows") => Mode::Rows,
            _ => Mode::Spiral,
        }
    }
    pub fn name(&self) -> &'static str {
        match self {
            Mode::Spiral => "spiral",
            Mode::Flip => "flip",
            Mode::Flipup => "flipup",
            Mode::Grid => "grid",
            Mode::Columns => "columns",
            Mode::Rows => "rows",
        }
    }
    // lib/layout-core.ts MODE_LABEL — the SVG title strings (NOT the menu labels).
    pub fn label(&self) -> &'static str {
        match self {
            Mode::Spiral => "Spiral — Fibonacci, largest first (left)",
            Mode::Flip => "Flip — largest right, curls down",
            Mode::Flipup => "Flip ↑ — largest right, curls up",
            Mode::Grid => "Grid — near-square equal cells",
            Mode::Columns => "Columns — one row, side by side",
            Mode::Rows => "Rows — one column, stacked",
        }
    }
}

pub struct Placement {
    pub win: Window,
    pub rect: Frame,
}

pub fn is_tileable(w: &Window) -> bool {
    !w.is_floating
        && !w.is_sticky
        && !w.is_minimized
        && !w.is_hidden
        && w.can_move != Some(false)
        && w.can_resize != Some(false)
}

fn spiral_rects(outer: Frame, count: usize, gap: f64) -> Vec<Frame> {
    if count == 0 {
        return vec![];
    }
    if count == 1 {
        return vec![outer];
    }
    let is_wide = outer.w >= outer.h;
    let (first, rest) = if is_wide {
        let half_w = (outer.w - gap) / 2.0;
        (
            Frame { x: outer.x, y: outer.y, w: half_w, h: outer.h },
            Frame { x: outer.x + half_w + gap, y: outer.y, w: half_w, h: outer.h },
        )
    } else {
        let half_h = (outer.h - gap) / 2.0;
        (
            Frame { x: outer.x, y: outer.y, w: outer.w, h: half_h },
            Frame { x: outer.x, y: outer.y + half_h + gap, w: outer.w, h: half_h },
        )
    };
    let mut out = vec![first];
    out.extend(spiral_rects(rest, count - 1, gap));
    out
}

fn mirror_x(rects: &[Frame], outer: Frame) -> Vec<Frame> {
    rects
        .iter()
        .map(|r| Frame {
            x: outer.x + outer.w - (r.x - outer.x) - r.w,
            y: r.y,
            w: r.w,
            h: r.h,
        })
        .collect()
}

fn mirror_y(rects: &[Frame], outer: Frame) -> Vec<Frame> {
    rects
        .iter()
        .map(|r| Frame {
            x: r.x,
            y: outer.y + outer.h - (r.y - outer.y) - r.h,
            w: r.w,
            h: r.h,
        })
        .collect()
}

fn grid_rects(outer: Frame, count: usize, gap: f64) -> Vec<Frame> {
    if count == 0 {
        return vec![];
    }
    let n = count as f64;
    let mut best_cols = 1usize;
    let mut best_score = f64::INFINITY;
    for cols in 1..=count {
        let colsf = cols as f64;
        let rows = (n / colsf).ceil();
        let empty = colsf * rows - n;
        let cell_w = (outer.w - (colsf - 1.0) * gap) / colsf;
        let cell_h = (outer.h - (rows - 1.0) * gap) / rows;
        let aspect_dev = (cell_w / cell_h).ln().abs();
        let score = empty * 2.0 + aspect_dev;
        if score < best_score {
            best_score = score;
            best_cols = cols;
        }
    }
    let cols = best_cols;
    let colsf = cols as f64;
    let rows = (n / colsf).ceil();
    let cell_w = (outer.w - (colsf - 1.0) * gap) / colsf;
    let cell_h = (outer.h - (rows - 1.0) * gap) / rows;
    (0..count)
        .map(|i| {
            let r = (i / cols) as f64;
            let c = (i % cols) as f64;
            Frame {
                x: outer.x + c * (cell_w + gap),
                y: outer.y + r * (cell_h + gap),
                w: cell_w,
                h: cell_h,
            }
        })
        .collect()
}

fn columns_rects(outer: Frame, count: usize, gap: f64) -> Vec<Frame> {
    if count == 0 {
        return vec![];
    }
    let n = count as f64;
    let w = (outer.w - (n - 1.0) * gap) / n;
    (0..count)
        .map(|i| Frame {
            x: outer.x + (i as f64) * (w + gap),
            y: outer.y,
            w,
            h: outer.h,
        })
        .collect()
}

fn rows_rects(outer: Frame, count: usize, gap: f64) -> Vec<Frame> {
    if count == 0 {
        return vec![];
    }
    let n = count as f64;
    let h = (outer.h - (n - 1.0) * gap) / n;
    (0..count)
        .map(|i| Frame {
            x: outer.x,
            y: outer.y + (i as f64) * (h + gap),
            w: outer.w,
            h,
        })
        .collect()
}

fn pack_rects(outer: Frame, count: usize, gap: f64, mode: Mode) -> Vec<Frame> {
    match mode {
        Mode::Grid => grid_rects(outer, count, gap),
        Mode::Columns => columns_rects(outer, count, gap),
        Mode::Rows => rows_rects(outer, count, gap),
        Mode::Flip => mirror_x(&spiral_rects(outer, count, gap), outer),
        Mode::Flipup => mirror_y(&mirror_x(&spiral_rects(outer, count, gap), outer), outer),
        Mode::Spiral => spiral_rects(outer, count, gap),
    }
}

pub fn outer_rect(display_frame: Frame, cfg: &Config) -> Frame {
    Frame {
        x: display_frame.x + cfg.left,
        y: display_frame.y + cfg.top,
        w: display_frame.w - cfg.left - cfg.right,
        h: display_frame.h - cfg.top - cfg.bottom,
    }
}

// computeLeaves: reorder (activeFirst) → pack → policy mirror for grid/columns.
pub fn compute_leaves(
    windows: &[Window],
    display_frame: Frame,
    cfg: &Config,
    mode: Mode,
    active_first: bool,
) -> (Frame, Vec<Placement>) {
    let outer = outer_rect(display_frame, cfg);
    let wins: Vec<Window> = if active_first {
        recency::order(windows)
    } else {
        windows.to_vec()
    };
    let mut leaves = vec![];
    if !wins.is_empty() {
        let mut rects = pack_rects(outer, wins.len(), cfg.gap, mode);
        if active_first && (mode == Mode::Grid || mode == Mode::Columns) {
            rects = mirror_x(&rects, outer);
        }
        leaves = rects
            .into_iter()
            .zip(wins.into_iter())
            .map(|(rect, win)| Placement { win, rect })
            .collect();
    }
    (outer, leaves)
}
