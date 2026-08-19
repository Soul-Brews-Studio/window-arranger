// oracle-profile — the "assign each oracle to a space" layer. A profile is a list
// of routing rules; 📸 Snapshot writes one FROM the current window positions (so you
// arrange by hand, then save), and ♻️ Restore re-applies it. Routing only: we record
// which SPACE each oracle sits on, not pixel frames — you re-tile with a layout mode
// after. yabai `window --space` moves are verified to work in non-SA mode (see
// CLAUDE.md "Key Technical Finding").
import { readFileSync, writeFileSync, mkdirSync, existsSync, copyFileSync, renameSync } from "node:fs";
import { dirname } from "node:path";
import type { YabaiWindow } from "./bsp";
import type { YabaiClient } from "./yabai";
import { IDLE_THRESHOLD_SEC, IDLE_VISIBLE_MULTIPLIER } from "./idle";

// `app` widens a pin beyond WezTerm: the rule matches windows whose app name
// contains it (e.g. a browser window used as a wall feed). Without `app`, rules
// keep the original fleet-only behavior (WezTerm + non-empty title).
// `origin` tags machine-written rules (e.g. "space-pin:s4") so unpin can remove
// exactly its own rules and never touch Nat's hand-written ones.
// `whenIdleOnly` (Nat 2026-07-12: "ถ้ามนุษย์ active ให้เป็นไปตามมนุษย์"): the rule
// only enforces once the human has been idle ≥ IDLE_THRESHOLD_SEC — while Nat
// is driving, his window placement always wins.
export interface OracleRule { match: string; app?: string; display?: number; displayName?: string; space?: number; label?: string; grid?: string; whenIdleOnly?: boolean; origin?: string; note?: string; }

export const PROFILE_PATH = `${process.env.HOME}/.config/window-arranger-oracle/oracle-profile.json`;
// Shells aren't oracles — skip them so a snapshot captures only the fleet.
const SHELLS = new Set(["zsh", "sh", "-zsh", "bash", "-bash"]);

export function loadProfile(): OracleRule[] {
  try { return JSON.parse(readFileSync(PROFILE_PATH, "utf8")); } catch { return []; }
}

// Overwrites the single profile file, backing up any existing one first
// (Nothing is Deleted — recover from oracle-profile.json.bak.<stamp>).
export function saveProfile(rules: OracleRule[]): string | null {
  mkdirSync(dirname(PROFILE_PATH), { recursive: true });
  let backup: string | null = null;
  if (existsSync(PROFILE_PATH)) {
    backup = `${PROFILE_PATH}.bak.${new Date().toISOString().replace(/[:.]/g, "-")}`;
    copyFileSync(PROFILE_PATH, backup);
  }
  writeFileSync(PROFILE_PATH, JSON.stringify(rules, null, 2) + "\n");
  return backup;
}

// Build a profile from live positions: each fleet oracle (WezTerm, real title) →
// its current space. One rule per title (first window wins on duplicates).
export function snapshotProfile(windows: YabaiWindow[]): OracleRule[] {
  const seen = new Set<string>();
  const rules: OracleRule[] = [];
  for (const w of windows) {
    if (w.app !== "WezTerm" || w.space == null) continue;
    const title = (w.title ?? "").trim();
    const key = title.toLowerCase();
    if (!title || SHELLS.has(key) || seen.has(key)) continue;
    // Oracle titles are single tokens (repo names); a spaced title is a status
    // pane ("2 awaiting input · claude agents", "Copy mode: …") — saving it as
    // a rule lets its substring steal a real oracle's match later.
    if (title.includes(" ")) continue;
    seen.add(key);
    rules.push({ match: title, space: w.space });
  }
  return rules;
}

// ---- pins: rules that are ENFORCED continuously (tracked), not just on Restore ----
// ~/.config/window-arranger-oracle/pins.json — same rule shape as the profile.
// e.g. [{ "match": "nh", "label": "nh" }] keeps every nh* window on the space
// labeled "nh", snapping drifters back on the server's pin tick.
export const PINS_PATH = `${process.env.HOME}/.config/window-arranger-oracle/pins.json`;

// pins.json is HAND-EDITED by Nat and only ever READ here (the enforce loop never
// writes it) — so it's safe to edit live; changes are picked up on the next 10s
// tick, no restart. A syntax error would otherwise silently disable ALL pins, so
// we shout it into the log instead of failing quiet. Unknown fields (e.g. "note")
// are ignored by enforcePins, so rules can carry inline annotations.
export function loadPins(): OracleRule[] {
  let raw: string;
  try { raw = readFileSync(PINS_PATH, "utf8"); } catch { return []; } // no file = no pins
  try { return JSON.parse(raw); }
  catch (e) { console.error(`⚠️ pins.json parse error (all pins disabled until fixed): ${e}`); return []; }
}

