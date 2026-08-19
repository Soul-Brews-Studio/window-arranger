// engine — the state layer. Samples yabai ONCE per tick into a single cached
// Snapshot so reads cost zero yabai forks (they read the object), instead of the
// 2–23 forks per request the inline-query design cost. Holds BOTH halves in one
// place (per Nat's design): the poll LOOP (getSnapshot) and the PER-REQUEST live
// path (forceRefresh, used right after a write for exact settled state).
import { yabai, type YabaiClient } from "./yabai";
import type { Snapshot, Config } from "./bsp";

let snapshot: Snapshot | null = null;
let timer: ReturnType<typeof setInterval> | null = null;
// Writes (apply/gather/layout) fire many sequential yabai mutations. While one
// is in flight, poll ticks must NOT cache a half-applied state — this counter
// gates them; the write itself does one forceRefresh() at the end.
let writesInFlight = 0;

// The client is injectable so the engine can be unit-tested with a FakeYabaiRunner.
let client: YabaiClient = yabai;
export function setEngineClient(c: YabaiClient): void { client = c; }

// Padding/gap change rarely (only when the user reconfigures yabai), so we cache
// them and only re-read on a full fetchLive (startup + after writes), keeping the
// idle poll tick to 3 forks instead of 8.
let lastConfig: Config | null = null;

// The 3 volatile queries — what the poll loop samples every tick.
async function sampleState(config: Config): Promise<Snapshot> {
  const [displays, spaces, windows] = await Promise.all([
    client.displays(),
    client.spaces(),
    client.windows(),
  ]);
  return { ts: Date.now(), displays, spaces, windows, config };
}

// Full sample incl. a fresh config read — used at startup and after writes.
export async function fetchLive(): Promise<Snapshot> {
  lastConfig = await client.globalConfig();
  return sampleState(lastConfig);
}

// Zero-fork read of the cached state.
export function getSnapshot(): Snapshot | null {
  return snapshot;
}

// Per-request live refresh — used after a write to reflect the settled state
// immediately (no waiting for the next tick).
export async function forceRefresh(): Promise<Snapshot> {
  snapshot = await fetchLive();
  return snapshot;
}

// Bracket a write so poll ticks skip caching until it resolves.
export function beginWrite(): void { writesInFlight++; }
export function endWrite(): void { writesInFlight = Math.max(0, writesInFlight - 1); }

// Start the poll loop. Awaits one fetch so getSnapshot() is ready before serving.
export async function startEngine(intervalMs = 1500): Promise<void> {
  await forceRefresh();
  if (timer) return;
  timer = setInterval(async () => {
    if (writesInFlight > 0) return; // apply-race guard
    // Reuse cached config (3 forks/tick, not 8); fetchLive refreshes it on writes.
    try { snapshot = await sampleState(lastConfig ?? await client.globalConfig()); } catch { /* keep last good snapshot */ }
  }, intervalMs);
}

export function stopEngine(): void {
  if (timer) { clearInterval(timer); timer = null; }
}
