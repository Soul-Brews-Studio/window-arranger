// summon — borrow an oracle window, then send it home.
//   bun scripts/summon.ts <name>            # bring the oracle HERE (records where it came from)
//   bun scripts/summon.ts --return <name>   # send it back to the space it was summoned from
//   bun scripts/summon.ts --return          # send EVERY summoned window home
//   bun scripts/summon.ts --list            # who is currently summoned (and their home)
// State lives in ~/.config/window-arranger-oracle/summons.json — {id, title, fromSpace, at}.
// NOTE: a PINNED oracle (pins.json) will be snapped home by the pin tracker ~10s
// after you summon it — pins deliberately outrank summons.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { yabai } from "../lib/yabai";

const STATE = `${process.env.HOME}/.config/window-arranger-oracle/summons.json`;

interface Summon { id: number; title: string; fromSpace: number; at: string; }
const load = (): Summon[] => { try { return JSON.parse(readFileSync(STATE, "utf8")); } catch { return []; } };
const save = (s: Summon[]) => { mkdirSync(dirname(STATE), { recursive: true }); writeFileSync(STATE, JSON.stringify(s, null, 2) + "\n"); };

const args = process.argv.slice(2);
const RETURN = args.includes("--return");
const LIST = args.includes("--list");
const query = args.find((a) => !a.startsWith("--"))?.toLowerCase();

if (LIST) {
  const s = load();
  if (!s.length) { console.log("no summons active"); process.exit(0); }
  for (const x of s) console.log(`${x.title}  (id ${x.id})  home = space ${x.fromSpace}  since ${x.at}`);
  process.exit(0);
}

const windows = await yabai.windows();
const spaces = await yabai.spaces();
const here = spaces.find((s) => s["has-focus"])?.index;

if (RETURN) {
  const summons = load();
  const targets = query ? summons.filter((s) => s.title.toLowerCase().includes(query)) : summons;
  if (!targets.length) { console.log(query ? `no summon recorded for: ${query}` : "no summons to return"); process.exit(1); }
  const remaining: Summon[] = summons.filter((s) => !targets.includes(s));
  for (const t of targets) {
    const win = windows.find((w) => w.id === t.id);
    if (!win) { console.log(`↩︎ ${t.title}: window gone (closed?) — dropping record`); continue; }
    if (win.space === t.fromSpace) { console.log(`↩︎ ${t.title}: already home (space ${t.fromSpace})`); continue; }
    await yabai.moveToSpace(t.id, t.fromSpace);
    console.log(`↩︎ ${t.title} → home space ${t.fromSpace}`);
  }
  save(remaining);
  process.exit(0);
}

if (!query) { console.error("usage: summon <name> | --return [name] | --list"); process.exit(1); }
if (here == null) { console.error("summon: no focused space found"); process.exit(1); }

const match = windows.find((w) =>
  w.app === "WezTerm" && (w.title ?? "").toLowerCase().includes(query));
if (!match) { console.error(`summon: no window matching '${query}'`); process.exit(1); }

const summons = load().filter((s) => s.id !== match.id); // re-summon replaces the record
if (match.space === here) {
  console.log(`${match.title} is already here (space ${here})`);
  process.exit(0);
}
summons.push({ id: match.id, title: (match.title ?? "").trim(), fromSpace: match.space!, at: new Date().toISOString() });
save(summons);
await yabai.moveToSpace(match.id, here);
console.log(`⬇︎ summoned ${match.title}: space ${match.space} → ${here}  (return: bun scripts/summon.ts --return ${query})`);
