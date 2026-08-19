// ascii-preview — render a layout as a block plot in the terminal (no browser).
// Reuses lib/bsp computeLayout so the ASCII matches the SVG/apply exactly.
//   bun scripts/ascii-preview.ts <space> <mode>
import { computeLayout, LAYOUT_MODES, type LayoutMode } from "../lib/bsp";

const space = Number(process.argv[2] ?? "5");
const mode = (process.argv[3] ?? "flipup") as LayoutMode;
if (!LAYOUT_MODES.includes(mode)) {
  console.error(`mode must be one of: ${LAYOUT_MODES.join(", ")}`);
  process.exit(1);
}

const CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const COLS = 92;

const { display, leaves, total } = await computeLayout(space, mode);
const { x: fx, y: fy, w: fw, h: fh } = display.frame;
// Terminal cells are ~2:1 (taller than wide); halve rows to keep true aspect.
const ROWS = Math.max(6, Math.round((COLS * (fh / fw)) / 2));

const grid: string[][] = Array.from({ length: ROWS }, () => Array(COLS).fill("·"));
for (let ry = 0; ry < ROWS; ry++) {
  for (let rx = 0; rx < COLS; rx++) {
    const gx = fx + ((rx + 0.5) / COLS) * fw;
    const gy = fy + ((ry + 0.5) / ROWS) * fh;
    const idx = leaves.findIndex(
      (l) => gx >= l.rect.x && gx < l.rect.x + l.rect.w && gy >= l.rect.y && gy < l.rect.y + l.rect.h
    );
    if (idx >= 0) grid[ry][rx] = CHARS[idx % CHARS.length];
  }
}

console.log(`\n  mode=${mode}  space=${space}  windows=${total}\n`);
console.log(grid.map((r) => "  " + r.join("")).join("\n"));
console.log("\n  legend (draw order = largest → smallest):");
leaves.forEach((l, i) => {
  console.log(`    ${CHARS[i % CHARS.length]}  ${l.win.app}${l.win.title ? ": " + l.win.title : ""}`);
});
console.log("");
