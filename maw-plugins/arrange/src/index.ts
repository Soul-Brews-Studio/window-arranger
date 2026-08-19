// maw arrange — window-arranger's layout tool (terminal-first).
//   status              terminals per display/space + non-terminal apps (read-only)
//   plan   [--max N]    dry-run the park+spread moves (no writes)
//   dedup  [--dry-run]  close duplicate tmux mirror windows (keep 1 per session)
//   spread [--max N]    park apps → main space, spread terminals ≤N/space
//   organize [--max N]  dedup + spread + tile each terminal space into columns
import {
  snapshot, computePlan, applyPlan, renderStatus, renderPlan,
  dedupPlan, applyDedup, renderDedup, tileTerminalSpaces,
  readReserved, writeReserved, renderReserved,
  emptyPanes, closeEmpty, renderEmpty,
} from "./impl";

type InvokeContext = { source: "cli" | string; args: string[] };
type PluginResult = { ok: boolean; output?: string; error?: string };

function parseMax(args: string[]): number {
  const i = args.indexOf("--max");
  if (i !== -1 && args[i + 1]) { const n = parseInt(args[i + 1], 10); if (Number.isFinite(n) && n >= 1) return n; }
  return 3;
}

async function dedup(dryRun: boolean): Promise<string> {
  const { detach, sessions } = await dedupPlan();
  const head = renderDedup(detach, sessions);
  if (dryRun || detach.length === 0) return head;
  const res = await applyDedup(detach);
  return `${head}\nclosed ${res.ok}/${detach.length}${res.fail ? ` (${res.fail} failed)` : ""}`;
}

async function spread(max: number): Promise<string> {
  const plan = computePlan(await snapshot(), max);
  if (plan.moves.length === 0) return renderPlan(plan);
  console.log(renderPlan(plan));
  const res = await applyPlan(plan);
  const tail = res.fail ? `\n⚠️ ${res.fail} failed:\n  ${res.errors.join("\n  ")}` : "";
  return `moved ${res.ok}/${plan.moves.length}${tail}`;
}

export async function handler(ctx: InvokeContext): Promise<PluginResult> {
  const args = ctx.source === "cli" ? (ctx.args ?? []) : [];
  const sub = args[0] && !args[0].startsWith("--") ? args[0] : "status";
  const max = parseMax(args);
  const dryRun = args.includes("--dry-run");
  try {
    if (sub === "status") return { ok: true, output: renderStatus(await snapshot(), max) };
    if (sub === "plan") return { ok: true, output: renderPlan(computePlan(await snapshot(), max)) };
    if (sub === "dedup") return { ok: true, output: await dedup(dryRun) };
    if (sub === "close-empty") {
      const panes = await emptyPanes();
      const head = renderEmpty(panes);
      if (dryRun || panes.length === 0) return { ok: true, output: head };
      const res = await closeEmpty(panes);
      return { ok: res.fail === 0, output: `${head}\nclosed ${res.ok}/${panes.length}${res.fail ? ` (${res.fail} failed)` : ""}` };
    }
    if (sub === "reserved") return { ok: true, output: renderReserved(await readReserved()) };
    if (sub === "reserve" || sub === "unreserve") {
      const n = parseInt(args[1], 10);
      if (!Number.isFinite(n) || n < 1) return { ok: false, error: `usage: maw arrange ${sub} <space#> ${sub === "reserve" ? "[label]" : ""}` };
      const m = await readReserved();
      if (sub === "reserve") m.set(n, args.slice(2).filter((a) => !a.startsWith("--")).join(" "));
      else m.delete(n);
      await writeReserved(m);
      return { ok: true, output: `${sub === "reserve" ? "reserved" : "unreserved"} space ${n}.\n${renderReserved(m)}` };
    }
    if (sub === "spread") {
      const out = await spread(max);
      return { ok: true, output: `${out}\n\n${renderStatus(await snapshot(), max)}` };
    }
    if (sub === "organize") {
      const steps: string[] = [];
      steps.push("① dedup\n" + await dedup(false));
      const empties = await emptyPanes();
      const ce = empties.length ? await closeEmpty(empties) : { ok: 0, fail: 0 };
      steps.push(`② close-empty\nclosed ${ce.ok} empty terminal(s)` + (empties.length ? "" : " (none)"));
      steps.push("③ spread\n" + await spread(max));
      const { tiled, failed } = await tileTerminalSpaces();
      steps.push(`④ tile columns → spaces [${tiled.join(", ")}]${failed.length ? ` (failed: ${failed.join("; ")})` : ""}`);
      steps.push("⑤ result\n" + renderStatus(await snapshot(), max));
      return { ok: failed.length === 0, output: steps.join("\n\n") };
    }
    return { ok: false, error: `unknown subcommand "${sub}". use: status | plan | dedup | spread | organize [--max N] [--dry-run]` };
  } catch (e: any) {
    return { ok: false, error: e?.message ?? String(e) };
  }
}

export default handler;

if (import.meta.main) {
  const result = await handler({ source: "cli", args: process.argv.slice(2) });
  if (result.output) console.log(result.output);
  if (result.error) console.error(result.error);
  process.exit(result.ok ? 0 : 1);
}