// ---- pins on/off switch (UI-facing) ----
// Disabling = rename pins.json → pins.json.off (same gesture as doing it by
// hand in the shell, durable across server restarts, rules never deleted).
// The 10s loop calls loadPins() every tick, so a toggle takes effect on the
// next tick with no restart.
export const PINS_OFF_PATH = `${PINS_PATH}.off`;

export function pinsEnabled(): boolean { return existsSync(PINS_PATH); }

// Rule count for the UI regardless of on/off state (reads whichever file exists).
export function pinRuleCount(): number {
  const p = existsSync(PINS_PATH) ? PINS_PATH : PINS_OFF_PATH;
  try { return (JSON.parse(readFileSync(p, "utf8")) as unknown[]).length; } catch { return 0; }
}

// Does a window match a pin rule? Shared by the enforcement loop and /api/who
// (v1.3 reports live pin state). app-scoped rules match any app containing
// pin.app; plain rules keep the fleet-only behavior (WezTerm, non-empty title).
export function pinMatches(w: YabaiWindow, pin: OracleRule): boolean {
  const title = (w.title ?? "").trim();
  if (pin.app != null) {
    return w.app.toLowerCase().includes(pin.app.toLowerCase()) &&
      title.toLowerCase().includes(pin.match.toLowerCase());
  }
  return w.app === "WezTerm" && title !== "" &&
    title.toLowerCase().includes(pin.match.toLowerCase());
}

// ---- space-pin (census web ⭐, Nat 2026-07-11) — LABEL-based so the star
// FOLLOWS the space through a renumber (census's UX call: ⭐ means "this
// workspace / this group of oracles", not "this index"). Each pin writes one
// rule per unique (app,title) on the space, targeting the space's LABEL (not a
// raw index — indices renumber, labels don't; and auto-heal re-applies labels
// lost on reboot). Rules are origin-tagged so unpin removes exactly its own and
// never touches Nat's hand-written rules. Synthetic labels (auto-assigned when
// a space has none) are prefixed ⭐ so they can be recognized/cleaned and kept
// out of user-facing strings.
const activePinsFile = () =>
  existsSync(PINS_PATH) || !existsSync(PINS_OFF_PATH) ? PINS_PATH : PINS_OFF_PATH;

function readActivePins(): OracleRule[] {
  try { return JSON.parse(readFileSync(activePinsFile(), "utf8")); } catch { return []; }
}

export const SYNTH_LABEL_PREFIX = "⭐";
export const isSyntheticLabel = (l: string | undefined): boolean => !!l && l.startsWith(SYNTH_LABEL_PREFIX);
export const spacePinTag = (label: string) => `space-pin:${label}`;

// Write (or clear, when pinned=false) the rules for the space labeled `label`.
// `windows` are the windows currently ON that space (caller filters by index).
export function setSpacePin(label: string, windows: YabaiWindow[], pinned: boolean): { count: number } {
  const tag = spacePinTag(label);
  const rest = readActivePins().filter((r) => r.origin !== tag);
  let added: OracleRule[] = [];
  if (pinned) {
    const seen = new Set<string>();
    for (const w of windows) {
      const title = (w.title ?? "").trim();
      if (!title || SHELLS.has(title.toLowerCase()) || seen.has(`${w.app}|${title.toLowerCase()}`)) continue;
      seen.add(`${w.app}|${title.toLowerCase()}`);
      const rule: OracleRule = { match: title, label, origin: tag };
      if (w.app !== "WezTerm") rule.app = w.app; // non-fleet windows need the app scope to match
      added.push(rule);
    }
  }
  writeFileSync(activePinsFile(), JSON.stringify([...rest, ...added], null, 2) + "\n");
  return { count: added.length };
}

export function setPinsEnabled(on: boolean): boolean {
  if (on) {
    if (!existsSync(PINS_PATH) && existsSync(PINS_OFF_PATH)) renameSync(PINS_OFF_PATH, PINS_PATH);
  } else if (existsSync(PINS_PATH)) {
    // If a stale .off already exists, keep it (Nothing is Deleted) — shelve it
    // with a timestamp instead of letting rename clobber it.
    if (existsSync(PINS_OFF_PATH)) renameSync(PINS_OFF_PATH, `${PINS_OFF_PATH}.bak.${new Date().toISOString().replace(/[:.]/g, "-")}`);
    renameSync(PINS_PATH, PINS_OFF_PATH);
  }
  return pinsEnabled();
}

