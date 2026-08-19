// bsp — deterministic tiling layouts for a space's windows, with preview + apply.
//
// We do NOT mimic `yabai -m space --layout bsp`. Research into yabai's source
// (view.c) confirmed its BSP tree is insertion-order dependent and cannot be
// reproduced from the current window set alone — so any stateless simulation is
// only an approximation. Instead we compute our OWN deterministic layout and
// apply it by explicit per-window --move/--resize (the space is floated first so
// yabai won't fight us). That guarantees preview == applied, and sidesteps the
// abrupt bsp re-tile that squished Comet windows. Frames come from yabai's own
// query, never CGWindowListCopyWindowInfo (which lags after a move).
import { readdirSync, statSync, openSync, readSync, closeSync } from "node:fs";
import { yabai, type YabaiClient } from "./yabai";

// Base geometry only. "active-first" ordering (formerly the rotate/recency
// modes) is now a composable flag — it reorders the windows before ANY of these
// layouts are applied, so the active window lands in that layout's largest slot.
import { packRects, mirrorXRects, MODE_LABEL, type LayoutMode } from "./layout-core";
export { LAYOUT_MODES, MODE_LABEL, type LayoutMode } from "./layout-core";

export interface YabaiWindow {
  id: number;
  app: string;
  title: string;
  display?: number;
  space?: number;
  frame?: Rect;
  "has-focus"?: boolean;
  "is-floating"?: boolean;
  "is-sticky"?: boolean;
  "is-minimized"?: boolean;
  "is-hidden"?: boolean;
  "can-move"?: boolean;
  "can-resize"?: boolean;
}
export interface Rect { x: number; y: number; w: number; h: number; }
export interface Leaf { rect: Rect; win: YabaiWindow; }

// All yabai I/O now goes through the injected YabaiClient (lib/yabai.ts) — the
// old yabaiJSON() read choke point and the scattered $`yabai ...` writes are gone.

// Only windows yabai itself would tile. Research (window_manager.c:272-281)
// lists 8 exclusion conditions; besides the four state flags we now also
// require can-move + can-resize (absent field = assume yes, for old fixtures).
// Found the hard way (2026-07-10): Wispr Flow's untitled main overlay reports
// floating=false but can-move=false/can-resize=false — it passed the old
// filter, claimed a column slot, then snapped itself back to center, leaving
// a permanent hole in the layout ("มีสี่อันแต่ไม่กระจายเต็มจอ").
export function isTileable(w: YabaiWindow): boolean {
  return !w["is-floating"] && !w["is-sticky"] && !w["is-minimized"] && !w["is-hidden"] &&
    w["can-move"] !== false && w["can-resize"] !== false;
}

// SPIRAL: split in half (axis by aspect ratio), largest window takes the FIRST
// half (left/top), the rest recurse into the second half — a 50/50 Fibonacci
// spiral. This is the layout previously verified as visually matching yabai.
export function bspSplit(rect: Rect, wins: YabaiWindow[], gap: number): Leaf[] {
  if (wins.length === 1) return [{ rect, win: wins[0] }];
  const isWide = rect.w >= rect.h;
  let first: Rect, rest: Rect;
  if (isWide) {
    const halfW = (rect.w - gap) / 2;
    first = { x: rect.x, y: rect.y, w: halfW, h: rect.h };
    rest = { x: rect.x + halfW + gap, y: rect.y, w: halfW, h: rect.h };
  } else {
    const halfH = (rect.h - gap) / 2;
    first = { x: rect.x, y: rect.y, w: rect.w, h: halfH };
    rest = { x: rect.x, y: rect.y + halfH + gap, w: rect.w, h: halfH };
  }
  return [{ rect: first, win: wins[0] }, ...bspSplit(rest, wins.slice(1), gap)];
}

// FLIP: horizontal mirror of any layout, reflected within the outer rect.
export function mirrorX(leaves: Leaf[], outer: Rect): Leaf[] {
  return leaves.map((l) => ({
    win: l.win,
    rect: { ...l.rect, x: outer.x + outer.w - (l.rect.x - outer.x) - l.rect.w },
  }));
}

// Vertical mirror. mirrorX + mirrorY == 180° rotation of the spiral.
export function mirrorY(leaves: Leaf[], outer: Rect): Leaf[] {
  return leaves.map((l) => ({
    win: l.win,
    rect: { ...l.rect, y: outer.y + outer.h - (l.rect.y - outer.y) - l.rect.h },
  }));
}

