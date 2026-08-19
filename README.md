# window-arranger

Layout engine for macOS Spaces. Give it a Space, pick a profile, and it positions
every window with absolute geometry via [yabai](https://github.com/koekeishiya/yabai) —
no bsp tree, no re-tiling surprises.

Ships four surfaces over one layout core: a **menu bar app**, an **HTTP API**, a
**CLI**, and a **maw plugin**.

> **macOS only.** Requires yabai. The scripted addition (SIP disable) is *not* used.

---

## Layout profiles

| profile | shape |
|---|---|
| `spiral` | Fibonacci, largest left |
| `flip` | largest right, curls down (mirrorX · spiral) |
| `flipup` | mirrorY · mirrorX · spiral |
| `grid` | near-square rows × cols |
| `columns` | single row — `1 \| 2 \| 3` |
| `rows` | single column |

**active-first** (default on) reorders windows by most-recently-typed-in, so the
window you were last working in lands in the profile's prime slot.

---

## Quickstart

```bash
brew install koekeishiya/formulae/yabai   # required
bun install
bun run build:tools                       # builds scripts/bin/{cursor,idle} via swiftc
bun run server.ts                         # http://localhost:8900
```

Then apply a layout:

```bash
bun scripts/rotate-active.ts                       # rotate the active Space through the ring
bun scripts/rotate-active.ts grid                  # jump straight to a profile
bun scripts/rotate-active.ts --toggle columns flip # alternate on each press
```

`yabai` must be running and able to answer `yabai -m query --spaces`.

---

## Configuration

Everything lives in `~/.config/window-arranger-oracle/`:

| file | purpose |
|---|---|
| `oracle-profile.json` | per-window rules — pin an app to a Space, a display, or a grid cell |
| `pins.json` | windows that get snapped home if they drift |
| `displays.json` | display-id → human name. Display ids **reshuffle across reboots**; regenerate with `bun scripts/update-displays.ts` |
| `rotate-state.json` | last-applied profile, so `--toggle` alternates correctly |

See `menubar/oracle-profile.example.json` for the rule shape.

### Environment variables

| var | default | effect |
|---|---|---|
| `PORT` | `8900` | HTTP server port |
| `WA_ROOT` | current working directory | repo root, used to locate `public/index.html` |
| `WA_CENSUS_URL` | *(unset)* | if set, `/` hands off to this companion UI instead of serving locally |
| `WA_DISPLAY_MAP_PUBLISH` | *(unset)* | if set, a script run after each arrange and on a 60s heartbeat |
| `WA_SHADOW` | *(unset)* | `1` = read-only shadow instance; all background loops off |

`WA_CENSUS_URL` and `WA_DISPLAY_MAP_PUBLISH` are **opt-in** — unset means the
feature does nothing at all and spawns nothing.

---

## HTTP API

Reads are served from a cached snapshot (zero `yabai` forks per request); writes
mutate yabai and then refresh the snapshot once.

```
GET  /                       the UI
GET  /api/state              windows, spaces, displays
GET  /api/who                which display/Space has focus
GET  /api/preview/:space     SVG preview of a profile applied to a Space
POST /api/space/:n/apply     apply a profile to Space n
POST /api/arrange-profile    apply the whole rule set
POST /api/park               move parked apps to their target display
POST /api/pins/toggle        enable/disable the pin tracker
```

**Writes are loopback-only and fail closed** — the server binds `127.0.0.1`, and
non-loopback `POST`s are rejected anyway in case that bind ever changes.

---

## The four surfaces

| path | what | build |
|---|---|---|
| `server.ts` + `lib/` | reference implementation | `bun run server.ts` |
| `menubar/` | Swift menu bar app | `swift build -c release` or `scripts/build-app.sh` |
| `server-rs/` | Rust port of the HTTP server | `cargo build --release` |
| `maw-plugins/arrange/` | plugin for [maw](https://github.com/Soul-Brews-Studio/maw-rs) | `maw arrange organize` |

`lib/bsp.ts`, `menubar/Sources/WindowArrangerCore/Layout.swift` and
`server-rs/src/layout.rs` implement the **same** geometry. `test/conformance/`
runs all three against a shared fixture and a `fake-yabai` stub, so a change to
one that diverges from the others fails the suite.

```bash
bun test                     # unit tests
bun test/conformance/run.ts  # cross-implementation conformance
```

The menu bar app also registers two global hotkeys (Carbon — no `skhd` involved):
`⌃⌥⌘Space` to jump to a window, `⌃⌥⌘G` to bring one to you. `⌘Enter` flips modes.

---

## Keyboard bindings

This repo ships no hotkey daemon config. If you use
[skhd](https://github.com/koekeishiya/skhd), these pair well:

```sh
ctrl + alt + cmd - up    : cd /path/to/window-arranger && bun scripts/rotate-active.ts
ctrl + alt + cmd - down  : cd /path/to/window-arranger && bun scripts/rotate-active.ts --prev
ctrl + alt + cmd - 0x1E  : cd /path/to/window-arranger && bun scripts/rotate-active.ts --toggle columns flip
```

skhd and yabai each need macOS **Accessibility** permission, granted per process
tree in System Settings → Privacy & Security. Nothing here can grant it for you,
and every command will report success without it.

---

## Running it as a service

`menubar/com.soulbrews.window-arranger-menubar.plist` and `…-server.plist` are
**templates** — replace `__INSTALL_DIR__` with a real install path first, then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<plist>
```

LaunchAgents are per-user and run inside that user's GUI session. On a machine
using fast user switching, only the account that owns `/dev/console` is the one
on screen — check `stat -f '%Su' /dev/console` before wondering why nothing
appears to happen.

---

## License

MIT — see [LICENSE](LICENSE).

yabai is GPL-3.0. This project invokes it as a separate process and does not link
against it, so no copyleft obligation flows here.
