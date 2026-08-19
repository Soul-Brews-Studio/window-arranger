// whenIdleOnly gate + parkNow, against a FakeYabaiRunner (zero real yabai).
// Contract with display-census (2026-07-12): 300s base threshold, 3× when the
// target window is focused on a visible space, null idle = never move.
import { expect, test } from "bun:test";
import { YabaiClient, FakeYabaiRunner } from "../lib/yabai";
import { enforcePins, parkNow, autoHealProfile, type OracleRule } from "../lib/oracle-profile";

const ok = { stdout: "", stderr: "", exitCode: 0 };

const comet = (over: Record<string, unknown> = {}) => ({
  id: 10, app: "Comet", title: "Docs — Comet", space: 3, display: 1,
  "is-floating": true, "is-sticky": false, "is-minimized": false, "is-hidden": false,
  frame: { x: 0, y: 0, w: 800, h: 600 },
  ...over,
}) as any;

const SPACES = [
  { index: 3, ["is-visible"]: true },
  { index: 21, label: "park", ["is-visible"]: false },
];
const PARK_PIN: OracleRule = { match: "", app: "Comet", label: "park", whenIdleOnly: true };

function client() {
  const runner = new FakeYabaiRunner({ "-m window 10 --space 21": ok });
  return { c: new YabaiClient(runner), runner };
}

test("whenIdleOnly: no idle measurement → never moves (fail safe)", async () => {
  for (const idle of [undefined, null]) {
    const { c, runner } = client();
    const { moved } = await enforcePins(c, [comet()], SPACES, [], {}, [PARK_PIN], idle);
    expect(moved).toHaveLength(0);
    expect(runner.calls).toHaveLength(0);
  }
});

test("whenIdleOnly: below threshold stays, past threshold parks (hidden space = base tier)", async () => {
  const spacesHidden = [{ index: 3, ["is-visible"]: false }, SPACES[1]];
  let { c } = client();
  expect((await enforcePins(c, [comet()], spacesHidden, [], {}, [PARK_PIN], 299)).moved).toHaveLength(0);
  ({ c } = client());
  expect((await enforcePins(c, [comet()], spacesHidden, [], {}, [PARK_PIN], 300)).moved).toHaveLength(1);
});

test("window on a VISIBLE space needs 3× idle, focus not required (video case)", async () => {
  const watching = comet(); // unfocused, space 3 is visible — may still be watched
  let { c } = client();
  expect((await enforcePins(c, [watching], SPACES, [], {}, [PARK_PIN], 600)).moved).toHaveLength(0);
  ({ c } = client());
  expect((await enforcePins(c, [watching], SPACES, [], {}, [PARK_PIN], 900)).moved).toHaveLength(1);
  // on a HIDDEN space (nobody can be watching it) → base threshold applies
  const hidden = comet({ "has-focus": true });
  const spacesHidden = [{ index: 3, ["is-visible"]: false }, SPACES[1]];
  ({ c } = client());
  expect((await enforcePins(c, [hidden], spacesHidden, [], {}, [PARK_PIN], 300)).moved).toHaveLength(1);
});

test("plain pins ignore the idle clock entirely", async () => {
  const pin: OracleRule = { match: "", app: "Comet", label: "park" };
  const { c } = client();
  const { moved } = await enforcePins(c, [comet()], SPACES, [], {}, [pin], 0);
  expect(moved).toHaveLength(1);
});

test("already in place → no call even when armed (no blink)", async () => {
  const { c, runner } = client();
  const parked = comet({ space: 21 });
  expect((await enforcePins(c, [parked], SPACES, [], {}, [PARK_PIN], 9999)).moved).toHaveLength(0);
  expect(runner.calls).toHaveLength(0);
});

test("parkNow forces the move regardless of idle (explicit pins)", async () => {
  const { c, runner } = client();
  const { moved } = await parkNow(c, [comet()], SPACES, [], {}, [PARK_PIN]);
  expect(moved).toHaveLength(1);
  expect(runner.calls[0].join(" ")).toBe("-m window 10 --space 21");
});

test("parkNow reports movedFrom = each moved window's source space (no post-move re-query)", async () => {
  const { c } = client();
  // comet() sits on space 3 → parked to 21 → source 3 recorded from the pre-move value
  const { moved, movedFrom } = await parkNow(c, [comet()], SPACES, [], {}, [PARK_PIN]);
  expect(moved).toHaveLength(1);
  expect(movedFrom).toEqual([3]);
  // an already-parked window contributes nothing (never moved)
  const { movedFrom: none } = await parkNow(new YabaiClient(new FakeYabaiRunner()), [comet({ space: 21 })], SPACES, [], {}, [PARK_PIN]);
  expect(none).toEqual([]);
});

// The critical review finding (2026-07-12): a park pin's windows live AWAY from
// their target by design, so a lost 'park' label must NEVER be healed onto
// wherever the browser currently sits (= Nat's working space).
test("auto-heal never relabels from a whenIdleOnly pin's window positions", async () => {
  const runner = new FakeYabaiRunner({ "-m space 3 --label park": ok, "-m space 3 --label home": ok });
  const c = new YabaiClient(runner);
  const spacesNoLabels = [{ index: 3 }, { index: 21 }]; // reboot: labels gone
  // park pin: evidence (all Comet on s3) exists but must be REJECTED
  const healedPark = await autoHealProfile(c, [comet()], spacesNoLabels, [PARK_PIN]);
  expect(healedPark).toHaveLength(0);
  expect(runner.calls).toHaveLength(0);
  // control: a plain keep-here pin with the same evidence DOES heal
  const keepPin: OracleRule = { match: "", app: "Comet", label: "home" };
  const healedKeep = await autoHealProfile(c, [comet()], spacesNoLabels, [keepPin]);
  expect(healedKeep).toHaveLength(1);
  expect(runner.calls[0].join(" ")).toBe("-m space 3 --label home");
});