// GRID: equal cells. Pick the column count that fills most cleanly while keeping
// cell aspect reasonable, then place windows in row-major order.
export function gridLeaves(outer: Rect, wins: YabaiWindow[], gap: number): Leaf[] {
  const n = wins.length;
  if (n === 0) return [];
  let best = { cols: 1, rows: n, score: Infinity };
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols);
    const empty = cols * rows - n;
    const cellW = (outer.w - (cols - 1) * gap) / cols;
    const cellH = (outer.h - (rows - 1) * gap) / rows;
    const aspectDev = Math.abs(Math.log(cellW / cellH)); // 0 == square-ish cells
    const score = empty * 2 + aspectDev;
    if (score < best.score) best = { cols, rows, score };
  }
  const { cols, rows } = best;
  const cellW = (outer.w - (cols - 1) * gap) / cols;
  const cellH = (outer.h - (rows - 1) * gap) / rows;
  return wins.map((win, i) => {
    const r = Math.floor(i / cols), c = i % cols;
    return { win, rect: { x: outer.x + c * (cellW + gap), y: outer.y + r * (cellH + gap), w: cellW, h: cellH } };
  });
}

// COLUMNS: one horizontal row of equal, full-height columns (1 | 2 | 3 | …).
export function columnsLeaves(outer: Rect, wins: YabaiWindow[], gap: number): Leaf[] {
  const n = wins.length;
  if (n === 0) return [];
  const w = (outer.w - (n - 1) * gap) / n;
  return wins.map((win, i) => ({ win, rect: { x: outer.x + i * (w + gap), y: outer.y, w, h: outer.h } }));
}

// ROWS: one vertical column of equal, full-width rows, stacked top→bottom
// (good for portrait displays).
export function rowsLeaves(outer: Rect, wins: YabaiWindow[], gap: number): Leaf[] {
  const n = wins.length;
  if (n === 0) return [];
  const h = (outer.h - (n - 1) * gap) / n;
  return wins.map((win, i) => ({ win, rect: { x: outer.x, y: outer.y + i * (h + gap), w: outer.w, h } }));
}

// RECENCY: order windows by which oracle interacted most recently, so the
// most-active oracle gets the largest tile. Signal = mtime of each oracle's
// Claude Code session log (~/.claude/projects/<encoded-repo>/*.jsonl). Ranking
// is per-space, so each display is arranged by only the oracles living on it.
function sessionMtimes(): Map<string, number> {
  const base = `${process.env.HOME}/.claude/projects`;
  const map = new Map<string, number>();
  let dirs: string[];
  try { dirs = readdirSync(base); } catch { return map; }
  for (const d of dirs) {
    let latest = 0;
    try {
      for (const f of readdirSync(`${base}/${d}`)) {
        if (!f.endsWith(".jsonl")) continue;
        const m = statSync(`${base}/${d}/${f}`).mtimeMs;
        if (m > latest) latest = m;
      }
    } catch { /* skip unreadable dir */ }
    if (latest > 0) map.set(d.toLowerCase(), latest);
  }
  return map;
}

// A WezTerm title like "argus" maps to the repo dir ending in "-argus" or
// e.g. "-my-project". Unmatched windows sort last (recency 0).
function recencyForTitle(title: string, mtimes: Map<string, number>): number {
  const t = title.toLowerCase().replace(/\s+/g, "-");
  let best = 0;
  for (const [name, m] of mtimes) {
    if ((name.endsWith("-" + t) || name.endsWith("-" + t + "-oracle")) && m > best) best = m;
  }
  return best;
}

export function orderByRecency(windows: YabaiWindow[]): YabaiWindow[] {
  const mtimes = sessionMtimes();
  return [...windows].sort((a, b) => recencyForTitle(b.title, mtimes) - recencyForTitle(a.title, mtimes));
}

// ROTATE signal: "where the human is working". Stronger than session mtime
// (which also bumps on AI output) — we read the timestamp of the last
// HUMAN-TYPED message in the oracle's session log, and treat the currently
// focused window as most-recent. Active window ends up largest on the right.
export function projectBase(): string {
  return `${process.env.HOME}/.claude/projects`;
}

export function dirForTitle(title: string, dirs: string[]): string | null {
  const t = title.toLowerCase().replace(/\s+/g, "-");
  return dirs.find((n) => {
    const l = n.toLowerCase();
    return l.endsWith("-" + t) || l.endsWith("-" + t + "-oracle");
  }) ?? null;
}

