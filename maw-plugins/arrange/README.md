# maw `arrange` plugin

window-arranger's desktop-organizing maw plugin. Terminal-first: closes
duplicate tmux mirror windows, parks non-terminal apps to the main Space, spreads
terminals so no Space holds more than N (default 3, each on its own display), then
tiles each terminal Space into equal side-by-side columns.

## Tools

```
maw arrange status              terminals per display/space + non-terminal apps (read-only)
maw arrange plan   [--max N]    dry-run the park + spread moves (no writes)
maw arrange dedup  [--dry-run]  close duplicate tmux mirror windows (keep 1 per session)
maw arrange spread [--max N]    park apps → main space, spread terminals ≤N/space
maw arrange organize [--max N]  the full pass: dedup → spread → tile columns → status
```

## Install (local)

```
maw plugin install <this-dir> --root ~/.maw/plugins --force
```

Requires `yabai` and `tmux` on PATH, and the repo's :8900 engine running (used for
the column tiling via `POST /api/space/:N/apply`).

## How it works

- **Terminal-first** — only `WezTerm` is spread/tiled. Every other app → `MAIN_SPACE = 1`
  (they get pinned elsewhere later). `Wispr Flow` is ignored (self-moving status pill).
- **dedup uses tmux ground truth, not window titles** — `tmux list-clients` finds
  sessions with >1 client; `detach-client` on the extras closes the mirror window
  while the session survives (re-open via ⌃⌥⌘Space). Title-based dedup is unsafe
  (e.g. five windows titled "zsh" are five distinct sessions, not duplicates).
- **tiling reuses the :8900 engine** — one source of layout truth; menu-bar inset + gaps.

## Known limitation

Follower apps (Discord, Wispr Flow) auto-raise onto the active Space, so they hop
back after being parked. That's the pin system's job, not the arranger's.
