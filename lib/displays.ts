// Display id → monitor name mapping, persisted to a config file so we don't
// shell out to system_profiler on every request. yabai's display id equals the
// macOS CGDirectDisplayID, so the same id keys both. The file is hand-editable
// (rename a monitor to a friendly label) and refreshable via detectDisplayNames.
import { $ } from "bun";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export const CONFIG_PATH = `${process.env.HOME}/.config/window-arranger-oracle/displays.json`;

export type DisplayNameMap = Record<string, string>; // id (string) -> name

export function readDisplayConfig(): DisplayNameMap {
  try {
    return JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  } catch {
    return {};
  }
}

export function writeDisplayConfig(map: DisplayNameMap): void {
  mkdirSync(dirname(CONFIG_PATH), { recursive: true });
  writeFileSync(CONFIG_PATH, JSON.stringify(map, null, 2) + "\n");
}

// Query the live monitor names from macOS (id -> model, e.g. "DELL S2725QS").
export async function detectDisplayNames(): Promise<DisplayNameMap> {
  const map: DisplayNameMap = {};
  try {
    const data = JSON.parse(await $`system_profiler SPDisplaysDataType -json`.text());
    for (const gpu of data.SPDisplaysDataType ?? []) {
      for (const scr of gpu.spdisplays_ndrvs ?? []) {
        const id = Number(scr._spdisplays_displayID ?? scr.spdisplays_displayID);
        if (id) map[String(id)] = scr._name ?? "Display";
      }
    }
  } catch { /* system_profiler unavailable */ }
  return map;
}

// Regenerate the config from the live monitors and persist it. Existing
// hand-edited names are kept only for ids that are no longer present is up to
// the caller; here we overwrite with freshly-detected names but preserve any
// custom entries for ids not currently detected.
export async function refreshDisplayConfig(): Promise<DisplayNameMap> {
  const existing = readDisplayConfig();
  const detected = await detectDisplayNames();
  const merged = { ...existing, ...detected };
  writeDisplayConfig(merged);
  return merged;
}

// Read from config, bootstrapping it from a live detect on first run.
export async function displayNames(): Promise<DisplayNameMap> {
  const cfg = readDisplayConfig();
  if (Object.keys(cfg).length) return cfg;
  return refreshDisplayConfig();
}