export function latestJsonl(dir: string): string | null {
  try {
    let best: string | null = null, bestM = 0;
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".jsonl")) continue;
      const m = statSync(`${dir}/${f}`).mtimeMs;
      if (m > bestM) { bestM = m; best = `${dir}/${f}`; }
    }
    return best;
  } catch { return null; }
}

// The typed text of a "user" entry, or null if it isn't one (tool results,
// assistant turns). Array content: human text has a "text" block.
function humanText(entry: any): string | null {
  if (entry?.type !== "user") return null;
  const c = entry?.message?.content;
  if (typeof c === "string") return c.trim() ? c : null;
  if (Array.isArray(c)) {
    const t = c.find((x) => x?.type === "text")?.text;
    return typeof t === "string" && t.trim() ? t : null;
  }
  return null;
}

// Scan the tail of the session log for the last human-typed message that
// `accept` likes, newest-first. Reading only the tail keeps this cheap even on
// multi-MB logs. Returns 0 when nothing in the window qualifies — callers
// decide their own fallback (ordering wants mtime; `who --last` wants honesty).
export function lastTypedTime(path: string, accept: (text: string) => boolean = () => true, window = 65536): number {
  try {
    const size = statSync(path).size;
    const start = Math.max(0, size - window);
    const len = size - start;
    const buf = Buffer.alloc(len);
    const fd = openSync(path, "r");
    readSync(fd, buf, 0, len, start);
    closeSync(fd);
    const lines = buf.toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i].trim();
      if (!line) continue;
      let e: any;
      try { e = JSON.parse(line); } catch { continue; }
      const text = humanText(e);
      if (text != null && accept(text) && e.timestamp) {
        const t = Date.parse(e.timestamp);
        if (!Number.isNaN(t)) return t;
      }
    }
    return 0;
  } catch { return 0; }
}

function lastHumanTime(path: string): number {
  const t = lastTypedTime(path);
  if (t) return t;
  try { return statSync(path).mtimeMs; } catch { return 0; } // no human msg in tail
}

export function orderByHumanRecency(windows: YabaiWindow[]): YabaiWindow[] {
  let dirs: string[];
  try { dirs = readdirSync(projectBase()); } catch { dirs = []; }
  const scored = windows.map((w) => {
    if (w["has-focus"]) return { w, t: Number.MAX_SAFE_INTEGER }; // active now → most recent
    const dir = dirForTitle(w.title, dirs);
    const jsonl = dir ? latestJsonl(`${projectBase()}/${dir}`) : null;
    return { w, t: jsonl ? lastHumanTime(jsonl) : 0 };
  });
  scored.sort((a, b) => b.t - a.t);
  return scored.map((s) => s.w);
}

export interface Config { top: number; bottom: number; left: number; right: number; gap: number; }

export interface Layout {
  space: { index: number; display: number };
  display: { frame: Rect };
  outer: Rect;
  leaves: Leaf[];
  total: number;
  mode: LayoutMode;
}

export interface YabaiDisplay { id: number; index: number; frame: Rect; "has-focus"?: boolean; }
export interface YabaiSpace { index: number; display: number; type: string; label?: string; "is-visible"?: boolean; windows: number[]; "has-focus"?: boolean; }

// A cached view of yabai state — one sample feeds many reads (see lib/engine.ts).
export interface Snapshot {
  ts: number;
  displays: YabaiDisplay[];
  spaces: YabaiSpace[];
  windows: YabaiWindow[];
  config: Config;
}

// PURE (no yabai I/O): compute outer rect + leaves for a base layout. When
// activeFirst is set, windows are reordered by human-active recency BEFORE the
// layout is applied, so the window you last typed in lands in that layout's
// largest slot (e.g. flip → far right, spiral → far left). This is the "rotate"
// behaviour, now composable with any base mode instead of a mode of its own.
export function computeLeaves(windows: YabaiWindow[], displayFrame: Rect, cfg: Config, mode: LayoutMode, activeFirst = false): { outer: Rect; leaves: Leaf[] } {
  const outer: Rect = {
    x: displayFrame.x + cfg.left,
    y: displayFrame.y + cfg.top,
    w: displayFrame.w - cfg.left - cfg.right,
    h: displayFrame.h - cfg.top - cfg.bottom,
  };
  const wins = activeFirst ? orderByHumanRecency(windows) : windows;
  let leaves: Leaf[] = [];
  if (wins.length) {
    // Base geometry comes from the shared pure core (lib/layout-core.ts) — one
    // source of truth, also used by agora's board. The ONE window-arranger-only
    // policy layered on top: grid/columns get an extra active-right mirror when
    // activeFirst is on (so the window you last typed in fills from the right,
    // matching flip). rows/spiral/flip/flipup need no extra step.
    let rects = packRects(outer, wins.length, cfg.gap, mode);
    if (activeFirst && (mode === "grid" || mode === "columns")) rects = mirrorXRects(rects, outer);
    leaves = rects.map((rect, i) => ({ rect, win: wins[i] }));
  }
  return { outer, leaves };
}

