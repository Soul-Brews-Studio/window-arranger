// who — CLI query: which oracle is on which display/space?
//   bun scripts/who.ts                 # full fleet map, grouped by display (L→R)
//   bun scripts/who.ts transcriber     # find one oracle (title substring)
//   bun scripts/who.ts --here          # "where am I" — the currently FOCUSED window
//   bun scripts/who.ts --here --notify # same, popped as a macOS notification (no terminal needed)
//   bun scripts/who.ts --json          # machine-readable
//   bun scripts/who.ts --report        # markdown report (pipe to a file or read)
//   bun scripts/who.ts --last          # "ล่าสุด Nat คุยกับใคร" — oracles by last
//                                        NAT-typed message (maw-relay filtered out)
// Reads live yabai state + monitor names from displays.json. Read-only.
import { readdirSync } from "node:fs";
import { yabai } from "../lib/yabai";
import { displayNames } from "../lib/displays";
import { projectBase, dirForTitle, latestJsonl, lastTypedTime } from "../lib/bsp";

const args = process.argv.slice(2);
const JSON_OUT = args.includes("--json");
const REPORT = args.includes("--report");
const HERE = args.includes("--here");
const NOTIFY = args.includes("--notify");
const LAST = args.includes("--last");
const query = args.find((a) => !a.startsWith("--"))?.toLowerCase();

const SHELLS = new Set(["zsh", "sh", "-zsh", "bash", "-bash"]);

const [windows, displays, spaces, names] = await Promise.all([
  yabai.windows(), yabai.displays(), yabai.spaces(), displayNames(),
]);

const nameOf = (d: { id: number; index: number }) => names[String(d.id)] ?? `display ${d.index}`;
const byX = [...displays].sort((a, b) => a.frame.x - b.frame.x);

// --here: "where am I" — the one window macOS says currently has focus.
// Works for ANY app, not just the oracle fleet (you might be focused on Chrome).
if (HERE) {
  const found = windows.find((w) => (w as any)["has-focus"]);
  if (!found) {
    console.log("ไม่รู้ว่าอยู่ไหน — ไม่มีหน้าต่างไหน has-focus ตอนนี้");
    process.exit(1);
  }
  const focused = found;
  const d = displays.find((x) => x.index === focused.display);
  const label = d ? nameOf(d) : `display ${focused.display}`;
  const title = (focused.title ?? "").trim() || focused.app;
  const msg = `${title}  →  display ${focused.display} (${label}) · space ${focused.space}`;
  if (JSON_OUT) {
    console.log(JSON.stringify({ app: focused.app, title: focused.title, display: focused.display, displayName: label, space: focused.space }, null, 2));
  } else {
    console.log(msg);
  }
  if (NOTIFY) {
    const script = `display notification "${msg.replace(/"/g, '\\"')}" with title "📍 อยู่ไหนตอนนี้"`;
    Bun.spawnSync(["osascript", "-e", script]);
  }
  process.exit(0);
}

// --last: which oracle did Nat actually TALK TO most recently? Same tail-scan
// as active-first, but a message only counts as Nat if it isn't oracle-to-oracle
// traffic or harness injection:
//   • maw relays always open with a "[host:oracle]"-style header → drop
//   • "/command" invocations inject the skill body ("Base directory for this
//     skill: …") and local-command caveats as user messages → drop
// A "(ไม่พบ)" row is honest: no Nat-typed message in the log tail (relay-only).
const NAT_TYPED = (t: string) =>
  !/^\s*\[[^\]\n]{1,80}\]/.test(t) &&
  !t.startsWith("Base directory for this skill") &&
  !t.startsWith("<local-command");