// One enforcement pass: for each pin, snap matching fleet windows back to the
// pin's target. Two kinds of target, resolved DURABLY (survive reboot renumber):
//   • display — by monitor NAME (displayName; yabai display indices reshuffle on
//     reboot, but a monitor's name/id is stable) or raw index. Lands on that
//     display's active space. Used for the guardian squad → smallest screen.
//   • space   — by LABEL (labels survive space renumbering) or raw index.
// Anything that can't be resolved right now is skipped quietly (never guess).
export async function enforcePins(
  client: YabaiClient,
  windows: YabaiWindow[],
  spaces: { index: number; label?: string; ["is-visible"]?: boolean }[],
  displays: { index: number; id: number }[] = [],
  names: Record<string, string> = {},
  pins: OracleRule[] = loadPins(),
  // Human-idle seconds for whenIdleOnly rules. undefined/null = "cannot prove
  // idle" → those rules skip (fail safe). Infinity = park-now (manual force).
  idle?: number | null,
): Promise<{ moved: string[]; movedFrom: number[] }> {
  const moved: string[] = [];
  // Source space of each moved window, captured AT MOVE TIME (w.space is still
  // the pre-move value here). parkAndRetile uses this to re-tile the spaces a
  // window left — reading it now avoids a post-move client.windows() that would
  // hit yabai's documented --space list lag and miss the change (review 2026-07-12).
  const movedFrom: number[] = [];
  const displayIndexByName = (name: string): number | undefined => {
    const id = Object.keys(names).find((k) => names[k] === name);
    return id == null ? undefined : displays.find((d) => String(d.id) === id)?.index;
  };
  const matches = pinMatches;

  // whenIdleOnly gate, per window: anything on a currently-VISIBLE space may be
  // watched with zero input (a video on the second monitor — focus not
  // required), so it needs 3× the idle. Hidden-space windows use the base tier.
  const idleGateOk = (pin: OracleRule, w: YabaiWindow): boolean => {
    if (!pin.whenIdleOnly) return true;
    if (idle == null) return false;
    const visible = !!spaces.find((s) => s.index === w.space)?.["is-visible"];
    const need = visible ? IDLE_THRESHOLD_SEC * IDLE_VISIBLE_MULTIPLIER : IDLE_THRESHOLD_SEC;
    return idle >= need;
  };

  for (const pin of pins) {
    // display pin takes precedence (durable via displayName)
    if (pin.displayName != null || pin.display != null) {
      const targetDisp = pin.displayName != null ? displayIndexByName(pin.displayName) : pin.display;
      if (targetDisp == null) continue; // monitor not attached / name unknown → skip
      for (const w of windows) {
        if (!matches(w, pin) || w.display === targetDisp || !idleGateOk(pin, w)) continue;
        if (w.space != null) movedFrom.push(w.space);
        await client.moveToDisplay(w.id, targetDisp, pin.grid);
        moved.push(`${(w.title ?? "").trim()} (d${w.display}→d${targetDisp})`);
      }
      continue;
    }
    // space pin (label > index)
    const target = pin.label != null ? spaces.find((s) => s.label === pin.label)?.index : pin.space;
    if (target == null) continue;
    for (const w of windows) {
      if (!matches(w, pin) || w.space === target || !idleGateOk(pin, w)) continue;
      if (w.space != null) movedFrom.push(w.space);
      await client.moveToSpace(w.id, target);
      moved.push(`${(w.title ?? "").trim()} (s${w.space}→s${target})`);
    }
  }
  return { moved, movedFrom };
}

// Park-now (skhd hotkey / census web button): apply the whenIdleOnly rules
// IMMEDIATELY — idle=∞ satisfies every gate, so the manual gesture and the 10s
// auto tick are ONE code path (same moves, same no-focus-steal semantics).
export async function parkNow(
  client: YabaiClient,
  windows: YabaiWindow[],
  spaces: { index: number; label?: string; ["is-visible"]?: boolean }[],
  displays: { index: number; id: number }[] = [],
  names: Record<string, string> = {},
  pins: OracleRule[] = loadPins().filter((p) => p.whenIdleOnly),
): Promise<{ moved: string[]; movedFrom: number[] }> {
  if (!pins.length) return { moved: [], movedFrom: [] };
  return enforcePins(client, windows, spaces, displays, names, pins, Infinity);
}

