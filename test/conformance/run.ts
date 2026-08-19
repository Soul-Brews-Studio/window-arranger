#!/usr/bin/env bun
// Conformance runner — boots each server implementation against the SAME fake
// yabai + sandboxed config, then asserts the full HTTP surface and the yabai
// write-argv stream are identical across implementations.
//
//   bun test/conformance/run.ts                 # ts + swift
//   bun test/conformance/run.ts --targets ts,swift,rust
//
// The first target is the reference; every other target diffs against it.
// Exit 0 = conformant, 1 = divergence (each one printed), 2 = harness failure.
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");
const FAKE = join(HERE, "fake-yabai");

interface Target {
  name: string;
  port: number;
  cmd: (port: number) => string[];
  env: (sbxHome: string, argvLog: string, port: number) => Record<string, string>;
}

const TARGETS: Record<string, Target> = {
  ts: {
    name: "ts",
    port: 18900,
    cmd: () => ["bun", join(REPO, "server.ts")],
    env: (home, log, port) => ({
      HOME: home, WA_SHADOW: "1", PORT: String(port),
      YABAI_BIN: FAKE, FAKE_YABAI_LOG: log,
    }),
  },
  swift: {
    name: "swift",
    port: 18901,
    cmd: (port) => [join(REPO, "menubar/.build/debug/WindowArrangerServer"), "--shadow", "--port", String(port)],
    env: (home, log, _port) => ({
      WA_HOME: home, YABAI_BIN: FAKE, FAKE_YABAI_LOG: log, WA_ROOT: REPO,
    }),
  },
  rust: {
    name: "rust",
    port: 18902,
    cmd: (port) => [join(REPO, "server-rs/target/debug/window-arranger-server"), "--shadow", "--port", String(port)],
    env: (home, log, _port) => ({
      WA_HOME: home, YABAI_BIN: FAKE, FAKE_YABAI_LOG: log, WA_ROOT: REPO,
    }),
  },
};

// ---------------------------------------------------------------- sandbox ---
function makeSandbox(): { home: string; argvLog: string; root: string } {
  const root = mkdtempSync(join(tmpdir(), "wa-conformance-"));
  const home = join(root, "home");
  const conf = join(home, ".config", "window-arranger-oracle");
  mkdirSync(conf, { recursive: true });

  writeFileSync(join(conf, "displays.json"), JSON.stringify({ "100": "TEST DELL 27", "200": "TEST PORTRAIT 16" }, null, 2) + "\n");
  writeFileSync(join(conf, "oracle-profile.json"), JSON.stringify([
    { match: "alpha", space: 1 },
    { match: "beta", space: 2 },          // drifted: window sits on 1
    { match: "gamma-oracle", space: 3 },  // drifted: window sits on 2
    { match: "nh", space: 3 },
  ], null, 2) + "\n");
  writeFileSync(join(conf, "pins.json"), JSON.stringify([
    { match: "", app: "Comet", label: "park", whenIdleOnly: true, note: "conformance park rule (label deliberately unresolvable)" },
    { match: "gamma-oracle", space: 2, origin: "space-pin:s2" },
    { match: "nh", label: "nh" },
  ], null, 2) + "\n");

  // Recency fixtures — distinct last-human-typed times so active-first ordering
  // is fully determined (an all-zero tie would expose unstable-sort differences
  // between languages instead of contract differences).
  const projects = join(home, ".claude", "projects");
  const line = (ts: string) => JSON.stringify({ type: "user", message: { content: "hello" }, timestamp: ts }) + "\n";
  const seed = [
    ["-conformance-alpha", "2026-07-01T03:00:00.000Z"],
    ["-conformance-beta", "2026-07-01T02:00:00.000Z"],
    ["-conformance-gamma-oracle", "2026-07-01T01:00:00.000Z"],
    ["-conformance-nh", "2026-07-01T00:30:00.000Z"],
  ] as const;
  for (const [dir, ts] of seed) {
    const d = join(projects, dir);
    mkdirSync(d, { recursive: true });
    const f = join(d, "session.jsonl");
    writeFileSync(f, line(ts));
    const t = new Date(ts);
    utimesSync(f, t, t);
  }

  return { home, argvLog: join(root, "yabai-argv.jsonl"), root };
}

// ------------------------------------------------------------- collection ---
interface Collected {
  entries: Map<string, string>; // key -> normalized "status|content-type|body"
  argv: string;
  files: Record<string, string>;
}