if (LAST) {
  let dirs: string[] = [];
  try { dirs = readdirSync(projectBase()); } catch {}
  const seen = new Set<string>();
  const rows: { title: string; t: number; display: number; space: number; focus: boolean }[] = [];
  for (const w of windows) {
    const title = (w.title ?? "").trim();
    if (w.app !== "WezTerm" || !title || SHELLS.has(title.toLowerCase()) || seen.has(title.toLowerCase())) continue;
    seen.add(title.toLowerCase());
    const dir = dirForTitle(title, dirs);
    const jsonl = dir ? latestJsonl(`${projectBase()}/${dir}`) : null;
    // 256KB tail: relay bursts can bury Nat's last real message deeper than 64KB
    rows.push({ title, t: jsonl ? lastTypedTime(jsonl, NAT_TYPED, 262144) : 0,
      display: w.display!, space: w.space!, focus: !!(w as any)["has-focus"] });
  }
  rows.sort((a, b) => b.t - a.t);
  if (JSON_OUT) {
    console.log(JSON.stringify(rows.map((r) => {
      const d = displays.find((x) => x.index === r.display);
      return { ...r, displayName: d ? nameOf(d) : null, lastNatTyped: r.t ? new Date(r.t).toISOString() : null };
    }), null, 2));
    process.exit(0);
  }
  const ago = (t: number) => {
    const m = Math.round((Date.now() - t) / 60000);
    return m < 1 ? "เมื่อกี้" : m < 60 ? `${m} นาทีก่อน` : m < 1440 ? `${Math.round(m / 60)} ชม.ก่อน` : `${Math.round(m / 1440)} วันก่อน`;
  };
  console.log("ล่าสุด Nat คุยกับ (กรอง maw-relay ออกแล้ว):\n");
  for (const r of rows.slice(0, 10)) {
    const d = displays.find((x) => x.index === r.display);
    const when = r.t ? `${new Date(r.t).toLocaleTimeString("th-TH", { hour12: false }).slice(0, 5)} · ${ago(r.t)}` : "(ไม่พบใน log tail)";
    console.log(`${r.focus ? "⭐" : "  "} ${r.title.padEnd(18)} ${when.padEnd(24)} จอ ${r.display} (${d ? nameOf(d) : "?"}) · space ${r.space}`);
  }
  process.exit(0);
}

interface Row { title: string; app: string; id: number; display: number; space: number; focus: boolean; dup: number; }
const fleet: Row[] = windows
  .filter((w) => w.app === "WezTerm" && (w.title ?? "").trim() && w.space != null && w.display != null)
  .map((w) => ({
    title: (w.title ?? "").trim(), app: w.app, id: w.id,
    display: w.display!, space: w.space!, focus: !!(w as any)["has-focus"], dup: 0,
  }));
// mark duplicates (same title > 1 window)
const counts = new Map<string, number>();
for (const r of fleet) counts.set(r.title.toLowerCase(), (counts.get(r.title.toLowerCase()) ?? 0) + 1);
for (const r of fleet) r.dup = counts.get(r.title.toLowerCase())!;

const matched = query ? fleet.filter((r) => r.title.toLowerCase().includes(query)) : fleet;

if (JSON_OUT) {
  // Include the human display name so consumers (e.g. homekeeper's gpu-doctor)
  // can join on title and print "display 2 (DELL U2723QE) · space 7" directly.
  const rows = matched.map((r) => {
    const d = displays.find((x) => x.index === r.display);
    return { ...r, displayName: d ? nameOf(d) : null };
  });
  console.log(JSON.stringify(rows, null, 2));
  process.exit(0);
}

if (query) {
  if (!matched.length) { console.log(`not found: ${query}`); process.exit(1); }
  for (const r of matched) {
    const d = displays.find((x) => x.index === r.display)!;
    console.log(`${r.title}  →  display ${r.display} (${nameOf(d)}) · space ${r.space}${r.focus ? " · FOCUSED" : ""}${r.dup > 1 ? ` · ⚠️ ${r.dup} windows` : ""}`);
  }
  process.exit(0);
}

// full map — grouped by display (physical L→R), then space
const h = REPORT ? "##" : "";
const line = (s = "") => console.log(s);
if (REPORT) {
  line(`# Fleet Report — ${new Date().toISOString().slice(0, 16).replace("T", " ")}`);
  line();
  const shells = fleet.filter((r) => SHELLS.has(r.title.toLowerCase())).length;
  const dups = [...counts.entries()].filter(([, n]) => n > 1);
  line(`**${fleet.length} windows** · ${counts.size} unique titles · ${displays.length} displays · ${spaces.length} spaces`);
  if (dups.length) line(`**⚠️ duplicates:** ${dups.map(([t, n]) => `${t} ×${n}`).join(", ")}`);
  if (shells) line(`**shells (not oracles):** ${shells}`);
  line();
}
for (const d of byX) {
  const dSpaces = spaces.filter((s) => s.display === d.index).sort((a, b) => a.index - b.index);
  line(`${h ? "## " : ""}Display ${d.index} · ${nameOf(d)}${REPORT ? "" : ` (${Math.round(d.frame.w)}×${Math.round(d.frame.h)})`}`);
  for (const s of dSpaces) {
    const here = fleet.filter((r) => r.space === s.index).sort((a, b) => a.title.localeCompare(b.title));
    const vis = (s as any)["is-visible"] ? " [visible]" : "";
    const foc = (s as any)["has-focus"] ? " ★" : "";
    line(`  space ${s.index}${vis}${foc} — ${here.length} oracle(s)`);
    for (const r of here) {
      line(`    ${r.focus ? "●" : " "} ${r.title}${r.dup > 1 ? `  ⚠️×${r.dup}` : ""}${SHELLS.has(r.title.toLowerCase()) ? "  (shell)" : ""}`);
    }
  }
  line();
}
