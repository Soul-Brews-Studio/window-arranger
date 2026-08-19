// window-arranger — organize the desktop, terminal-first.
//   • non-terminal apps (Discord, Comet, Finder, ...) → the main Space (1),
//     since they get pinned elsewhere anyway (Nat 2026-07-23).
//   • terminal windows (WezTerm) → spread so no Space holds more than N,
//     each kept on its own display, overflow into that display's empty Spaces.
//   • then tile each terminal Space into equal side-by-side COLUMNS via the
//     repo's own :8900 engine (handles menu-bar inset + gaps; preview==applied).
// Pure yabai reads/moves + one local HTTP call per space for the tiling.

const YABAI = "/opt/homebrew/bin/yabai";
const TMUX = "/opt/homebrew/bin/tmux";
const WEZTERM = "/opt/homebrew/bin/wezterm";
// A WezTerm pane whose title is a bare shell = an idle terminal with nothing
// running (an oracle pane's title is its tmux session name, e.g. "maw-rs"). These
// are leftovers worth closing. Title, not process — reliable + matches what you see.
const BARE_SHELLS = new Set(["zsh", "-zsh", "bash", "-bash", "fish", "sh", "login"]);
const SOCKET = `/private/tmp/tmux-${process.getuid?.() ?? 501}/default`;
const API = "http://127.0.0.1:8900";
const MAIN_SPACE = 1;                          // display 1's primary — the app dump
const RESERVED_PATH = `${process.env.HOME}/.config/window-arranger-oracle/arrange-reserved.json`;

// Reserved spaces are hands-off: the arranger never spreads terminals INTO them,
// never evicts terminals FROM them, and never tiles them. They belong to a named
// owner (e.g. space 2 → nh, space 7 → phd-project). Stored space-index → label.
export async function readReserved(): Promise<Map<number, string>> {
  try {
    const f = Bun.file(RESERVED_PATH);
    if (!(await f.exists())) return new Map();
    const obj = JSON.parse(await f.text());
    return new Map(Object.entries(obj).map(([k, v]) => [Number(k), String(v)]));
  } catch { return new Map(); }
}
export async function writeReserved(m: Map<number, string>): Promise<void> {
  const obj: Record<string, string> = {};
  for (const [k, v] of [...m].sort((a, b) => a[0] - b[0])) obj[String(k)] = v;
  await Bun.write(RESERVED_PATH, JSON.stringify(obj, null, 2) + "\n");
}
export function renderReserved(m: Map<number, string>): string {
  if (m.size === 0) return "no reserved spaces.";
  return "reserved spaces (hands-off):\n" + [...m].sort((a, b) => a[0] - b[0]).map(([s, l]) => `  space ${s} → ${l || "(reserved)"}`).join("\n");
}
const IGNORE_APPS = new Set(["Wispr Flow"]);   // self-moving status pill, not ours
const TERMINALS = new Set(["WezTerm"]);        // the only apps we tile/spread