// Zero-I/O: derive a space's layout entirely from a cached snapshot.
export function computeLayoutFromSnapshot(snap: Snapshot, spaceIndex: number, mode: LayoutMode = "spiral", activeFirst = false): Layout {
  const space = snap.spaces.find((s) => s.index === spaceIndex);
  if (!space) throw new Error(`space ${spaceIndex} not in snapshot`);
  const display = snap.displays.find((d) => d.index === space.display);
  if (!display) throw new Error(`display ${space.display} not in snapshot`);
  const windows = snap.windows.filter((w) => w.space === spaceIndex && isTileable(w));
  const { outer, leaves } = computeLeaves(windows, display.frame, snap.config, mode, activeFirst);
  return { space: { index: space.index, display: space.display }, display: { frame: display.frame }, outer, leaves, total: windows.length, mode };
}

// Live path (forks yabai via the client) — used to build a snapshot; reads
// should prefer the engine's cached snapshot instead. Thin wrapper over the pure
// core. The client is injectable so this is unit-testable with a FakeYabaiRunner.
export async function computeLayout(spaceIndex: number, mode: LayoutMode = "spiral", activeFirst = false, client: YabaiClient = yabai): Promise<Layout> {
  const space = await client.space(spaceIndex);
  const windows = (await client.windows({ space: spaceIndex })).filter(isTileable);
  const display = await client.display(space.display);
  const cfg = await client.spaceConfig(space.index);
  const { outer, leaves } = computeLeaves(windows, display.frame, cfg, mode, activeFirst);
  return { space, display, outer, leaves, total: windows.length, mode };
}

// Apply the computed layout to the real windows. Float the space first so yabai
// stops managing them (verified hands-off in space_manager.c), then move+resize.
// STABILITY (Nat 2026-07-11: "จัดถูกแล้ว แต่อย่ากระพริบ อยู่ที่เดิมต้องนิ่ง"):
// a window already within 2px of its target is NOT touched — re-applying the
// same layout moves nothing, so nothing blinks and settled windows stay put.
// `moved` now reports windows actually moved, not leaves counted.
const inPlace = (f: Rect | undefined, r: Rect): boolean =>
  !!f && Math.abs(f.x - r.x) < 2 && Math.abs(f.y - r.y) < 2 &&
  Math.abs(f.w - r.w) < 2 && Math.abs(f.h - r.h) < 2;

export async function applyLayout(spaceIndex: number, mode: LayoutMode = "spiral", activeFirst = false, client: YabaiClient = yabai): Promise<{ moved: number; mode: LayoutMode }> {
  const { space, leaves } = await computeLayout(spaceIndex, mode, activeFirst, client);
  const todo = leaves.filter((leaf) => !inPlace(leaf.win.frame, leaf.rect));
  if (!todo.length) return { moved: 0, mode }; // everything already in place — zero writes
  if ((space as YabaiSpace).type !== "float") await client.setLayout(spaceIndex, "float");
  for (const leaf of todo) {
    const r = leaf.rect;
    await client.moveWindow(leaf.win.id, { x: r.x, y: r.y });
    await client.resizeWindow(leaf.win.id, { w: r.w, h: r.h });
  }
  return { moved: todo.length, mode };
}

// Re-tile a space with the app default (flip + active-first) — used after a
// window is moved OUT of a space (park hotkey) or INTO one (⌃⌥⌘⇧N) so the
// remaining/arrived windows re-flow to fill the frame (Nat 2026-07-12: "the
// moved to another and that current should re-organized"). applyLayout's
// skip-in-place means settled windows never blink; 0-1 window → 0 moves.
export async function retileSpace(spaceIndex: number, client: YabaiClient = yabai): Promise<{ moved: number }> {
  return applyLayout(spaceIndex, "flip", true, client);
}

