#!/usr/bin/env python3
"""Diff the Bun server (:8900) against the native shadow (:8901).

Normalizes known-benign volatility (snapshot ts, idle grain, focus flicker is
NOT normalized — a mismatch there usually just means re-run) and reports every
structural difference path-by-path.
"""
import json, sys, urllib.request

BUN, SWIFT = "http://127.0.0.1:8900", "http://127.0.0.1:8901"

def get(base, path):
    with urllib.request.urlopen(base + path, timeout=5) as r:
        body = r.read()
        return r.status, r.headers.get("Content-Type", ""), body

def jget(base, path):
    _, _, body = get(base, path)
    return json.loads(body)

def diff(a, b, path="$", out=None):
    if out is None:
        out = []
    if type(a) is not type(b) and not (isinstance(a, (int, float)) and isinstance(b, (int, float))):
        out.append(f"{path}: TYPE {type(a).__name__} vs {type(b).__name__} ({a!r} vs {b!r})")
        return out
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: MISSING in bun, swift={b[k]!r}")
            elif k not in b:
                out.append(f"{path}.{k}: MISSING in swift, bun={a[k]!r}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: LEN {len(a)} vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif isinstance(a, float) or isinstance(b, float):
        if abs(float(a) - float(b)) > 1e-6:
            out.append(f"{path}: {a!r} vs {b!r}")
    elif a != b:
        out.append(f"{path}: {a!r} vs {b!r}")
    return out

def norm_who(w):
    w = json.loads(json.dumps(w))
    w.pop("ts", None)
    if isinstance(w.get("idle"), dict):
        w["idle"].pop("seconds", None)  # 10s grain can tick between fetches
    return w

def key_windows(w):
    # Sort rows by id so ordering differences don't mask real field diffs.
    for k in ("fleet", "windows"):
        if k in w:
            w[k] = sorted(w[k], key=lambda r: r["id"])
    return w

failures = 0

def report(name, diffs, cap=25):
    global failures
    if diffs:
        failures += 1
        print(f"❌ {name}: {len(diffs)} diff(s)")
        for d in diffs[:cap]:
            print(f"   {d}")
        if len(diffs) > cap:
            print(f"   … +{len(diffs)-cap} more")
    else:
        print(f"✅ {name}")

# 1. /api/pins
report("/api/pins", diff(jget(BUN, "/api/pins"), jget(SWIFT, "/api/pins")))

# 2. /api/state
report("/api/state", diff(jget(BUN, "/api/state"), jget(SWIFT, "/api/state")))

# 3. /api/who (ts + idle.seconds normalized, rows sorted by id)
a = key_windows(norm_who(jget(BUN, "/api/who")))
b = key_windows(norm_who(jget(SWIFT, "/api/who")))
report("/api/who", diff(a, b))

# 4. SVG endpoints for every space that exists
spaces = [s["index"] for s in jget(BUN, "/api/state")["spaces"]]
svg_diffs = []
for sp in spaces:
    for ep in (f"/api/current/{sp}", f"/api/preview/{sp}?mode=flip&active=1"):
        sa, ca, ba = get(BUN, ep)
        sb, cb, bb = get(SWIFT, ep)
        if sa != sb:
            svg_diffs.append(f"{ep}: status {sa} vs {sb}")
        elif ba != bb:
            svg_diffs.append(f"{ep}: body differs ({len(ba)}B vs {len(bb)}B)")
report(f"SVG x{len(spaces)*2}", svg_diffs, cap=8)

# 5. Content types
for ep, want in (("/api/who", "application/json"), ("/api/current/%d" % spaces[0], "image/svg+xml")):
    _, ct, _ = get(SWIFT, ep)
    if want not in ct:
        report(f"content-type {ep}", [f"{ct!r} lacks {want!r}"])
    else:
        print(f"✅ content-type {ep} = {ct}")

print(f"\n{'🎉 PARITY' if failures == 0 else f'💥 {failures} endpoint group(s) differ'}")
sys.exit(1 if failures else 0)
