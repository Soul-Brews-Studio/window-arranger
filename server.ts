// window-arranger — local-only tool to preview + apply yabai BSP layouts per space.
// Separate app from display-census on purpose: this one WRITES to real windows
// (yabai -m space --layout, window --move/--resize), so it stays local-only and
// is never deployed alongside the public display-census read replica.
//
// Reads are served from lib/engine.ts's cached Snapshot (zero yabai forks per
// request); writes mutate yabai live, then forceRefresh() the snapshot once.
import { Elysia } from "elysia";
import { appendFileSync, existsSync } from "node:fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { renderPreviewSVG, renderCurrentSVG, applyLayout, gatherToMain, LAYOUT_MODES, type LayoutMode } from "./lib/bsp";
import { displayNames, refreshDisplayConfig, CONFIG_PATH } from "./lib/displays";
import { startEngine, getSnapshot, forceRefresh, beginWrite, endWrite } from "./lib/engine";
import { yabai } from "./lib/yabai";
import { snapshotProfile, arrangeByProfile, saveProfile, loadProfile, enforcePins, loadPins, pinsEnabled, setPinsEnabled, pinRuleCount, autoHealProfile, setSpacePin, SYNTH_LABEL_PREFIX, isSyntheticLabel } from "./lib/oracle-profile";
import { parkAndRetile } from "./lib/park";
import { effectiveIdleSeconds, noteRemoteHumanAction } from "./lib/idle";
import { computeWhoReport } from "./lib/who";

const DIR = dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8900);
// WA_SHADOW=1: conformance/shadow instance — background loops (pins enforce,
// auto-heal, argus publish) stay OFF so it can never fight the real :8900
// server or push test data outward. Same contract as the Swift --shadow flag.
const SHADOW = process.env.WA_SHADOW === "1";

// A second copy must die LOUDLY here — before spawning loops or writing any
// config — because Bun's default SO_REUSEPORT lets a duplicate bind SILENTLY
// split connections with the first copy (census hit this live on :8899,
// 2026-07-15: kernel round-robined the two copies, curl went 000). Guard at
// the top of the file: their second copy died at a bottom-of-file guard only
// after it had already spawned daemons, leaving orphans.
try {
  const r = await fetch(`http://127.0.0.1:${PORT}/api/pins`, { signal: AbortSignal.timeout(900) });
  if (r.ok) {
    console.error(`FATAL: something already serves :${PORT} — refusing to double-bind`);
    process.exit(1);
  }
} catch {} // nothing answered — the port is ours to take

const parseMode = (m: unknown): LayoutMode =>
  LAYOUT_MODES.includes(m as LayoutMode) ? (m as LayoutMode) : "spiral";

// Sample yabai on a loop; every read below serves this cached snapshot (0 forks).
await startEngine(1500);

// Re-detect monitor names on every boot. CGDirectDisplayIDs RESHUFFLE across
// reboots (proven 2026-07-10: the cached displays.json had U2719DC↔S2725QS
// swapped, so displayName pins were bound to the wrong physical panel — caught
// by display-census cross-checking CGDisplayBounds). pm2 restarts us on boot,
// so refreshing here means the id→name map can never go stale across a reboot.
if (!SHADOW) {
  try { await refreshDisplayConfig(); } catch (e) { console.error(`display-name refresh failed (using cached): ${e}`); }
}
const currentSnap = async () => getSnapshot() ?? (await forceRefresh());

// Pin tracker: every 10s, snap pinned oracles back to their home space if they
// drifted (pins.json — e.g. keep the nh fleet on the space labeled "nh").
// Reads the cached snapshot (0 extra forks); writes bracket like every mutation.
if (!SHADOW) setInterval(async () => {
  const pins = loadPins();
  if (!pins.length) return;
  const s = getSnapshot();
  if (!s) return;
  try {
    const names = await displayNames();
    // whenIdleOnly rules see the shared idle clock (local HID min remote-queue);
    // plain rules ignore it. null = can't measure → whenIdleOnly rules sit out.
    // fresh: a 2s-stale cached value could fire a park right as Nat sits back
    // down at the 299s→300s crossing — enforcement always reads live.
    const { moved } = await enforcePins(yabai, s.windows, s.spaces, s.displays, names, pins, effectiveIdleSeconds({ fresh: true }));
    if (moved.length) {
      console.log(`📌 pins: snapped back ${moved.join(", ")}`);
      beginWrite();
      try { await forceRefresh(); } finally { endWrite(); }
      publishDisplayMap();
    }
  } catch (e) {
    console.error(`pins: enforcement failed: ${e}`);
  }
}, 10_000);

