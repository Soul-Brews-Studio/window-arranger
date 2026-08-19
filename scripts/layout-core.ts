#!/usr/bin/env bun
// layout-core CLI — language-agnostic access to the pure packing geometry.
// Any board / tool (not just this repo) can shell out to it: JSON in, JSON out,
// no yabai, no state. First consumer: agora's Oracle Board "tidy selection".
//
//   echo '{"outer":{"x":0,"y":0,"w":1600,"h":900},"count":5,"gap":8,"mode":"grid"}' \
//     | bun scripts/layout-core.ts
//   → [{"rect":{"x":..,"y":..,"w":..,"h":..},"index":0}, ...]
//
//   # SVG thumbnail from rects (rect[] → svg):
//   echo '{"frame":{...},"rects":[{...},{...}],"title":"preview","svg":true}' \
//     | bun scripts/layout-core.ts
//   → <svg ...>...</svg>
//
//   bun scripts/layout-core.ts --modes    # list valid modes
import { packItems, renderRectsSVG, LAYOUT_MODES, type LayoutMode, type Rect } from "../lib/layout-core";

if (process.argv.includes("--modes")) {
  console.log(JSON.stringify(LAYOUT_MODES));
  process.exit(0);
}

const raw = await Bun.stdin.text();
let input: any;
try {
  input = JSON.parse(raw);
} catch (e) {
  console.error(`layout-core: invalid JSON on stdin: ${e}`);
  process.exit(1);
}

// SVG mode: {frame, rects:[{rect?|x,y,w,h}], title?} → svg string
if (input.svg) {
  const frame: Rect = input.frame ?? input.outer;
  const items = (input.rects ?? input.items ?? []).map((r: any) =>
    r.rect ? { rect: r.rect, label: r.label } : { rect: r, label: r.label });
  if (!frame) { console.error("layout-core --svg: need {frame} (or {outer})"); process.exit(1); }
  console.log(renderRectsSVG(frame, items, { title: input.title }));
  process.exit(0);
}

// Pack mode: {outer, count, gap, mode} → [{rect, index}]
const outer: Rect = input.outer ?? input.frame;
const count: number = input.count ?? (Array.isArray(input.items) ? input.items.length : 0);
const gap: number = input.gap ?? 0;
const mode: LayoutMode = input.mode ?? "grid";
if (!outer || typeof outer.w !== "number" || typeof outer.h !== "number") {
  console.error('layout-core: need {"outer":{x,y,w,h}, "count", "gap", "mode"}');
  process.exit(1);
}
if (!LAYOUT_MODES.includes(mode)) {
  console.error(`layout-core: unknown mode "${mode}" — one of ${LAYOUT_MODES.join(", ")}`);
  process.exit(1);
}
console.log(JSON.stringify(packItems(outer, count, gap, mode)));
