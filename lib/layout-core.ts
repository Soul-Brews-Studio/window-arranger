// layout-core — the pure, dependency-free packing geometry behind window-arranger,
// extracted so anything can reuse it (first consumer: agora's Oracle Board, for
// "tidy this selection into a frame"). ZERO I/O, ZERO yabai, ZERO node imports —
// just rect math. Generic over item INDEX: you give a frame + a count + a gap +
// a mode, you get back rects in item order. Caller owns ordering and which items
// to include (e.g. the board excludes pinned items before calling).
//
// Coordinate model: Rect {x,y,w,h}, y-DOWN, origin top-left, x/y may be NEGATIVE
// (a frame left/above the origin), one uniform `gap` between tiles. Units are
// agnostic — screen pixels here, world-units on a board, same math.
//
// This is BOUNDED-CONTAINER packing (fill a finite frame), NOT infinite-canvas
// free placement. No collision-avoidance against pre-placed items, no pan/zoom,
// no edge routing — those belong to the canvas, not here.

export interface Rect { x: number; y: number; w: number; h: number; }

export type LayoutMode = "spiral" | "flip" | "flipup" | "grid" | "columns" | "rows";
export const LAYOUT_MODES: LayoutMode[] = ["spiral", "flip", "flipup", "grid", "columns", "rows"];

export const MODE_LABEL: Record<LayoutMode, string> = {
  spiral: "Spiral — Fibonacci, largest first (left)",
  flip: "Flip — largest right, curls down",
  flipup: "Flip ↑ — largest right, curls up",
  grid: "Grid — near-square equal cells",
  columns: "Columns — one row, side by side",
  rows: "Rows — one column, stacked",
};

// SPIRAL: split the frame in half (axis by aspect ratio), item 0 takes the FIRST
// half (left/top), the rest recurse into the second half — a 50/50 Fibonacci
// spiral. Returns rects in item order.
export function spiralRects(outer: Rect, count: number, gap: number): Rect[] {
  if (count <= 0) return [];
  if (count === 1) return [{ ...outer }];
  const isWide = outer.w >= outer.h;
  let first: Rect, rest: Rect;
  if (isWide) {
    const halfW = (outer.w - gap) / 2;
    first = { x: outer.x, y: outer.y, w: halfW, h: outer.h };
    rest = { x: outer.x + halfW + gap, y: outer.y, w: halfW, h: outer.h };
  } else {
    const halfH = (outer.h - gap) / 2;
    first = { x: outer.x, y: outer.y, w: outer.w, h: halfH };
    rest = { x: outer.x, y: outer.y + halfH + gap, w: outer.w, h: halfH };
  }
  return [first, ...spiralRects(rest, count - 1, gap)];
}

// Horizontal mirror within `outer` (used for flip / "largest on the right").
export function mirrorXRects(rects: Rect[], outer: Rect): Rect[] {
  return rects.map((r) => ({ ...r, x: outer.x + outer.w - (r.x - outer.x) - r.w }));
}
// Vertical mirror within `outer`. mirrorX ∘ mirrorY == 180° rotation of the spiral.
export function mirrorYRects(rects: Rect[], outer: Rect): Rect[] {
  return rects.map((r) => ({ ...r, y: outer.y + outer.h - (r.y - outer.y) - r.h }));
}

// GRID: equal cells. Pick the column count that keeps cells near-square while
// leaving the fewest empty cells, then fill row-major.
export function gridRects(outer: Rect, count: number, gap: number): Rect[] {
  if (count <= 0) return [];
  let best = { cols: 1, rows: count, score: Infinity };
  for (let cols = 1; cols <= count; cols++) {
    const rows = Math.ceil(count / cols);
    const empty = cols * rows - count;
    const cellW = (outer.w - (cols - 1) * gap) / cols;
    const cellH = (outer.h - (rows - 1) * gap) / rows;
    const aspectDev = Math.abs(Math.log(cellW / cellH)); // 0 == square-ish
    const score = empty * 2 + aspectDev;
    if (score < best.score) best = { cols, rows, score };
  }
  const { cols } = best;
  const rows = Math.ceil(count / cols);
  const cellW = (outer.w - (cols - 1) * gap) / cols;
  const cellH = (outer.h - (rows - 1) * gap) / rows;
  return Array.from({ length: count }, (_, i) => {
    const r = Math.floor(i / cols), c = i % cols;
    return { x: outer.x + c * (cellW + gap), y: outer.y + r * (cellH + gap), w: cellW, h: cellH };
  });
}

// COLUMNS: one horizontal row of equal full-height columns (1 | 2 | 3 | …).
export function columnsRects(outer: Rect, count: number, gap: number): Rect[] {
  if (count <= 0) return [];
  const w = (outer.w - (count - 1) * gap) / count;
  return Array.from({ length: count }, (_, i) => ({ x: outer.x + i * (w + gap), y: outer.y, w, h: outer.h }));
}

