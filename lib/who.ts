// who — shared fleet-topology computation: which oracle is on which display/space.
// Extracted from scripts/who.ts so the CLI and the HTTP endpoint (server.ts
// GET /api/who) share one implementation instead of duplicating the shape.
import type { Snapshot, YabaiSpace } from "./bsp";
import { displayNames } from "./displays";
import { loadProfile, loadPins, pinMatches, isSyntheticLabel, type OracleRule } from "./oracle-profile";
import { effectiveIdleSeconds, IDLE_THRESHOLD_SEC, IDLE_VISIBLE_MULTIPLIER } from "./idle";

const SHELLS = new Set(["zsh", "sh", "-zsh", "bash", "-bash"]);

// Is the saved profile stale vs the live layout? Two reboot-caused signals:
//  1. a pin's space LABEL no longer resolves (yabai labels don't survive reboot,
//     so the pin is silently disarmed).
//  2. open oracles sit on a different space than their profile rule (space
//     indices renumber on reboot / display reshuffle → raw-index rules drift).
// Returns null when there's no profile at all (→ display-census shows no badge).
function computeProfileStatus(
  fleet: { title: string; space: number; isShell: boolean }[],
  spaces: YabaiSpace[],
): { stale: boolean; reason?: string } | null {
  const profile = loadProfile();
  if (!profile.length) return null;

  const matchRule = (title: string): OracleRule | undefined => {
    const t = title.toLowerCase();
    return profile.find((r) => t.includes(r.match.toLowerCase()) || r.match.toLowerCase().includes(t));
  };

  const reasons: string[] = [];

  const labels = new Set(spaces.map((s) => s.label).filter((l): l is string => !!l));
  const lostLabels = [...new Set(loadPins().map((p) => p.label).filter((l): l is string => !!l))]
    // Synthetic ⭐ labels (auto-assigned by space-pin) self-heal within 60s and
    // are never user-named — keep them out of the census-facing stale reason.
    .filter((l) => !labels.has(l) && !isSyntheticLabel(l));
  if (lostLabels.length) reasons.push(`pin label(s) lost after reboot: ${lostLabels.join(", ")}`);

  let mismatched = 0;
  for (const w of fleet) {
    if (w.isShell) continue;
    // Oracle titles are single tokens (repo names); a spaced title is a status
    // pane ("2 awaiting input · claude agents", "Copy mode: …") whose substring
    // can steal a real rule (…awai-TING…) and fake a drift.
    if (w.title.includes(" ")) continue;
    const rule = matchRule(w.title);
    if (rule?.space != null && rule.space !== w.space) mismatched++;
  }
  if (mismatched >= 2) reasons.push(`${mismatched} oracle(s) off their profile space (likely space renumber)`);

  return reasons.length ? { stale: true, reason: reasons.join("; ") } : { stale: false };
}

export interface FleetRow {
  title: string;
  app: string;
  id: number;
  display: number;
  space: number;
  focus: boolean;
  dup: number;
  displayName: string | null;
  isShell: boolean;
}

// display-census schema v1.2 (additive): EVERY window on EVERY space — feeds
// the per-space mini-map on the public site. frame is yabai's raw GLOBAL
// coordinates (consumer normalizes against its display's frame).
export interface WindowRow {
  id: number;
  app: string;
  title: string;
  space: number;
  display: number;
  focus: boolean;
  // v1.3 (additive): this window matches an ACTIVE pin rule (live enforcement
  // state — false for everything while the global pin toggle is off).
  pinned: boolean;
  // v1.4 (additive): this window matches a whenIdleOnly pin — it parks to its
  // rule's target automatically once the human idles past the threshold.
  whenIdleOnly: boolean;
  frame: { x: number; y: number; w: number; h: number };
}