// Deep-scrub live/instance-specific values; preserves object key order.
function scrub(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(scrub);
  if (v && typeof v === "object") {
    const o: Record<string, unknown> = {};
    for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
      if (k === "ts") { o[k] = "«ts»"; continue; }
      if (k === "backup") { o[k] = val == null ? null : "«backup-path»"; continue; }
      if (k === "idle" && val && typeof val === "object") {
        const idle = { ...(val as Record<string, unknown>) };
        idle.seconds = "«live»";
        idle.armed = "«live»";
        o[k] = idle;
        continue;
      }
      o[k] = scrub(val);
    }
    return o;
  }
  return v;
}

const normalizeJSON = (text: string) => JSON.stringify(scrub(JSON.parse(text)));
// File compare is formatting-agnostic (pretty vs sorted-keys) but array-order strict.
const canonical = (v: unknown): string => {
  const sort = (x: unknown): unknown => {
    if (Array.isArray(x)) return x.map(sort);
    if (x && typeof x === "object") {
      return Object.fromEntries(Object.keys(x as object).sort().map((k) => [k, sort((x as Record<string, unknown>)[k])]));
    }
    return x;
  };
  return JSON.stringify(sort(scrub(v)));
};

async function collect(t: Target): Promise<Collected> {
  const sbx = makeSandbox();
  const proc = Bun.spawn(t.cmd(t.port), {
    env: { ...process.env, ...t.env(sbx.home, sbx.argvLog, t.port) },
    cwd: REPO,
    stdout: "pipe",
    stderr: "pipe",
  });
  const base = `http://127.0.0.1:${t.port}`;

  const ready = async () => {
    for (let i = 0; i < 60; i++) {
      try {
        const r = await fetch(`${base}/api/pins`, { signal: AbortSignal.timeout(1000) });
        if (r.ok) return true;
      } catch {}
      await Bun.sleep(250);
    }
    return false;
  };
  if (!(await ready())) {
    proc.kill();
    const err = await new Response(proc.stderr).text();
    throw new Error(`${t.name}: server never became ready\n${err.slice(-2000)}`);
  }

  const entries = new Map<string, string>();
  const record = async (key: string, res: Response) => {
    const ct = (res.headers.get("content-type") ?? "").split(";")[0].trim();
    let body = await res.text();
    if (ct.includes("json")) {
      try { body = normalizeJSON(body); } catch { /* keep raw */ }
    }
    entries.set(key, `${res.status}|${ct}|${body}`);
  };
  const GET = async (path: string) => record(`GET ${path}`, await fetch(base + path));
  // Each POST also captures the yabai writes IT caused, so a divergence points
  // straight at the responsible route instead of an offset-shifted argv stream.
  const argvLines = () => (existsSync(sbx.argvLog) ? readFileSync(sbx.argvLog, "utf8").split("\n").filter(Boolean) : []);
  const POST = async (path: string, body?: unknown, headers: Record<string, string> = {}) => {
    const before = argvLines().length;
    const key = `POST ${path}${headers["X-Arrange-Source"] ? " [public-queue]" : ""}${(entries.has(`POST ${path}`) || entries.has(`POST ${path} #2`)) ? " #2" : ""}`;
    await record(key, await fetch(base + path, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    }));
    const writes = argvLines().slice(before);
    entries.set(`${key} → yabai`, writes.join("\n"));
  };

  // --- read surface ---
  await GET("/");
  await GET("/api/state");
  await GET("/api/who");
  await GET("/api/pins");
  const MODES = ["spiral", "flip", "flipup", "grid", "columns", "rows"];
  for (const space of [1, 2, 3, 4]) {
    await GET(`/api/current/${space}`);
    await GET(`/api/preview/${space}`); // defaults: spiral, active off
    for (const mode of MODES) {
      await GET(`/api/preview/${space}?mode=${mode}&active=1`);
      await GET(`/api/preview/${space}?mode=${mode}&active=0`);
    }
  }

  // --- write surface (argv stream + responses + state files) ---
  await POST("/api/space/1/apply", { mode: "flip", activeFirst: true });
  await POST("/api/space/1/apply", { mode: "grid", activeFirst: false });
  await POST("/api/space/3/apply", { mode: "columns", activeFirst: true }); // minimized window excluded
  await POST("/api/space/1/layout", { layout: "float" });
  await POST("/api/space/99/focus", {});
  await POST("/api/space/2/focus", {});
  await POST("/api/gather-to-main", {});
  await POST("/api/park", {});
  await POST("/api/space/2/pin", { pinned: true });
  await GET("/api/pins");
  await POST("/api/space/2/pin", { pinned: false });
  await POST("/api/pins/toggle", {});
  await GET("/api/pins");
  await POST("/api/pins/toggle", {});
  await POST("/api/arrange-profile", {});
  await POST("/api/snapshot-profile", {});
  await POST("/api/nope", {});
  // public-queue contract: allowed action passes, disallowed action 403s.
  await POST("/api/pins/toggle", {}, { "X-Arrange-Source": "public-queue" });
  await POST("/api/space/1/apply", { mode: "flip", activeFirst: true }, { "X-Arrange-Source": "public-queue" });

  const conf = join(sbx.home, ".config", "window-arranger-oracle");
  const files: Record<string, string> = {};
  files["oracle-profile.json"] = canonical(JSON.parse(readFileSync(join(conf, "oracle-profile.json"), "utf8")));
  files["pins.json"] = canonical(JSON.parse(readFileSync(join(conf, "pins.json"), "utf8")));
  files["audit.jsonl"] = readFileSync(join(conf, "audit.jsonl"), "utf8")
    .trim().split("\n").map((l) => normalizeJSON(l)).join("\n");

  const argv = existsSync(sbx.argvLog) ? readFileSync(sbx.argvLog, "utf8") : "";

  proc.kill();
  await proc.exited;
  rmSync(sbx.root, { recursive: true, force: true });
  return { entries, argv, files };
}