// Optional display-map publisher: push the oracle→display map to an external
// consumer after every arrange (event-driven) plus a 60s heartbeat.
// Fire-and-forget — a failed publish never blocks a write.
//
// OPT-IN. Set WA_DISPLAY_MAP_PUBLISH to the script you want run; unset means the
// feature is off and nothing is spawned. It used to be a hardcoded absolute path
// into a private repo, which meant every machine that was not the author's spawned
// a nonexistent path every 60 seconds with stdout and stderr discarded — silent,
// permanent, and invisible to the user.
const PUBLISH_SCRIPT = process.env.WA_DISPLAY_MAP_PUBLISH ?? "";
const publishDisplayMap = () => {
  if (SHADOW || !PUBLISH_SCRIPT) return;
  try { Bun.spawn(["bun", PUBLISH_SCRIPT], { stdout: "ignore", stderr: "ignore" }); } catch {}
};
if (!SHADOW && PUBLISH_SCRIPT) setInterval(publishDisplayMap, 60_000);

// 🩹 Auto-heal (60s): re-apply reboot-lost pin labels + remap the profile when
// space indices renumbered but the groups stayed intact. Never touches real
// drift (that keeps the stale badge for a human). See autoHealProfile.
if (!SHADOW) setInterval(async () => {
  const s = getSnapshot();
  if (!s) return;
  try {
    const healed = await autoHealProfile(yabai, s.windows, s.spaces);
    if (healed.length) {
      console.log(`🩹 auto-heal: ${healed.join("; ")}`);
      beginWrite();
      try { await forceRefresh(); } finally { endWrite(); }
    }
  } catch (e) {
    console.error(`auto-heal failed: ${e}`);
  }
}, 60_000);

// Control-plane A execute side (contract with display-census, 2026-07-10):
// census's server is the only caller and tags every request with
// X-Arrange-Source: local | public-queue. Phase-1 rules for public-queue:
// only apply-layout / arrange-profile / snapshot-profile (gather + pins are
// phase 2), a kill-switch file disables remote entirely, and every POST is
// audit-logged either way. Bearer comes later — token handshake pending.
const CONF_DIR = `${process.env.HOME}/.config/window-arranger-oracle`;
const REMOTE_OFF = `${CONF_DIR}/remote-control.off`; // touch = kill every public-queue command
const AUDIT_PATH = `${CONF_DIR}/audit.jsonl`;
const publicAllowed = (path: string) =>
  path === "/api/arrange-profile" || path === "/api/snapshot-profile" ||
  path === "/api/park" || // bounded: only whenIdleOnly-pinned browsers, to their parking targets
  /^\/api\/space\/\d+\/(apply|focus)$/.test(path);

// 🔒 Writes are loopback-only (security finding, display-census + Nat
// 2026-07-10: *:8900 was reachable from the whole LAN subnet — any host could
// POST write routes). Two layers:
//   1. the server binds to 127.0.0.1 (below) — LAN can't even connect
//   2. this guard 403s non-loopback POSTs anyway, in case the bind ever changes
// Fail CLOSED: if the source IP can't be determined, reject the write.
const LOOPBACK = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"]);
let srv: { requestIP(req: Request): { address: string } | null } | null = null;

// Cursor microtool (scripts/cursor.swift → scripts/bin/cursor). Missing binary
// degrades gracefully: focus still works, the cursor just isn't pinned.
const CURSOR_BIN = join(DIR, "scripts/bin/cursor");
const cursorPos = (): [string, string] | null => {
  try {
    const out = Bun.spawnSync([CURSOR_BIN]).stdout.toString().trim().split(" ");
    return out.length === 2 ? [out[0], out[1]] : null;
  } catch { return null; }
};
const cursorWarp = (pos: [string, string]) => {
  try { Bun.spawnSync([CURSOR_BIN, pos[0], pos[1]]); } catch {}
};

