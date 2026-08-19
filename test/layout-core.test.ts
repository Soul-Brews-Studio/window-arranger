// layout-core is the shared, pure packing geometry (also used by agora's board).
// These lock the contract agora relies on: full-frame coverage, item ordering,
// negative origins, and the mode set.
import { test, expect } from "bun:test";
import { packItems, packRects, LAYOUT_MODES, renderRectsSVG, normalizeRectToFrame, type Rect } from "../lib/layout-core";

const F: Rect = { x: 0, y: 0, w: 1200, h: 800 };

test("normalizeRectToFrame maps global px-frames onto a 0..1 frame (mirror view)", () => {
  // a left display at NEGATIVE origin (the DELL U2719DC case, x=-2560)
  const display = { x: -2560, y: 0, w: 2560, h: 1440 };
  const win = { x: -2560, y: 0, w: 1280, h: 720 }; // fills the top-left quarter
  expect(normalizeRectToFrame(win, display)).toEqual({ x: 0, y: 0, w: 0.5, h: 0.5 });
  const win2 = { x: -2560 + 1280, y: 720, w: 1280, h: 720 }; // bottom-right quarter
  expect(normalizeRectToFrame(win2, display)).toEqual({ x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
  // portrait display (h > w) — pure ratio math, no special-casing needed
  const portrait = { x: 4736, y: 0, w: 1440, h: 2560 };
  const pwin = { x: 4736, y: 1280, w: 1440, h: 1280 }; // bottom half
  expect(normalizeRectToFrame(pwin, portrait)).toEqual({ x: 0, y: 0.5, w: 1, h: 0.5 });
});

test("columns/rows fill the frame edge-to-edge (gap 0)", () => {
  const cols = packRects(F, 3, 0, "columns");
  expect(cols.reduce((s, r) => s + r.w, 0)).toBeCloseTo(F.w);
  expect(cols.every((r) => r.h === F.h)).toBe(true);
  const rows = packRects(F, 4, 0, "rows");
  expect(rows.reduce((s, r) => s + r.h, 0)).toBeCloseTo(F.h);
  expect(rows.every((r) => r.w === F.w)).toBe(true);
});

test("packItems returns one rect per item, index-tagged in order", () => {
  const items = packItems(F, 5, 8, "grid");
  expect(items.map((i) => i.index)).toEqual([0, 1, 2, 3, 4]);
});

test("negative origin frames are honored (a board panning left)", () => {
  const neg: Rect = { x: -500, y: -300, w: 400, h: 400 };
  const r = packRects(neg, 2, 0, "columns");
  expect(r[0].x).toBe(-500);
  expect(r[1].x).toBe(-500 + 200); // second column starts halfway
});

test("every declared mode produces exactly `count` rects", () => {
  for (const mode of LAYOUT_MODES) {
    expect(packRects(F, 6, 8, mode)).toHaveLength(6);
  }
  expect(packRects(F, 0, 8, "grid")).toHaveLength(0);
});

test("renderRectsSVG emits a self-contained svg", () => {
  const svg = renderRectsSVG(F, [{ rect: F, label: "x" }], { title: "t" });
  expect(svg).toContain("<svg");
  expect(svg).toContain("</svg>");
});
