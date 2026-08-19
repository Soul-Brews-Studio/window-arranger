// park orchestration — park the whenIdleOnly-pinned windows, THEN re-tile every
// space they LEFT so the gap fills (Nat 2026-07-12: "the moved to another and
// that current should re-organized"). Shared by the ⌃⌥⌘⇧Enter hotkey
// (scripts/park-now.ts) and POST /api/park so both behave identically.
import { yabai, type YabaiClient } from "./yabai";
import { parkNow } from "./oracle-profile";
import { retileSpace } from "./bsp";
import { displayNames } from "./displays";

export async function parkAndRetile(client: YabaiClient = yabai): Promise<{ moved: string[]; retiled: number[] }> {
  const [windows, spaces, displays] = await Promise.all([client.windows(), client.spaces(), client.displays()]);
  const names = await displayNames();

  // parkNow reports movedFrom = the source space of each window it moved,
  // captured at move time (NOT via a post-move re-query, which would hit yabai's
  // --space list lag and report the window still on its old space → empty diff →
  // the re-tile silently no-ops; review 2026-07-12). Re-tile each distinct
  // source so the gap the browser left fills. parkNow never moves a window
  // already on its target, so a source is never also a destination.
  const { moved, movedFrom } = await parkNow(client, windows, spaces, displays, names);
  const retiled: number[] = [];
  for (const s of [...new Set(movedFrom)]) {
    try {
      await retileSpace(s, client);
      retiled.push(s);
    } catch { /* a source space that vanished mid-move — skip, never fail the park */ }
  }
  return { moved, retiled };
}