async function yabai(args: string[]): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = Bun.spawn([YABAI, ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { stdout, stderr, exitCode };
}

interface Frame { x: number; y: number; w: number; h: number; }
interface Win {
  id: number; app: string; title: string; space: number; display: number; frame: Frame;
  "is-minimized"?: boolean; "is-hidden"?: boolean; "is-sticky"?: boolean;
}
interface Space { index: number; display: number; }

function usable(w: Win): boolean {
  if (w["is-minimized"] || w["is-hidden"] || w["is-sticky"]) return false;
  if (IGNORE_APPS.has(w.app)) return false;
  const f = w.frame ?? { x: 0, y: 0, w: 0, h: 0 };
  return f.w >= 1 && f.h >= 1;
}
const isTerminal = (w: Win) => usable(w) && TERMINALS.has(w.app);
const isOther = (w: Win) => usable(w) && !TERMINALS.has(w.app);

export interface Snapshot {
  termsBySpace: Map<number, Win[]>;
  others: Win[];
  spacesByDisplay: Map<number, number[]>;
  reserved: Map<number, string>;
}

export async function snapshot(): Promise<Snapshot> {
  const wq = await yabai(["-m", "query", "--windows"]);
  const sq = await yabai(["-m", "query", "--spaces"]);
  if (wq.exitCode !== 0) throw new Error(`yabai query --windows failed: ${wq.stderr.trim()}`);
  if (sq.exitCode !== 0) throw new Error(`yabai query --spaces failed: ${sq.stderr.trim()}`);
  const wins: Win[] = JSON.parse(wq.stdout);
  const spaces: Space[] = JSON.parse(sq.stdout);

  const termsBySpace = new Map<number, Win[]>();
  const others: Win[] = [];
  for (const w of wins) {
    if (isTerminal(w)) {
      if (!termsBySpace.has(w.space)) termsBySpace.set(w.space, []);
      termsBySpace.get(w.space)!.push(w);
    } else if (isOther(w)) {
      others.push(w);
    }
  }
  const spacesByDisplay = new Map<number, number[]>();
  for (const s of spaces.sort((a, b) => a.index - b.index)) {
    if (!spacesByDisplay.has(s.display)) spacesByDisplay.set(s.display, []);
    spacesByDisplay.get(s.display)!.push(s.index);
  }
  return { termsBySpace, others, spacesByDisplay, reserved: await readReserved() };
}

export interface Move { id: number; app: string; from: number; to: number; kind: "park" | "term"; }
export interface Plan { moves: Move[]; unplaced: Win[]; max: number; }

export function computePlan(snap: Snapshot, max: number): Plan {
  const moves: Move[] = [];
  const unplaced: Win[] = [];

  // 1) park every non-terminal app onto the main space
  for (const o of snap.others) {
    if (o.space !== MAIN_SPACE) moves.push({ id: o.id, app: o.app, from: o.space, to: MAIN_SPACE, kind: "park" });
  }

  // 2) spread terminals per display, ≤max/space, evicting all terminals off the main space
  for (const [, spaceIdxs] of snap.spacesByDisplay) {
    const count = new Map<number, number>();
    const excess: Win[] = [];
    for (const s of spaceIdxs) {
      if (snap.reserved.has(s)) { count.set(s, Infinity); continue; }             // hands-off: never source or target
      const terms = snap.termsBySpace.get(s) ?? [];
      if (s === MAIN_SPACE) { excess.push(...terms); count.set(s, 0); }          // main = apps only
      else if (terms.length > max) { excess.push(...terms.slice(max)); count.set(s, max); }
      else count.set(s, terms.length);
    }
    if (excess.length === 0) continue;
    const targets = spaceIdxs.filter((s) => s !== MAIN_SPACE && !snap.reserved.has(s) && (count.get(s) ?? 0) === 0);
    let ti = 0;
    for (const w of excess) {
      while (ti < targets.length && (count.get(targets[ti]) ?? 0) >= max) ti++;
      if (ti >= targets.length) { unplaced.push(w); continue; }
      const to = targets[ti];
      moves.push({ id: w.id, app: w.app, from: w.space, to, kind: "term" });
      count.set(to, (count.get(to) ?? 0) + 1);
    }
  }
  return { moves, unplaced, max };
}

export async function applyPlan(plan: Plan): Promise<{ ok: number; fail: number; errors: string[] }> {
  let ok = 0, fail = 0; const errors: string[] = [];
  for (const m of plan.moves) {
    const r = await yabai(["-m", "window", String(m.id), "--space", String(m.to)]);
    if (r.exitCode === 0) ok++;
    else { fail++; errors.push(`${m.app}#${m.id}→sp${m.to}: ${r.stderr.trim()}`); }
  }
  return { ok, fail, errors };
}

// Tile each Space that holds terminals into equal side-by-side columns, using the
// repo's :8900 engine (single source of layout truth; menu-bar inset + gaps).
export async function tileTerminalSpaces(): Promise<{ tiled: number[]; failed: string[] }> {
  const snap = await snapshot();
  const tiled: number[] = []; const failed: string[] = [];
  const spaces = [...snap.termsBySpace.keys()]
    .filter((s) => !snap.reserved.has(s) && (snap.termsBySpace.get(s) ?? []).length >= 1)  // never tile reserved
    .sort((a, b) => a - b);
  for (const s of spaces) {
    try {
      const res = await fetch(`${API}/api/space/${s}/apply`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ mode: "columns", activeFirst: false }),
        signal: AbortSignal.timeout(5000),
      });
      if (res.ok) tiled.push(s); else failed.push(`sp${s}: HTTP ${res.status}`);
    } catch (e: any) { failed.push(`sp${s}: ${e?.message ?? e}`); }
  }
  return { tiled, failed };
}

// ---- dedup: one WezTerm window per tmux session ----
// A duplicate = a session with >1 attached client (extra mirror windows). We keep
// one client and detach the rest; detaching makes each mirror's `tmux attach`
// exit, so WezTerm closes that window while the SESSION survives (re-openable via
// ⌃⌥⌘Space). Ground truth from tmux, not window titles — so distinct "zsh" shells
// on different sessions are never conflated.
export interface Detach { tty: string; session: string; }

