// yabai — a typed class wrapping the yabai CLI, mirroring how maw-js/maw-rs wrap
// tmux: every invocation (read or write) funnels through one exec choke point,
// args are built as validated string[] arrays (never hand-interpolated strings),
// and a Runner seam lets tests inject a fake so the engine + layouts are testable
// with zero real yabai. yabai emits native JSON on `-m query`, so — unlike tmux —
// there is no format-string parsing layer; reads are just JSON.parse.
import { existsSync } from "node:fs";
import type { Rect, Config, YabaiWindow, YabaiDisplay, YabaiSpace } from "./bsp";

export interface YabaiRunResult { stdout: string; stderr: string; exitCode: number; }

// The entire test seam — one method. Swap it for a fake in unit tests.
export interface YabaiRunner {
  run(args: string[]): Promise<YabaiRunResult>;
}

export type YabaiErrorKind = "missing-binary" | "no-op" | "command-failed" | "invalid-args";

export class YabaiError extends Error {
  constructor(
    public readonly kind: YabaiErrorKind,
    message: string,
    public readonly args: string[],
    public readonly stderr?: string,
    public readonly exitCode?: number,
  ) {
    super(message);
    this.name = "YabaiError";
  }
}

// Fail BEFORE a string is built — mirrors maw-rs's validate_tmux_option_values.
// This is what makes the old `--space ${params.space}` class of bug impossible.
function assertIndex(n: number, label: string): number {
  if (!Number.isInteger(n) || n < 0) {
    throw new YabaiError("invalid-args", `invalid ${label}: ${JSON.stringify(n)}`, []);
  }
  return n;
}

function classify(args: string[], r: YabaiRunResult): YabaiError {
  // yabai returns exit 1 + a human message for benign "already X" / "not found"
  // states — harmless for idempotent commands (focus already-focused space, etc.)
  // "could not locate" is yabai's actual wording for a vanished window id
  // (probed live 2026-07-12) — the stale-snapshot idempotency case: a window
  // that closed between snapshot and move is a no-op, not a failure.
  if (/already|could not (find|locate)|does not exist/i.test(r.stderr)) {
    return new YabaiError("no-op", r.stderr.trim(), args, r.stderr, r.exitCode);
  }
  return new YabaiError("command-failed", r.stderr.trim() || `yabai exited ${r.exitCode}`, args, r.stderr, r.exitCode);
}

// The only place that touches the process API.
export class BunYabaiRunner implements YabaiRunner {
  private static readonly CANDIDATES = ["/opt/homebrew/bin/yabai", "/usr/local/bin/yabai"];
  async run(args: string[]): Promise<YabaiRunResult> {
    // YABAI_BIN lets the conformance suite point every implementation at the
    // same fake binary; unset in normal operation.
    const bin = process.env.YABAI_BIN || BunYabaiRunner.CANDIDATES.find((p) => existsSync(p));
    if (!bin) throw new Error("yabai binary not found on PATH candidates");
    const proc = Bun.spawn([bin, ...args], { stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
      proc.exited,
    ]);
    return { stdout, stderr, exitCode };
  }
}

// A fake for tests: stub responses keyed by the joined args, and record calls.
export class FakeYabaiRunner implements YabaiRunner {
  calls: string[][] = [];
  constructor(private responses: Record<string, YabaiRunResult> = {}) {}
  async run(args: string[]): Promise<YabaiRunResult> {
    this.calls.push(args);
    return this.responses[args.join(" ")] ?? { stdout: "", stderr: "not stubbed", exitCode: 1 };
  }
}

const CONFIG_KEYS = ["top_padding", "bottom_padding", "left_padding", "right_padding", "window_gap"] as const;

export class YabaiClient {
  constructor(private readonly runner: YabaiRunner = new BunYabaiRunner()) {}

  // ---- the two choke points ----
  private async run(args: string[]): Promise<YabaiRunResult> {
    let result: YabaiRunResult;
    try {
      result = await this.runner.run(args);
    } catch (e) {
      throw new YabaiError("missing-binary", `yabai not found (or failed to spawn): ${e}`, args);
    }
    if (result.exitCode !== 0) throw classify(args, result);
    return result;
  }

  async query<T>(args: string[]): Promise<T> {
    const { stdout } = await this.run(["-m", "query", ...args]);
    return (stdout.trim() ? JSON.parse(stdout) : undefined) as T;
  }