// ------------------------------------------------------------------ diff ---
function diff(ref: Collected, refName: string, got: Collected, gotName: string): string[] {
  const problems: string[] = [];
  for (const [key, want] of ref.entries) {
    const have = got.entries.get(key);
    if (have === undefined) { problems.push(`${key}: missing in ${gotName}`); continue; }
    if (have !== want) {
      const w = want.length > 400 ? want.slice(0, 400) + `… (${want.length}B)` : want;
      const h = have.length > 400 ? have.slice(0, 400) + `… (${have.length}B)` : have;
      problems.push(`${key}:\n  ${refName}: ${w}\n  ${gotName}: ${h}`);
    }
  }
  // Full-stream check is redundant with the per-POST deltas but cheap — it
  // catches writes from outside any request (e.g. a loop that shouldn't run).
  if (ref.argv !== got.argv) {
    problems.push(`total yabai write stream differs (${ref.argv.split("\n").filter(Boolean).length} vs ${got.argv.split("\n").filter(Boolean).length} lines) — see per-route diffs above`);
  }
  for (const [name, want] of Object.entries(ref.files)) {
    if (got.files[name] !== want) {
      problems.push(`file ${name}:\n  ${refName}: ${want.slice(0, 400)}\n  ${gotName}: ${(got.files[name] ?? "«missing»").slice(0, 400)}`);
    }
  }
  return problems;
}

// ------------------------------------------------------------------ main ---
const targetArg = process.argv.find((a) => a.startsWith("--targets"))?.split("=")[1]
  ?? process.argv[process.argv.indexOf("--targets") + 1];
const names = (process.argv.includes("--targets") ? targetArg : "ts,swift").split(",").map((s) => s.trim()).filter(Boolean);

const results: { name: string; c: Collected }[] = [];
for (const n of names) {
  const t = TARGETS[n];
  if (!t) { console.error(`unknown target: ${n}`); process.exit(2); }
  console.log(`▶ collecting ${n} …`);
  results.push({ name: n, c: await collect(t) });
  console.log(`  ${n}: ${results.at(-1)!.c.entries.size} endpoints, ${results.at(-1)!.c.argv.split("\n").filter(Boolean).length} yabai writes`);
}

let failed = false;
const [ref, ...rest] = results;
for (const r of rest) {
  const problems = diff(ref.c, ref.name, r.c, r.name);
  if (problems.length) {
    failed = true;
    console.log(`\n✘ ${r.name} diverges from ${ref.name} (${problems.length}):\n`);
    for (const p of problems.slice(0, 40)) console.log("— " + p + "\n");
    if (problems.length > 40) console.log(`… and ${problems.length - 40} more`);
  } else {
    console.log(`✔ ${r.name} == ${ref.name} (${ref.c.entries.size} endpoints, argv stream, state files)`);
  }
}
process.exit(failed ? 1 : 0);