export async function dedupPlan(): Promise<{ detach: Detach[]; sessions: Map<string, number> }> {
  const proc = Bun.spawn([TMUX, "-S", SOCKET, "list-clients", "-F", "#{client_tty}\t#{session_name}"],
    { stdout: "pipe", stderr: "pipe" });
  const [out, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (code !== 0) return { detach: [], sessions: new Map() };
  const bySession = new Map<string, string[]>();       // session -> [client ttys], in list order
  for (const line of out.split("\n")) {
    const [tty, session] = line.split("\t");
    if (!tty || !session) continue;
    if (!bySession.has(session)) bySession.set(session, []);
    bySession.get(session)!.push(tty);
  }
  const detach: Detach[] = [];
  const sessions = new Map<string, number>();
  for (const [session, ttys] of bySession) {
    sessions.set(session, ttys.length);
    for (const tty of ttys.slice(1)) detach.push({ tty, session }); // keep ttys[0]
  }
  return { detach, sessions };
}

export async function applyDedup(detach: Detach[]): Promise<{ ok: number; fail: number }> {
  let ok = 0, fail = 0;
  for (const d of detach) {
    const proc = Bun.spawn([TMUX, "-S", SOCKET, "detach-client", "-t", d.tty], { stdout: "pipe", stderr: "pipe" });
    (await proc.exited) === 0 ? ok++ : fail++;
  }
  return { ok, fail };
}

export function renderDedup(detach: Detach[], sessions: Map<string, number>): string {
  const dups = [...sessions.entries()].filter(([, n]) => n > 1).sort((a, b) => b[1] - a[1]);
  if (detach.length === 0) return "no duplicate mirror windows — one client per tmux session ✅";
  const lines = [`dedup: ${detach.length} duplicate mirror window(s) to close (keep 1 per session):`];
  for (const [s, n] of dups) lines.push(`  ${s}: ${n} windows → keep 1, close ${n - 1}`);
  return lines.join("\n");
}

// ---- close-empty: close idle bare-shell WezTerm windows ----
export interface EmptyPane { paneId: number; windowId: number; title: string; cwd: string; }

export async function emptyPanes(): Promise<EmptyPane[]> {
  const proc = Bun.spawn([WEZTERM, "cli", "list", "--format", "json"], { stdout: "pipe", stderr: "pipe" });
  const [out, code] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (code !== 0) return [];
  let panes: any[]; try { panes = JSON.parse(out); } catch { return []; }
  return panes
    .filter((p) => BARE_SHELLS.has(String(p.title ?? "").trim().toLowerCase()))
    .map((p) => ({ paneId: p.pane_id, windowId: p.window_id, title: String(p.title ?? ""), cwd: String(p.cwd ?? "") }));
}

export async function closeEmpty(panes: EmptyPane[]): Promise<{ ok: number; fail: number }> {
  let ok = 0, fail = 0;
  for (const p of panes) {
    const proc = Bun.spawn([WEZTERM, "cli", "kill-pane", "--pane-id", String(p.paneId)], { stdout: "pipe", stderr: "pipe" });
    (await proc.exited) === 0 ? ok++ : fail++;
  }
  return { ok, fail };
}

export function renderEmpty(panes: EmptyPane[]): string {
  if (panes.length === 0) return "no empty terminals (bare shells) open ✅";
  const lines = [`${panes.length} empty terminal(s) to close (bare shell, no oracle):`];
  for (const p of panes) lines.push(`  pane ${p.paneId} — "${p.title}" @ …/${p.cwd.replace(/\/$/, "").split("/").pop()}`);
  return lines.join("\n");
}

export function renderStatus(snap: Snapshot, max: number): string {
  const lines: string[] = ["terminals (WezTerm) per display/space  +  non-terminal apps:"];
  let over = 0;
  for (const [d, idxs] of [...snap.spacesByDisplay].sort((a, b) => a[0] - b[0])) {
    for (const s of idxs) {
      const terms = snap.termsBySpace.get(s) ?? [];
      if (terms.length === 0) continue;
      const flag = terms.length > max ? ` ⚠️ >${max}` : "";
      if (terms.length > max) over++;
      lines.push(`  display ${d} · space ${String(s).padStart(2)}: ${terms.length} term${flag}`);
    }
  }
  const otherApps = [...new Set(snap.others.map((w) => w.app))];
  lines.push(`  non-terminal apps (→ space ${MAIN_SPACE}): ${otherApps.length ? otherApps.join(", ") : "none"}`);
  if (snap.reserved.size) lines.push(`  reserved (hands-off): ${[...snap.reserved].sort((a, b) => a[0] - b[0]).map(([s, l]) => `sp${s}=${l || "?"}`).join(", ")}`);
  lines.push(over === 0 ? `all terminal spaces ≤${max} ✅` : `${over} terminal space(s) over ${max}`);
  return lines.join("\n");
}

export function renderPlan(plan: Plan): string {
  const park = plan.moves.filter((m) => m.kind === "park");
  const term = plan.moves.filter((m) => m.kind === "term");
  if (plan.moves.length === 0) return `nothing to move — apps already on space ${MAIN_SPACE}, terminals already ≤${plan.max}/space ✅`;
  const lines: string[] = [`plan: ${plan.moves.length} move(s):`];
  if (park.length) {
    lines.push(`  → park ${park.length} app window(s) to space ${MAIN_SPACE}: ${park.map((m) => `${m.app}#${m.id}(sp${m.from})`).join(", ")}`);
  }
  for (const m of term) lines.push(`  → terminal ${m.app}#${m.id}: space ${m.from} → space ${m.to}`);
  if (plan.unplaced.length) lines.push(`  ⚠️ ${plan.unplaced.length} terminal(s) unplaced (no empty space left on display): ${plan.unplaced.map((w) => `${w.app}#${w.id}`).join(", ")}`);
  return lines.join("\n");
}
