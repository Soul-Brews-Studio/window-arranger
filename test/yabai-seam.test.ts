// Proves the payoff of the YabaiClient runner seam: the whole layout pipeline
// (computeLayout → all pure geometry) runs against a FakeYabaiRunner with ZERO
// real yabai, and invalid indices are rejected before any argv is built.
import { expect, test } from "bun:test";
import { YabaiClient, FakeYabaiRunner, YabaiError } from "../lib/yabai";
import { computeLayout } from "../lib/bsp";

const win = (id: number, title: string) => ({
  id, app: "WezTerm", title, space: 1,
  "is-floating": false, "is-sticky": false, "is-minimized": false, "is-hidden": false,
  frame: { x: 0, y: 0, w: 1, h: 1 },
});

function stubClient() {
  const zero = { stdout: "0", stderr: "", exitCode: 0 };
  return new YabaiClient(new FakeYabaiRunner({
    "-m query --spaces --space 1": { stdout: JSON.stringify({ index: 1, display: 1 }), stderr: "", exitCode: 0 },
    "-m query --windows --space 1": { stdout: JSON.stringify([win(10, "alpha"), win(11, "beta")]), stderr: "", exitCode: 0 },
    "-m query --displays --display 1": { stdout: JSON.stringify({ id: 1, index: 1, frame: { x: 0, y: 0, w: 2000, h: 1000 } }), stderr: "", exitCode: 0 },
    "-m config --space 1 top_padding": zero,
    "-m config --space 1 bottom_padding": zero,
    "-m config --space 1 left_padding": zero,
    "-m config --space 1 right_padding": zero,
    "-m config --space 1 window_gap": zero,
  }));
}

test("computeLayout runs with a fake runner (no real yabai)", async () => {
  const layout = await computeLayout(1, "spiral", false, stubClient());
  expect(layout.leaves).toHaveLength(2);
  // spiral: first window takes the left half of a 2000-wide display.
  expect(layout.leaves[0].win.title).toBe("alpha");
  expect(layout.leaves[0].rect.w).toBe(1000);
});

test("invalid space index is rejected before spawn (the --space bug is impossible)", async () => {
  const client = stubClient();
  await expect(client.setLayout(Number("abc"), "float")).rejects.toBeInstanceOf(YabaiError);
  await expect(client.setLayout(-1, "float")).rejects.toMatchObject({ kind: "invalid-args" });
});