// ---- auto-heal (Nat 2026-07-10: "รู้ว่า stale แล้วทำไมไม่ update ให้เลย") ----
// Heals ONLY what needs no intent interpretation; real drift keeps the badge.
//   1. lost pin labels — labels die on reboot. If a pin's label is on no live
//      space but ALL windows matching the pin sit together on ONE space,
//      re-label that space. (The label was the durable key; the group is the
//      evidence of where it belongs.)
//   2. pure renumber — if profile space-groups are intact but indices shifted
//      (reboot signature), remap the profile's numbers. Guards: every group's
//      open members must agree on one live space, the saved→live mapping must
//      be injective, and ≥2 groups must have moved (a single moved group is
//      indistinguishable from an intentional move → human decides, not us).
export async function autoHealProfile(
  client: YabaiClient,
  windows: YabaiWindow[],
  spaces: { index: number; label?: string }[],
  pins: OracleRule[] = loadPins(),
): Promise<string[]> {
  const healed: string[] = [];
  const fleet = windows.filter((w) => w.app === "WezTerm" && (w.title ?? "").trim() && w.space != null);
  // The one space a match's windows all share, or null (absent / split = ambiguous).
  const spaceOf = (match: string): number | null => {
    const hits = fleet.filter((w) => (w.title ?? "").toLowerCase().includes(match.toLowerCase()));
    if (!hits.length) return null;
    const s = hits[0].space!;
    return hits.every((w) => w.space === s) ? s : null;
  };

  // Pin labels heal against the windows the PIN actually matches (pinMatches
  // honors app scope) — an app-scoped pin like {app:"Comet", match:""} must
  // never take its evidence from the WezTerm fleet.
  const pinSpaceOf = (pin: OracleRule): number | null => {
    const hits = windows.filter((w) => pinMatches(w, pin) && w.space != null);
    if (!hits.length) return null;
    const s = hits[0].space!;
    return hits.every((w) => w.space === s) ? s : null;
  };

  const liveLabels = new Set(spaces.map((s) => s.label).filter((l): l is string => !!l));
  for (const pin of pins) {
    if (pin.label == null || liveLabels.has(pin.label)) continue;
    // whenIdleOnly (park) pins are the INVERSE case: their matched windows sit
    // AWAY from the target by design (Comet lives on Nat's working space, only
    // visits 'park' while idle) — so window location is NOT evidence of the
    // label's home. Healing here would relabel the WORKING space as the parking
    // spot and then actively snap the browser back to it (review 2026-07-12).
    // A lost park label stays lost → rule skips quietly + stale badge tells a human.
    if (pin.whenIdleOnly) continue;
    const target = pinSpaceOf(pin);
    if (target == null) continue; // no unambiguous evidence → leave it to a human
    await client.labelSpace(target, pin.label);
    healed.push(`re-labeled space ${target} → '${pin.label}'`);
  }

  const rules = loadProfile();
  const mapping = new Map<number, number>(); // saved space → live space
  let consistent = true;
  for (const r of rules) {
    if (r.space == null) continue;
    const live = spaceOf(r.match);
    if (live == null) continue; // oracle closed → no evidence for this rule
    const prev = mapping.get(r.space);
    if (prev != null && prev !== live) { consistent = false; break; } // group split = real drift
    mapping.set(r.space, live);
  }
  const movedGroups = [...mapping].filter(([saved, live]) => saved !== live);
  const targets = [...mapping.values()];
  if (consistent && movedGroups.length >= 2 && new Set(targets).size === targets.length) {
    const next = rules.map((r) =>
      r.space != null && mapping.has(r.space) ? { ...r, space: mapping.get(r.space)! } : r);
    saveProfile(next); // timestamped backup built in — Nothing is Deleted
    healed.push(`profile remap (pure renumber): ${movedGroups.map(([a, b]) => `s${a}→s${b}`).join(", ")}`);
    // Space-based PIN rules hold a raw index too (space-pin:sN + any
    // hand-written {space:N}) — shift them by the same renumber mapping, or
    // they'd keep enforcing the OLD index against whatever space slid into it.
    const pins = readActivePins();
    let pinsChanged = false;
    const remapped = pins.map((r) => {
      if (r.space != null && mapping.has(r.space) && mapping.get(r.space) !== r.space) {
        pinsChanged = true;
        return { ...r, space: mapping.get(r.space)!, origin: r.origin?.startsWith("space-pin:") ? `space-pin:s${mapping.get(r.space)}` : r.origin };
      }
      return r;
    });
    if (pinsChanged) {
      writeFileSync(activePinsFile(), JSON.stringify(remapped, null, 2) + "\n");
      healed.push("pin rules shifted with the renumber");
    }
  }
  return healed;
}

// Restore: move each matched window to its rule's target (label > space > display).
// First matching rule wins, mirroring the Swift menu-bar arrangeOracles.
export async function arrangeByProfile(
  client: YabaiClient,
  windows: YabaiWindow[],
  rules: OracleRule[],
): Promise<{ moved: number; matched: number }> {
  let moved = 0, matched = 0;
  for (const w of windows) {
    const rule = rules.find((r) =>
      (w.title ?? "").toLowerCase().includes(r.match.toLowerCase()) ||
      w.app.toLowerCase().includes(r.match.toLowerCase()));
    if (!rule) continue;
    matched++;
    if (rule.label != null) await client.moveToSpace(w.id, rule.label);
    else if (rule.space != null) await client.moveToSpace(w.id, rule.space);
    else if (rule.display != null) await client.moveToDisplay(w.id, rule.display, rule.grid);
    else continue;
    moved++;
  }
  return { moved, matched };
}
