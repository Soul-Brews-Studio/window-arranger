// park-now — send the whenIdleOnly-pinned browsers to their parking targets
// RIGHT NOW (the skhd hotkey path; the server's 10s tick does the same
// automatically once Nat idles ≥5 min). Standalone on purpose: queries yabai
// directly, so the hotkey keeps working even when the :8900 server is down.
// Same code path as the auto tick (parkNow → enforcePins, no focus steal).
import { pinsEnabled } from "../lib/oracle-profile";
import { parkAndRetile } from "../lib/park";

if (!pinsEnabled()) {
  // honest no-op, but SAY so — "nothing to park" and "pins are off" differ
  console.log("📌 pins are OFF (pins.json.off) — enable via the web header toggle first");
  process.exit(0);
}
const { moved, retiled } = await parkAndRetile();
console.log(moved.length ? `🅿️ parked: ${moved.join(", ")}` : "🅿️ nothing to park");
if (retiled.length) console.log(`   ↻ re-tiled source space(s): ${retiled.join(", ")}`);