// The macOS primary display is the one whose global frame origin is (0,0).
export async function mainDisplayIndex(client: YabaiClient = yabai): Promise<number> {
  const displays = await client.displays();
  const main = displays.find((d) => d.frame.x === 0 && d.frame.y === 0);
  return main?.index ?? Math.min(...displays.map((d) => d.index));
}

// Pull every tileable window from other displays onto the main display's active
// space. Sticky/floating/minimized/hidden windows are left where they are.
export async function gatherToMain(client: YabaiClient = yabai): Promise<{ moved: number; mainIndex: number; total: number }> {
  const mainIndex = await mainDisplayIndex(client);
  const windows = (await client.windows()).filter(isTileable);
  let moved = 0;
  for (const w of windows) {
    if (w.display !== mainIndex) {
      await client.moveToDisplay(w.id, mainIndex);
      moved++;
    }
  }
  return { moved, mainIndex, total: windows.length };
}

const PALETTE = ["#e94560", "#0f3460", "#16213e", "#53354a", "#903749", "#e3b23c", "#2b7a78", "#5c6b73", "#a06cd5", "#f26430"];

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}


interface SvgItem { rect: Rect; label: string; }

// Shared renderer: draws window rects (global coords) scaled onto a canvas that
// matches the display's aspect ratio, with a title band on top.
function svgFromItems(displayFrame: Rect, items: SvgItem[], title: string): string {
  const MARGIN = 8;
  const LABEL_H = 26;
  const CANVAS_W = 1000;
  const scale = (CANVAS_W - MARGIN * 2) / displayFrame.w;
  const drawH = displayFrame.h * scale;
  const CANVAS_H = Math.round(drawH + MARGIN * 2 + LABEL_H);
  const offsetX = MARGIN;
  const offsetY = MARGIN + LABEL_H;

  const rects = items.map((it, i) => {
    const x = offsetX + (it.rect.x - displayFrame.x) * scale;
    const y = offsetY + (it.rect.y - displayFrame.y) * scale;
    const w = it.rect.w * scale, h = it.rect.h * scale;
    const color = PALETTE[i % PALETTE.length];
    return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${color}" stroke="#fff" stroke-width="1.5" opacity="0.85"/>
      <text x="${x + 6}" y="${y + 16}" fill="white" font-family="monospace" font-size="11">${esc(it.label)}</text>`;
  }).join("");

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${CANVAS_W}" height="${CANVAS_H}" viewBox="0 0 ${CANVAS_W} ${CANVAS_H}">
    <rect width="${CANVAS_W}" height="${CANVAS_H}" fill="#0a0e14"/>
    <text x="${MARGIN}" y="18" fill="#8fd3ff" font-family="monospace" font-size="14">${esc(title)}</text>
    <rect x="${offsetX}" y="${offsetY}" width="${displayFrame.w * scale}" height="${drawH}" fill="none" stroke="#444" stroke-dasharray="4,4"/>
    ${rects}
  </svg>`;
}

function winLabel(w: YabaiWindow): string {
  return `${w.app}${w.title ? ": " + w.title.slice(0, 22) : ""}`;
}

// Preview of a PROPOSED layout (what Apply would do), from a cached snapshot.
export function renderPreviewSVG(snap: Snapshot, spaceIndex: number, mode: LayoutMode = "spiral", activeFirst = false): string {
  const { space, display, leaves, total } = computeLayoutFromSnapshot(snap, spaceIndex, mode, activeFirst);
  const items = leaves.map((l) => ({ rect: l.rect, label: winLabel(l.win) }));
  const tag = activeFirst ? " · active-first" : "";
  return svgFromItems(display.frame, items, `${MODE_LABEL[mode]}${tag} · space ${space.index} / display ${space.display} · ${total} windows`);
}

// View of the CURRENT real arrangement — each window at its actual yabai frame
// (like display-census), from a cached snapshot. Not a layout you apply.
export function renderCurrentSVG(snap: Snapshot, spaceIndex: number): string {
  const space = snap.spaces.find((s) => s.index === spaceIndex);
  if (!space) throw new Error(`space ${spaceIndex} not in snapshot`);
  const display = snap.displays.find((d) => d.index === space.display);
  if (!display) throw new Error(`display ${space.display} not in snapshot`);
  const windows = snap.windows.filter((w) => w.space === spaceIndex && isTileable(w) && w.frame);
  const items = windows.map((w) => ({ rect: w.frame!, label: winLabel(w) }));
  return svgFromItems(display.frame, items, `CURRENT arrangement · space ${space.index} / display ${space.display} · ${items.length} windows`);
}
