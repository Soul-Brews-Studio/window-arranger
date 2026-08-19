// idle — ONE fleet-wide idle clock (contract with display-census, 2026-07-12):
// seconds since the last human input, min over mouse/key/scroll, read from
// scripts/bin/idle (CGEventSource — the same formula and 300s threshold as
// census's active-watch, so the wall's "(idle)" badge and our whenIdleOnly
// pins arm at the same second). We compute it OURSELVES instead of asking
// census's API: the write engine must not wobble with the read body's health.
//
// null = binary missing/failed → callers must treat as "cannot prove idle"
// and move NOTHING (fail safe, never guess).
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const IDLE_BIN = join(dirname(fileURLToPath(import.meta.url)), "../scripts/bin/idle");

export const IDLE_THRESHOLD_SEC = 300; // = census active-watch IDLE_SEC
// Watching a video = a VISIBLE browser with zero input (focus not required —
// Nat watches the second monitor with hands off everything): any window on a
// currently-visible space needs 3× the idle before we're allowed to move it.
export const IDLE_VISIBLE_MULTIPLIER = 3;

// The binary is gitignored (scripts/bin/) — on a fresh checkout every
// whenIdleOnly rule silently sits out, so the failure must be LOUD, once.
let warnedNoBinary = false;
const warnNoBinary = () => {
  if (warnedNoBinary) return;
  warnedNoBinary = true;
  console.error(`⚠️ idle binary unavailable (${IDLE_BIN}) — ALL whenIdleOnly pins are disabled. Build it: swiftc -O scripts/idle.swift -o scripts/bin/idle`);
};

// census polls /api/who at 1 Hz — cache so we don't fork the binary per request.
// fresh:true bypasses the cache for ENFORCEMENT decisions: a 2s-stale value can
// say "idle ≥300s" right after Nat touches the mouse at 299s, and yanking a
// window the second he sits back down is this repo's cardinal sin.
let cache: { ts: number; val: number | null } | null = null;
export function idleSeconds(opts?: { fresh?: boolean }): number | null {
  const now = Date.now();
  if (!opts?.fresh && cache && now - cache.ts < 2_000) return cache.val;
  let val: number | null = null;
  try {
    const p = Bun.spawnSync([IDLE_BIN]);
    const n = Number(p.stdout.toString().trim());
    val = p.exitCode === 0 && Number.isFinite(n) ? n : null;
  } catch { /* missing binary → null */ }
  if (val == null) warnNoBinary();
  cache = { ts: now, val };
  return val;
}

// Nat driving from the iPad goes through census's control queue → our HTTP
// writes, with the local HID totally silent — CGEventSource alone would call
// that "idle" and yank the browser mid-command. Every executed public-queue
// write bumps this, and the effective idle is the min of both clocks.
let lastRemoteHumanMs = 0;
export function noteRemoteHumanAction(): void { lastRemoteHumanMs = Date.now(); }

export function effectiveIdleSeconds(opts?: { fresh?: boolean }): number | null {
  const local = idleSeconds(opts);
  if (local == null) return null;
  if (!lastRemoteHumanMs) return local;
  return Math.min(local, (Date.now() - lastRemoteHumanMs) / 1_000);
}