  private async mutate(args: string[], opts: { tolerateNoOp?: boolean } = {}): Promise<void> {
    try {
      await this.run(args);
    } catch (e) {
      if (opts.tolerateNoOp && e instanceof YabaiError && e.kind === "no-op") return;
      throw e;
    }
  }

  // ---- typed reads ----
  displays(): Promise<YabaiDisplay[]> { return this.query(["--displays"]); }
  display(index: number): Promise<YabaiDisplay> { return this.query(["--displays", "--display", String(assertIndex(index, "display"))]); }
  spaces(): Promise<YabaiSpace[]> { return this.query(["--spaces"]); }
  space(index: number): Promise<YabaiSpace> { return this.query(["--spaces", "--space", String(assertIndex(index, "space"))]); }

  windows(opts?: { space?: number; display?: number }): Promise<YabaiWindow[]> {
    const args = ["--windows"];
    if (opts?.space != null) args.push("--space", String(assertIndex(opts.space, "space")));
    if (opts?.display != null) args.push("--display", String(assertIndex(opts.display, "display")));
    return this.query(args);
  }

  async configNumber(key: string, opts?: { space?: number }): Promise<number> {
    const args = opts?.space != null
      ? ["-m", "config", "--space", String(assertIndex(opts.space, "space")), key]
      : ["-m", "config", key];
    const { stdout } = await this.run(args);
    return Number(stdout.trim());
  }

  private async readConfig(space?: number): Promise<Config> {
    const [top, bottom, left, right, gap] = await Promise.all(
      CONFIG_KEYS.map((k) => this.configNumber(k, space != null ? { space } : undefined)),
    );
    return { top, bottom, left, right, gap };
  }
  globalConfig(): Promise<Config> { return this.readConfig(); }
  spaceConfig(index: number): Promise<Config> { return this.readConfig(index); }

  // ---- typed writes (validated before the argv is ever assembled) ----
  async setLayout(spaceIndex: number, layout: "bsp" | "float" | "stack"): Promise<void> {
    await this.mutate(["-m", "space", String(assertIndex(spaceIndex, "space")), "--layout", layout], { tolerateNoOp: true });
  }
  async focusSpace(index: number): Promise<void> {
    await this.mutate(["-m", "space", "--focus", String(assertIndex(index, "space"))], { tolerateNoOp: true });
  }
  async moveWindow(id: number, abs: { x: number; y: number }): Promise<void> {
    await this.mutate(["-m", "window", String(assertIndex(id, "window id")), "--move", `abs:${Math.round(abs.x)}:${Math.round(abs.y)}`], { tolerateNoOp: true });
  }
  async resizeWindow(id: number, abs: { w: number; h: number }): Promise<void> {
    await this.mutate(["-m", "window", String(assertIndex(id, "window id")), "--resize", `abs:${Math.round(abs.w)}:${Math.round(abs.h)}`], { tolerateNoOp: true });
  }
  async moveToDisplay(id: number, display: number, grid?: string): Promise<void> {
    await this.mutate(["-m", "window", String(assertIndex(id, "window id")), "--display", String(assertIndex(display, "display"))], { tolerateNoOp: true });
    if (grid) await this.mutate(["-m", "window", String(id), "--grid", grid], { tolerateNoOp: true });
  }
  // Move a window to a specific space — index (validated) or a label. yabai's
  // `--space` accepts both. Verified to work in non-SA mode (no scripting addition).
  async moveToSpace(id: number, space: number | string): Promise<void> {
    const selector = typeof space === "number" ? String(assertIndex(space, "space")) : space;
    await this.mutate(["-m", "window", String(assertIndex(id, "window id")), "--space", selector], { tolerateNoOp: true });
  }
  // Attach a stable label to a space (positional selector) so profiles can target
  // `--space <label>` and survive index renumbering.
  async labelSpace(index: number, label: string): Promise<void> {
    await this.mutate(["-m", "space", String(assertIndex(index, "space")), "--label", label], { tolerateNoOp: true });
  }
}

// Shared default instance for the running app; tests construct their own with a
// FakeYabaiRunner. Marked as the type too so callers can accept an injectable.
export const yabai = new YabaiClient();
export type { Rect };