export interface WhoReport {
  ts: number;
  fleet: FleetRow[];
  displays: { index: number; name: string; frame: { x: number; y: number; w: number; h: number } }[];
  // v1.3 (additive): spaces[].pinned — some active pin rule targets this space.
  spaces: { index: number; display: number; isVisible: boolean; hasFocus: boolean; pinned: boolean }[];
  windows: WindowRow[];
  // display-census schema v1.1: amber "⚠ profile stale" badge when stale=true.
  profile: { stale: boolean; reason?: string } | null;
  // v1.4 (additive): the shared fleet idle clock (census 🌙 badge). seconds is
  // PRIVACY-CLAMPED — /api/who is republished on the PUBLIC census site, and a
  // live "seconds since Nat touched input" counter is a burglar clock, so it's
  // quantized to 10s and capped at the threshold (armed still uses the true
  // value). null = idle binary unavailable. armed = some whenIdleOnly pin is
  // active AND the base threshold passed (windows on a visible space wait for
  // visibleThreshold — see enforcePins).
  idle: { seconds: number | null; threshold: number; visibleThreshold: number; armed: boolean };
}

export async function computeWhoReport(snapshot: Snapshot): Promise<WhoReport> {
  const names = await displayNames();
  const nameOf = (d: { id: number; index: number }) => names[String(d.id)] ?? `display ${d.index}`;

  const rows = snapshot.windows
    .filter((w) => w.app === "WezTerm" && (w.title ?? "").trim() && w.space != null && w.display != null)
    .map((w) => ({
      title: (w.title ?? "").trim(),
      app: w.app,
      id: w.id,
      display: w.display!,
      space: w.space!,
      focus: !!(w as any)["has-focus"],
      dup: 0,
    }));

  const counts = new Map<string, number>();
  for (const r of rows) counts.set(r.title.toLowerCase(), (counts.get(r.title.toLowerCase()) ?? 0) + 1);
  for (const r of rows) r.dup = counts.get(r.title.toLowerCase())!;

  const fleet: FleetRow[] = rows.map((r) => {
    const d = snapshot.displays.find((x) => x.index === r.display);
    return { ...r, displayName: d ? nameOf(d) : null, isShell: SHELLS.has(r.title.toLowerCase()) };
  });

  // v1.2 mini-map rows: all apps, all spaces (invisible ones included — the
  // snapshot already has them). Noise filter per display-census: drop tiny
  // chrome (w<80 or h<60) and untitled windows; KEEP minimized ones with a
  // real frame so the map shows them where they'd restore.
  const pins = loadPins(); // [] while the global toggle is off → pinned:false everywhere (truthful)
  const windows: WindowRow[] = snapshot.windows
    .filter((w) => w.space != null && w.display != null && (w.title ?? "").trim() !== "" &&
      w.frame != null && w.frame.w >= 80 && w.frame.h >= 60)
    .map((w) => ({
      id: w.id,
      app: w.app,
      title: (w.title ?? "").trim(),
      space: w.space!,
      display: w.display!,
      focus: !!(w as any)["has-focus"],
      pinned: pins.some((p) => pinMatches(w, p)),
      whenIdleOnly: pins.some((p) => p.whenIdleOnly && pinMatches(w, p)),
      frame: { x: w.frame!.x, y: w.frame!.y, w: w.frame!.w, h: w.frame!.h },
    }));

  const idleSecs = effectiveIdleSeconds();
  return {
    ts: snapshot.ts,
    fleet,
    windows,
    displays: snapshot.displays.map((d) => ({ index: d.index, name: nameOf(d), frame: d.frame })),
    spaces: snapshot.spaces.map((s) => ({
      index: s.index,
      display: s.display,
      isVisible: !!(s as any)["is-visible"],
      hasFocus: !!(s as any)["has-focus"],
      pinned: pins.some((p) => p.space === s.index || (p.label != null && p.label === s.label)),
    })),
    profile: computeProfileStatus(fleet, snapshot.spaces),
    idle: {
      seconds: idleSecs == null ? null : Math.min(IDLE_THRESHOLD_SEC, Math.floor(idleSecs / 10) * 10),
      threshold: IDLE_THRESHOLD_SEC,
      visibleThreshold: IDLE_THRESHOLD_SEC * IDLE_VISIBLE_MULTIPLIER,
      armed: idleSecs != null && idleSecs >= IDLE_THRESHOLD_SEC && pins.some((p) => p.whenIdleOnly),
    },
  };
}
