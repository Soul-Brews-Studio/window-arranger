// update-displays — re-detect monitors from macOS and write the id→name mapping
// to the config file. Run whenever you plug/unplug or rename a monitor:
//   bun scripts/update-displays.ts
import { refreshDisplayConfig, CONFIG_PATH } from "../lib/displays";

const names = await refreshDisplayConfig();
console.log(`\n  wrote ${Object.keys(names).length} monitor(s) → ${CONFIG_PATH}\n`);
for (const [id, name] of Object.entries(names)) {
  console.log(`    display id ${id.padStart(3)}  ${name}`);
}
console.log("\n  edit that file to set friendly names; the app reads it on next request.\n");