// ROWS: one vertical column of equal full-width rows, stacked top→bottom.
export function rowsRects(outer: Rect, count: number, gap: number): Rect[] {
  if (count <= 0) return [];
  const h = (outer.h - (count - 1) * gap) / count;
  return Array.from({ length: count }, (_, i) => ({ x: outer.x, y: outer.y + i * (h + gap), w: outer.w, h }));
}

// The one dispatch every consumer wants: frame + count + gap + mode → rects in
// item order. flip/flipup are mirrors of the spiral; grid/columns/rows are their
// own base geometry (no mirror — caller applies any policy mirror itself).
export function packRects(outer: Rect, count: number, gap: number, mode: LayoutMode): Rect[] {
  switch (mode) {
    case "grid": return gridRects(outer, count, gap);
    case "columns": return columnsRects(outer, count, gap);
    case "rows": return rowsRects(outer, count, gap);
    case "flip": return mirrorXRects(spiralRects(outer, count, gap), outer);
    case "flipup": return mirrorYRects(mirrorXRects(spiralRects(outer, count, gap), outer), outer);
    case "spiral":
    default: return spiralRects(outer, count, gap);
  }
}

// Index-tagged convenience for CLI/JSON consumers.
export function packItems(outer: Rect, count: number, gap: number, mode: LayoutMode): { rect: Rect; index: number }[] {
  return packRects(outer, count, gap, mode).map((rect, index) => ({ rect, index }));
}

// ---- normalize: a window/child rect in the SAME coordinate space as `frame`
// → a rect relative to `frame`'s origin, at unit scale (1 = the whole frame).
// This is the mapper a MIRROR view needs (agora's Stoa board, 2026-07-12):
// yabai reports window frames AND display frames in ONE global point-space
// (origin top-left, y-DOWN, left/upper displays NEGATIVE), and a space fills
// its display — so "window px-frame → space-relative" is exactly this subtract
// + divide. No Retina math: yabai frames are already logical POINTS, so a
// window and its display are in the same units (never mix in CGDisplayBounds
// pixel sizes). Multiply the result by your canvas w/h to draw. `out.w/out.h`
// can exceed 1 or go negative if the child pokes outside the frame — clamp at
// the draw site if you want to hard-crop.
export interface NormRect { x: number; y: number; w: number; h: number; } // 0..1 within frame
export function normalizeRectToFrame(child: Rect, frame: Rect): NormRect {
  return {
    x: (child.x - frame.x) / frame.w,
    y: (child.y - frame.y) / frame.h,
    w: child.w / frame.w,
    h: child.h / frame.h,
  };
}

// ---- SVG preview (rect[] → thumbnail), pure. Scales `frame` onto a fixed-width
// dark canvas; each rect gets a palette fill + optional label. For board tile
// thumbnails and layout previews alike.
const PALETTE = ["#16537e", "#1d6796", "#2b7fb8", "#e94560", "#53354a", "#3a2f14", "#173a2b", "#7d5ba6"];
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

export function renderRectsSVG(
  frame: Rect,
  items: { rect: Rect; label?: string }[],
  opts: { title?: string; canvasW?: number } = {},
): string {
  const MARGIN = 8, LABEL_H = opts.title ? 26 : 0, CANVAS_W = opts.canvasW ?? 1000;
  const scale = (CANVAS_W - MARGIN * 2) / frame.w;
  const drawH = frame.h * scale;
  const CANVAS_H = Math.round(drawH + MARGIN * 2 + LABEL_H);
  const offsetX = MARGIN, offsetY = MARGIN + LABEL_H;
  const body = items.map((it, i) => {
    const x = offsetX + (it.rect.x - frame.x) * scale;
    const y = offsetY + (it.rect.y - frame.y) * scale;
    const w = it.rect.w * scale, h = it.rect.h * scale;
    const label = it.label
      ? `<text x="${x + 6}" y="${y + 16}" fill="white" font-family="monospace" font-size="11">${esc(it.label)}</text>` : "";
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${PALETTE[i % PALETTE.length]}" stroke="#fff" stroke-width="1.5" opacity="0.85"/>${label}`;
  }).join("");
  const titleEl = opts.title
    ? `<text x="${MARGIN}" y="18" fill="#8fd3ff" font-family="monospace" font-size="14">${esc(opts.title)}</text>` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS_W}" height="${CANVAS_H}" viewBox="0 0 ${CANVAS_W} ${CANVAS_H}">
    <rect width="${CANVAS_W}" height="${CANVAS_H}" fill="#0a0e14"/>${titleEl}
    <rect x="${offsetX}" y="${offsetY}" width="${frame.w * scale}" height="${drawH}" fill="none" stroke="#444" stroke-dasharray="4,4"/>
    ${body}
  </svg>`;
}
