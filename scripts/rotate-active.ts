// rotate-active — arrange the ACTIVE display's focused space with a layout profile
// (always active-first). Bound to hotkeys via skhd:
//   ctrl+alt+cmd - up    : bun scripts/rotate-active.ts                 (next in ring)
//   ctrl+alt+cmd - down  : bun scripts/rotate-active.ts --prev          (prev in ring)
//   ctrl+alt+cmd - 1..6  : bun scripts/rotate-active.ts <mode>          (apply that mode)
//   ctrl+alt+cmd - ]     : bun scripts/rotate-active.ts --toggle columns flip
// The ring index persists so ↑/↓ step symmetrically and wrap; passing an explicit
// mode (or a toggle result) also updates the index so ↑/↓ continue from there.
// --dry prints, no moves.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { yabai } from "../lib/yabai";
import { applyLayout, LAYOUT_MODES, type LayoutMode } from "../lib/bsp";

const args = process.argv.slice(2);
const DRY = args.includes("--dry");
const DIR = args.includes("--prev") ? -1 : 1;
// An explicit mode arg (e.g. "spiral", "columns") applies that profile directly.
const explicit = args.find((a) => (LAYOUT_MODES as string[]).includes(a)) as LayoutMode | undefined;
// --toggle A B : one key alternates between two modes, based on the LAST-applied
// mode — no fixed start. If the last apply was A → go B, otherwise → go A. So a
// second/third press just flips A⇄B. Shares the ring state below, so ↑/↓ continue.
const toggleAt = args.indexOf("--toggle");
const togglePair = toggleAt >= 0
  ? (args.slice(toggleAt + 1, toggleAt + 3).filter((a) => (LAYOUT_MODES as string[]).includes(a)) as LayoutMode[])
  : [];
const STATE = `${process.env.HOME}/.config/window-arranger-oracle/rotate-state.json`;
// The ring — same order as the app's mode list, so number keys map 1→spiral … 6→rows.
const ROTATION: LayoutMode[] = [...LAYOUT_MODES];
const N = ROTATION.length;
const readLastIdx = (): number => {
  try { return JSON.parse(readFileSync(STATE, "utf8")).idx ?? -1; } catch { return -1; }
};

const spaces = await yabai.spaces();
const active = spaces.find((s) => s["has-focus"]) ?? spaces.find((s) => s["is-visible"]);
if (!active) {
  console.error("rotate-active: no active/visible space found");
  process.exit(1);
}

let idx: number;
let how: string;
if (togglePair.length === 2) {
  const [a, b] = togglePair;
  const last = readLastIdx();
  const lastMode = last >= 0 ? ROTATION[last] : undefined;
  const next = lastMode === a ? b : a; // last was A → B; anything else → A
  idx = ROTATION.indexOf(next);
  how = `toggle ${a}⇄${b} → ${next}`;
} else if (explicit) {
  idx = ROTATION.indexOf(explicit); // direct jump to a specific profile
  how = `direct → ${ROTATION[idx]}`;
} else {
  const last = readLastIdx();
  idx = last < 0 ? (DIR > 0 ? 0 : N - 1) : (((last + DIR) % N) + N) % N;
  how = `${DIR > 0 ? "next" : "prev"} → ${ROTATION[idx]}`;
}
const mode = ROTATION[idx];

if (DRY) {
  console.log(`[dry] ${how}: space ${active.index} (display ${active.display}) + active-first`);
  process.exit(0);
}

mkdirSync(dirname(STATE), { recursive: true });
writeFileSync(STATE, JSON.stringify({ idx }) + "\n");

const { moved } = await applyLayout(active.index, mode, /* activeFirst */ true);
console.log(`rotate-active: space ${active.index} (display ${active.display}) → ${mode} + active-first (${moved} windows)`);
