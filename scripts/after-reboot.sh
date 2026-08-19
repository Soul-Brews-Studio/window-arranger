#!/bin/bash
# after-reboot — bring the window-arranger stack back after a reboot, one command:
#   ./scripts/after-reboot.sh          # start server + restore oracle→space + report
#   ./scripts/after-reboot.sh --dry    # check only, move nothing
#
# What survives a reboot: the profile (~/.config/window-arranger-oracle/),
# macOS Spaces, yabai+skhd (launchd). What does NOT: tmux/maw sessions (the
# oracle windows), the :8900 server, the menu bar app.
#
# NOTE: this script does NOT open oracle windows — wake them first:
#   maw wake <oracle>            # per oracle
#   maw wake --from-snapshot     # or restore the fleet from maw's recovery snapshot
# Restore only MOVES existing windows (matched by title) to their saved space.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUN="${BUN:-$HOME/.bun/bin/bun}"
PORT="${PORT:-8900}"
DRY=""; [ "${1:-}" = "--dry" ] && DRY=1

echo "── after-reboot · window-arranger ──"

# 0) all displays attached? (space indices renumber if a monitor is missing —
#    restoring with a missing display would send oracles to the WRONG spaces)
EXPECTED_DISPLAYS=$(python3 -c 'import json;print(len(json.load(open("'"$HOME"'/.config/window-arranger-oracle/displays.json"))))' 2>/dev/null || echo "?")
ACTUAL_DISPLAYS=$(/opt/homebrew/bin/yabai -m query --displays 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
echo "displays: $ACTUAL_DISPLAYS attached (expected $EXPECTED_DISPLAYS)"
if [ "$EXPECTED_DISPLAYS" != "?" ] && [ "$ACTUAL_DISPLAYS" != "$EXPECTED_DISPLAYS" ]; then
  echo "⚠️  display count mismatch — plug in all monitors BEFORE restoring (space indices shift)."
  [ -z "$DRY" ] && { echo "   aborting (run with --dry to inspect)."; exit 1; }
fi

# 1) server up?
if curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/api/state"; then
  echo "server: already up on :$PORT"
else
  if [ -n "$DRY" ]; then
    echo "server: DOWN (would start it)"
  else
    echo "server: starting…"
    (cd "$REPO" && nohup "$BUN" server.ts > /tmp/window-arranger-server.log 2>&1 &)
    for i in 1 2 3 4 5 6 7 8; do
      sleep 1
      curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/api/state" && break
    done
    curl -s -o /dev/null --max-time 2 "http://localhost:$PORT/api/state" \
      && echo "server: up ✅" || { echo "server: FAILED — see /tmp/window-arranger-server.log"; exit 1; }
  fi
fi

# 2) restore oracle → saved space (♻️)
if [ -n "$DRY" ]; then
  echo "restore: skipped (--dry)"
else
  echo "restore: ♻️  arranging by profile…"
  curl -s -X POST --max-time 30 "http://localhost:$PORT/api/arrange-profile"; echo
fi

# 3) fleet report — who is where now
echo
(cd "$REPO" && "$BUN" scripts/who.ts --report)
