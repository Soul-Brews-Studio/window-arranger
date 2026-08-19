// move-to-space N — SEND the focused window to space N and STAY put (no follow),
// then re-tile the current space (the one you're still on) to fill the gap the
// window left. Backs the ⌃⌥⌘⇧1-9 skhd bindings (Nat 2026-07-12: "ส่งไปอย่างเดียว
// ไม่ต้องไปด้วย" — send only, don't follow). Nat's earlier "re-organize" applies
// to the space you STAY on now, so only the source is re-tiled (N is untouched —
// you're not there to see it, and leaving it alone is the least surprising).
import { yabai } from "../lib/yabai";
import { retileSpace } from "../lib/bsp";

const n = Number(process.argv[2]);
if (!Number.isInteger(n) || n < 1) {
  console.error("usage: move-to-space <N>");
  process.exit(1);
}

const [wins, spaces] = await Promise.all([yabai.windows(), yabai.spaces()]);
const targetExists = spaces.some((s) => s.index === n);
const focused = wins.find((w) => (w as any)["has-focus"]);
const source = focused?.space ?? null;

// Send the focused window over (no-op if nothing focused or N is out of range —
// both tolerated). NO focusSpace: the window leaves, you stay where you are.
if (focused) await yabai.moveToSpace(focused.id, n);

// Re-tile ONLY the space you're still on, and only when a window actually left
// it for a real other space — so pressing this with nothing focused, or for a
// non-existent N, moves nothing and re-tiles nothing (no unrequested motion).
if (focused && targetExists && source != null && source !== n) {
  try {
    await retileSpace(source);
    console.log(`sent ${focused.id} → space ${n}; stayed on ${source} (re-tiled)`);
  } catch {
    console.log(`sent ${focused.id} → space ${n}; stayed on ${source} (re-tile skipped)`);
  }
} else {
  console.log(focused ? (targetExists ? `already on ${n}` : `space ${n} not found — window stays`) : "nothing focused");
}