const app = new Elysia()
  .onBeforeHandle(({ request, set }) => {
    if (request.method !== "POST") return;
    const ip = srv?.requestIP(request)?.address;
    if (!ip || !LOOPBACK.has(ip)) {
      set.status = 403;
      return { error: "writes are loopback-only (run this from the machine itself)" };
    }
    // source-tagged allowlist + audit (control-plane A execute side)
    const source = request.headers.get("x-arrange-source") ?? "local";
    const path = new URL(request.url).pathname;
    let blocked: string | null = null;
    if (source === "public-queue") {
      if (existsSync(REMOTE_OFF)) blocked = "remoteControl is off (remove remote-control.off to re-enable)";
      else if (!publicAllowed(path)) blocked = "action not in the phase-1 public allowlist";
      // iPad commands are a human driving with the local HID silent — count
      // them on the idle clock or whenIdleOnly pins would yank mid-command.
      if (!blocked) noteRemoteHumanAction();
    }
    try {
      appendFileSync(AUDIT_PATH, JSON.stringify({ ts: new Date().toISOString(), path, source, allowed: blocked == null, ...(blocked ? { blocked } : {}) }) + "\n");
    } catch { /* audit must never take the write path down */ }
    if (blocked) {
      set.status = 403;
      return { error: blocked };
    }
  })
  .get("/api/state", async () => {
    const s = await currentSnap();
    const names = await displayNames();
    return { displays: s.displays.map((d) => ({ ...d, name: names[String(d.id)] ?? null })), spaces: s.spaces };
  })

  // Fleet topology — which oracle (WezTerm window title) is on which display/space.
  // Read-only, consumed by display-census's push loop to surface space cards on
  // the public site. Served from the cached snapshot — 0 extra yabai forks.
  .get("/api/who", async () => computeWhoReport(await currentSnap()))

  // Re-detect monitor names from macOS and rewrite the config file.
  .post("/api/refresh-displays", async () => {
    const names = await refreshDisplayConfig();
    return { ok: true, config: CONFIG_PATH, names };
  })

  .get("/api/preview/:space", async ({ params, query, set }) => {
    set.headers["Content-Type"] = "image/svg+xml";
    const activeFirst = query.active === "1" || query.active === "true";
    return renderPreviewSVG(await currentSnap(), Number(params.space), parseMode(query.mode), activeFirst);
  })

  // Snapshot of the CURRENT real window positions on a space (display-census style).
  .get("/api/current/:space", async ({ params, set }) => {
    set.headers["Content-Type"] = "image/svg+xml";
    return renderCurrentSVG(await currentSnap(), Number(params.space));
  })

  // Apply the previewed layout by explicitly moving/resizing each window (live),
  // then refresh the snapshot once. beginWrite/endWrite bracket the sequence so a
  // poll tick can't cache a half-applied arrangement.
  .post("/api/space/:space/apply", async ({ params, body }) => {
    const b = body as { mode?: string; activeFirst?: boolean } | undefined;
    const mode = parseMode(b?.mode);
    const activeFirst = b?.activeFirst === true;
    beginWrite();
    try {
      const { moved } = await applyLayout(Number(params.space), mode, activeFirst);
      return { ok: true, space: Number(params.space), mode, activeFirst, moved };
    } finally {
      await forceRefresh();
      endWrite();
      publishDisplayMap();
    }
  })

  // Navigate: switch the display to show a space (no windows move — reversible
  // by just focusing back, so it's in the phase-1 public allowlist). Index is
  // validated by the client (assertIndex) before any argv is built. Known
  // yabai quirk: rapid-fire focus (<1s apart) can no-op with "mission-control
  // is active" — reported as ok:false, never a crash.
  //
  // Cursor behavior (Nat, final call 2026-07-10): DEFAULT = let the mouse
  // follow the warp ("คลิกแล้วเด้งไปทำงานต่อที่จอนั้นเลย") — yabai's non-SA
  // cross-display focus warps it there naturally. body {keepMouse:true} pins
  // it instead: save via scripts/bin/cursor, focus, warp back immediately +
  // at 350ms (the switch animation can re-warp after we return). The census
  // web sends keepMouse from its toggle (default off).
  .post("/api/space/:space/focus", async ({ params, body }) => {
    const space = Number(params.space);
    const keepMouse = (body as { keepMouse?: boolean } | undefined)?.keepMouse === true;
    const pos = keepMouse ? cursorPos() : null;
    try {
      await yabai.focusSpace(space);
      await forceRefresh();
      return { ok: true, space, keepMouse };
    } catch (e) {
      return { ok: false, space, error: String(e) };
    } finally {
      if (pos) {
        cursorWarp(pos);
        setTimeout(() => cursorWarp(pos), 350); // after the switch animation settles
      }
    }
  })

  // Gather every tileable window from all displays onto the main display.
  .post("/api/gather-to-main", async () => {
    beginWrite();
    try {
      return { ok: true, ...(await gatherToMain()) };
    } finally {
      await forceRefresh();
      endWrite();
      publishDisplayMap();
    }
  })

  // 🅿️ Park-now (Nat 2026-07-12): send the whenIdleOnly-pinned browsers to
  // their parking targets immediately — the manual twin of the 10s auto tick,
  // same code path (parkNow → enforcePins with the gate forced open). Bounded
  // action, so it IS in publicAllowed: census puts a button on the web for iPad.
  .post("/api/park", async () => {
    // pinsEnabled in the response: with the toggle off parkNow is an honest
    // no-op, and "nothing to park" must be distinguishable from "pins are off".
    const enabled = pinsEnabled();
    beginWrite();
    try {
      // park + re-tile the source spaces the browsers left (same as the hotkey)
      const { moved, retiled } = await parkAndRetile(yabai);
      return { ok: true, pinsEnabled: enabled, moved, retiled };
    } catch (e) {
      // never a 500 to census's button — same contract as the focus route
      return { ok: false, pinsEnabled: enabled, error: String(e) };
    } finally {
      await forceRefresh();
      endWrite();
      publishDisplayMap();
    }
  })

  // 📌 Pin tracker on/off — the UI switch for the 10s enforcement loop above.
  // Toggling renames pins.json ⇄ pins.json.off (rules kept, never deleted);
  // the loop picks the change up on its next tick.
  .get("/api/pins", () => ({ enabled: pinsEnabled(), rules: pinRuleCount() }))
  .post("/api/pins/toggle", () => ({ ok: true, enabled: setPinsEnabled(!pinsEnabled()), rules: pinRuleCount() }))

  // ⭐ Space-pin (census web, Nat 2026-07-11): pin/unpin everything currently on
  // a space at its space (routing-level, like everything else here). Writes
  // origin-tagged rules into the active pins file; the 10s loop enforces them.
  // LOCAL_ONLY by design — deliberately NOT in publicAllowed (standing
  // enforcement changes don't belong on the public token path).
  .post("/api/space/:space/pin", async ({ params, body, set }) => {
    const space = Number(params.space);
    const pinned = (body as { pinned?: boolean } | undefined)?.pinned === true;
    const s = await currentSnap();
    const sp = s.spaces.find((x) => x.index === space);
    if (!sp) {
      set.status = 400;
      return { ok: false, error: `no space with index ${space}` };
    }
    // Pin by LABEL so it follows the space through a renumber. Reuse an existing
    // label; otherwise auto-assign a synthetic ⭐ one (opaque, never shown to the
    // census UI — /api/who exposes spaces[].pinned, not the label string).
    let label = (sp.label ?? "").trim();
    const windows = s.windows.filter((w) => w.space === space);
    beginWrite();
    try {
      if (pinned) {
        if (!label) { label = `${SYNTH_LABEL_PREFIX}${space}`; await yabai.labelSpace(space, label); }
        const { count } = setSpacePin(label, windows, true);
        return { ok: true, space, pinned: true, count, pinsEnabled: pinsEnabled() };
      } else {
        // Unpin the space at THIS index: remove its rules; drop a synthetic label.
        const { count } = setSpacePin(label, windows, false);
        if (isSyntheticLabel(label)) await yabai.labelSpace(space, "");
        return { ok: true, space, pinned: false, count, pinsEnabled: pinsEnabled() };
      }
    } finally {
      await forceRefresh();
      endWrite();
    }
  })

  // 📸 Snapshot — write a profile FROM the current positions (each oracle → its
  // space). Backs up any existing profile first. Moves no windows.
  .post("/api/snapshot-profile", async () => {
    // The saved rules become tomorrow's targets — read at write-grade
    // freshness (same standard as apply/gather), not the ≤1.5s poll cache.
    const s = (await forceRefresh()) ?? (await currentSnap());
    const rules = snapshotProfile(s.windows);
    const backup = saveProfile(rules);
    return { ok: true, saved: rules.length, backup };
  })

  // ♻️ Restore — move every oracle back to the space its saved rule names.
  .post("/api/arrange-profile", async () => {
    const rules = loadProfile();
    if (!rules.length) return { ok: false, error: "no profile saved — snapshot one first" };
    beginWrite();
    try {
      const s = await currentSnap();
      const { moved, matched } = await arrangeByProfile(yabai, s.windows, rules);
      return { ok: true, rules: rules.length, matched, moved };
    } finally {
      await forceRefresh();
      endWrite();
      publishDisplayMap();
    }
  })

  .post("/api/space/:space/layout", async ({ params, body }) => {
    const { layout } = body as { layout: "float" };
    if (layout !== "float") {
      return new Response(JSON.stringify({ error: "only float is applied via yabai layout; use /apply for tiling" }), { status: 400 });
    }
    beginWrite();
    try {
      // Validated by the client (assertIndex) before any argv is built — the
      // structural fix for the old unvalidated `--space ${params.space}` bug.
      await yabai.setLayout(Number(params.space), layout);
      return { ok: true, space: Number(params.space), layout };
    } finally {
      await forceRefresh();
      endWrite();
    }
  })

  // Landing page: serves the bundled UI (public/index.html) by default.
  //
  // This used to be a "signpost" that probed a companion app on localhost:8899
  // and, on failure, ran location.replace() to a specific external domain. That
  // meant anyone who was not the original author started the server, opened
  // :8900, and was bounced off their own machine within 1.2s to a dashboard
  // about someone else's fleet — while the actual UI sat unadvertised at
  // /legacy. The hop is now OPT-IN.
  //
  //   WA_CENSUS_URL   preferred companion UI; unset = just serve the UI here.
  .get("/", () => {
    const census = process.env.WA_CENSUS_URL ?? "";
    if (!census) {
      return new Response(Bun.file(join(DIR, "public/index.html")), {
        headers: { "Content-Type": "text/html", "Cache-Control": "no-store" },
      });
    }
    const esc = census.replace(/"/g, "&quot;");
    return new Response(`<!doctype html><meta charset="utf-8">
<title>window-arranger</title>
<body style="background:#0a0e14;color:#cbd5e1;font-family:ui-monospace,monospace;display:grid;place-items:center;min-height:95vh">
<div style="max-width:32rem;text-align:center;line-height:1.9">
  <div style="font-size:2.2rem">\u{1F3AD}</div>
  <p>Handing off to the configured companion UI\u2026</p>
  <p><a style="color:#8fd3ff" href="${esc}">${esc}</a></p>
  <p style="color:#64748b;font-size:.85rem">This server's own UI is at <a style="color:#94a3b8" href="/legacy">/legacy</a> \u00b7 API is unaffected.</p>
</div>
<script>location.replace(${JSON.stringify(census)});</script></body>`,
      { headers: { "Content-Type": "text/html", "Cache-Control": "no-store" } });
  })

  // break-glass: the pre-D single-page UI, untouched (CDN-dependent — fine for
  // an on-machine emergency surface; it talks straight to this server).
  .get("/legacy", () => new Response(Bun.file(join(DIR, "public/index.html")), {
    headers: { "Content-Type": "text/html", "Cache-Control": "no-store" },
  }))

  // loopback bind: local-only means the OS enforces it, not just our routes
  // reusePort:false → a race the probe above missed still dies with a loud
  // EADDRINUSE instead of a silent SO_REUSEPORT connection split.
  .listen({ port: PORT, hostname: "127.0.0.1", reusePort: false });

srv = app.server;
console.log(`🪟 window-arranger (local-only, 127.0.0.1 bind) on http://localhost:${app.server!.port}`);
