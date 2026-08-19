import Cocoa
import WindowArrangerCore
import WindowArrangerServerKit

// Carries a space + chosen layout mode through an NSMenuItem's representedObject.
final class ApplyRequest: NSObject {
    let space: YabaiSpace
    let mode: LayoutMode
    init(space: YabaiSpace, mode: LayoutMode) {
        self.space = space
        self.mode = mode
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    // Composable "active-first" flag — reorders windows so the one you last typed
    // in gets the layout's biggest slot. ON by default so every arrange puts the
    // active window biggest (pick Flip for it to land on the right). Toggle to off.
    private var activeFirst = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
        installEditMenu() // so ⌘A/⌘C/⌘V/⌘X/⌘Z work in the search field (Nat 2026-07-13)

        Engine.shared.start() // sample yabai into a cached snapshot on a poll

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Window Arranger")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        // Live space indicator: the title shows the FOCUSED space's number —
        // "space 4" — i.e. where you are right now. (Per-display map was tried
        // first but space numbers don't follow physical L→R order, so the row
        // of numbers read as shuffled; Nat picked focused-only 2026-07-08.)
        // NSStatusItem appears on every display's menu bar. Rides the same
        // Engine poll (no yabai signals — golden rule).
        updateStatusTitle()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatusTitle()
        }

        // 🦅 native-server health (Nat 2026-07-13 "System Tray ขึ้นบอก Status"):
        // a 2s-timeout GET /api/pins every 15s. Down → ⚠️ rides the space title
        // so it's visible without opening the menu; details live in a menu row.
        checkServer()
        serverTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkServer()
        }

        // รวมร่าง (Nat 2026-07-15 "เปิดมามี Status Bar แล้วก็ Run Server ด้วย"):
        // if nothing answers on :8900 (fresh machine, service removed), run the
        // server INSIDE this app. On m5 the launchd service usually owns the
        // port — then we adopt it: two pin-enforcement loops must never fight
        // over the same windows.
        startServerIfPortFree()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // ⌃⌥⌘Space (jump) / ⌃⌥⌘G (bring) — Spotlight-style oracle search
        // (Carbon hotkeys, app-side; no skhdrc involvement). ⌘Enter flips modes.
        SearchPanelController.shared.registerHotKey()
    }

    // A menu-bar accessory app has no main menu, so the standard text-editing
    // key equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) had nothing to route through and did
    // nothing in the search field (Nat 2026-07-13: "กด Command A select all
    // ได้ไหม"). Install a minimal Edit menu whose items are nil-targeted — AppKit
    // dispatches them down the responder chain to the field editor.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editHolder = NSMenuItem()
        mainMenu.addItem(editHolder)
        let edit = NSMenu(title: "Edit")
        editHolder.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
    }

    private var statusTimer: Timer?
    private var serverTimer: Timer?
    // nil = not checked yet; (up, pinsEnabled, rules) once a check lands.
    private var serverState: (up: Bool, pinsEnabled: Bool, rules: Int)?

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let warn = (serverState?.up == false) ? " ⚠️" : ""
        guard let snap = Engine.shared.snapshot,
              let focused = snap.spaces.first(where: { $0.hasFocus }) else {
            button.title = warn
            return
        }
        button.title = " space \(focused.index)" + warn
    }

    // In-process :8900 — set when THIS app is the server (no external one found).
    private var embeddedServer = false

    @objc private func openDashboard() {
        DashboardWindowController.shared.show()
    }

    private func startServerIfPortFree() {
        // Boot-race guard (Nat 2026-07-15): at login the launchd server
        // (com.soulbrews.window-arranger-server) may not have bound :8900 yet.
        // A single probe would then see the port "free", start THIS app's
        // embedded server, and grab it — leaving the launchd service
        // crash-looping ("Address already in use") forever with ownership
        // inverted. So probe up to 6× over ~6s and only run the embedded server
        // if NOBODY answers after the last try. The launchd server (KeepAlive)
        // is the canonical owner; when it answers we adopt it.
        probeThenMaybeEmbed(attempt: 0, maxAttempts: 6)
    }

    private func probeThenMaybeEmbed(attempt: Int, maxAttempts: Int) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8900/api/pins")!)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] _, response, _ in
            let up = (response as? HTTPURLResponse)?.statusCode == 200
            guard let self else { return }
            if up { return }                              // launchd server owns it → adopt, done
            if attempt + 1 >= maxAttempts {
                DispatchQueue.main.async { self.startEmbedded() }   // truly nobody after ~6s
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.probeThenMaybeEmbed(attempt: attempt + 1, maxAttempts: maxAttempts)
            }
        }.resume()
    }

    @objc private func startEmbedded() {
        guard !embeddedServer else { return }
        do {
            try ServerRuntime.start(port: 8900, shadow: false)
            embeddedServer = true
            checkServer()
        } catch {
            // Lost the race to another instance binding the port, or a real
            // failure — either way the 15s health check keeps reporting truth.
            NSLog("embedded server failed to start: \(error)")
        }
    }

    private func checkServer() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8900/api/pins")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            var state: (Bool, Bool, Int) = (false, false, 0)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                state = (true, obj["enabled"] as? Bool ?? false, obj["rules"] as? Int ?? 0)
            }
            DispatchQueue.main.async {
                self?.serverState = state
                self?.updateStatusTitle()
            }
        }.resume()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard YabaiClient.isAvailable else {
            menu.addItem(disabledItem("yabai not found"))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(quitItem())
            return
        }

        // 🦅 native-server status row (+ refresh the check on every open).
        checkServer()
        switch serverState {
        case let .some(s) where s.up:
            let pins = s.pinsEnabled ? "pins ON · \(s.rules) rules" : "pins OFF · \(s.rules) rules"
            let host = embeddedServer ? "in-app" : "native"
            menu.addItem(disabledItem("🦅 API :8900 \(host) ✓ · \(pins)"))
        case .some:
            menu.addItem(disabledItem("🦅 API :8900 ไม่ตอบ ⚠️"))
            let start = NSMenuItem(title: "▶️ Run server in this app now", action: #selector(startEmbedded), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
        case nil:
            menu.addItem(disabledItem("🦅 API :8900 — checking…"))
        }

        // 🖥 "กดดูง่าย" — the one web face, one click away (Nat 2026-07-15).
        let dash = NSMenuItem(title: "🖥 Oracle Display (กดดู)", action: #selector(openDashboard), keyEquivalent: "d")
        dash.target = self
        menu.addItem(dash)
        menu.addItem(NSMenuItem.separator())

        // Fresh sample on open — one snapshot feeds the whole menu build (and the
        // apply below), instead of scattered per-item yabai queries.
        Engine.shared.forceRefresh()
        let snap = Engine.shared.snapshot
        let displays = snap?.displays ?? []
        let spaces = snap?.spaces ?? []
        let displayIndexById = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.index) })

        // Global active-first toggle (checkable) — applies to whichever mode you pick.
        let af = NSMenuItem(title: "↻ Active-first (you typed = biggest)", action: #selector(toggleActiveFirst), keyEquivalent: "")
        af.target = self
        af.state = activeFirst ? .on : .off
        menu.addItem(af)
        menu.addItem(NSMenuItem.separator())

        // 💬 who did Nat last TALK TO (twin of `who.ts --last`; maw-relay traffic
        // filtered out, so oracle-to-oracle chatter doesn't fake recency).
        // Click = focus that oracle's window (macOS follows to its space).
        let talks = Recency.lastTalkedTo(snap?.windows ?? [], limit: 5)
        if !talks.isEmpty {
            menu.addItem(disabledItem("💬 Last talked to"))
            for talk in talks {
                let row = "  \(talk.window.title)  ·  \(agoLabel(since: talk.time))  ·  space \(talk.window.space)"
                let mi = NSMenuItem(title: row, action: #selector(focusWindowItem(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = talk.window.id
                menu.addItem(mi)
            }
            menu.addItem(NSMenuItem.separator())
        }

        let grouped = Dictionary(grouping: spaces, by: { $0.display })
        let orderedDisplayIds = grouped.keys.sorted { (displayIndexById[$0] ?? $0) < (displayIndexById[$1] ?? $1) }

        if orderedDisplayIds.isEmpty {
            menu.addItem(disabledItem("No spaces found"))
        }

        for displayId in orderedDisplayIds {
            let label = "Display \(displayIndexById[displayId] ?? displayId)"
            menu.addItem(disabledItem(label))

            let displaySpaces = (grouped[displayId] ?? []).sorted { $0.index < $1.index }
            for space in displaySpaces {
                menu.addItem(spaceItem(space))
            }
            menu.addItem(NSMenuItem.separator())
        }

        let search = NSMenuItem(title: "🔍 Search Oracle…  ⌃⌥⌘Space ไปหา · ⌃⌥⌘G พามา", action: #selector(openSearch), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        menu.addItem(NSMenuItem.separator())

        // 📸 Snapshot current → Profile, then ♻️ Restore (arrange by that profile).
        let snapshot = NSMenuItem(title: "📸 Snapshot layout → Profile", action: #selector(snapshotLayout), keyEquivalent: "")
        snapshot.target = self
        menu.addItem(snapshot)

        let arrange = NSMenuItem(title: "♻️ Restore (Arrange by Profile)…", action: #selector(arrangeOracles), keyEquivalent: "")
        arrange.target = self
        menu.addItem(arrange)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem())
    }

    private func spaceItem(_ space: YabaiSpace) -> NSMenuItem {
        let marker = space.hasFocus ? "●" : (space.isVisible ? "○" : " ")
        let title = "\(marker) Space \(space.index) — \(space.type) (\(space.windows.count) win)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

        let submenu = NSMenu()

        let focus = NSMenuItem(title: "Focus", action: #selector(focusSpace(_:)), keyEquivalent: "")
        focus.target = self
        focus.representedObject = space.index
        submenu.addItem(focus)

        submenu.addItem(NSMenuItem.separator())
        // Number keys were re-purposed to space switching (2026-07-08); layouts
        // are reachable via the ↑↓ ring and the [ ] \ keys, or right here.
        submenu.addItem(disabledItem("Apply tiling  ·  ⌃⌥⌘ ↑↓  ·  [ ] \\"))

        for mode in LayoutMode.allCases {
            let mi = NSMenuItem(title: "  \(mode.label)", action: #selector(applyTiling(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ApplyRequest(space: space, mode: mode)
            submenu.addItem(mi)
        }

        submenu.addItem(NSMenuItem.separator())

        let revert = NSMenuItem(title: "Revert to Float", action: #selector(setLayoutFloat(_:)), keyEquivalent: "")
        revert.target = self
        revert.representedObject = space.index
        submenu.addItem(revert)

        item.submenu = submenu
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func quitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Quit Window Arranger", action: #selector(quit), keyEquivalent: "q")
        item.target = self
        return item
    }

    private func agoLabel(since t: Double) -> String {
        let m = Int(Date().timeIntervalSince1970 - t) / 60
        if m < 1 { return "เมื่อกี้" }
        if m < 60 { return "\(m)m" }
        if m < 1440 { return "\(m / 60)h" }
        return "\(m / 1440)d"
    }

    @objc private func focusWindowItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int else { return }
        YabaiClient.focusWindow(id: id)
    }

    @objc private func focusSpace(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        YabaiClient.focusSpace(index: index)
    }

    @objc private func setLayoutFloat(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        Engine.shared.beginWrite()
        YabaiClient.setLayout(spaceIndex: index, layout: "float")
        Engine.shared.forceRefresh()
        Engine.shared.endWrite()
    }

    @objc private func toggleActiveFirst() {
        activeFirst.toggle()
    }

    @objc private func applyTiling(_ sender: NSMenuItem) {
        guard let req = sender.representedObject as? ApplyRequest else { return }
        let space = req.space

        // Everything reads from the engine snapshot (sampled fresh on menu open),
        // not live per-item queries.
        guard let snap = Engine.shared.snapshot else { return }
        let windows = snap.windows.filter { $0.space == space.index }.filter(Layout.isTileable)
        guard !windows.isEmpty else {
            showInfo(title: "No tileable windows", message: "Space \(space.index) has nothing to arrange.")
            return
        }

        // Comet got squished by re-tiling before (see CLAUDE.md "Open Threads").
        // Every apply confirms; call Comet out by name if it's in this space.
        let hasComet = windows.contains { $0.app.localizedCaseInsensitiveContains("Comet") }
        let label = req.mode.label + (activeFirst ? " + active-first" : "")

        let alert = NSAlert()
        alert.messageText = "Apply \(label) to Space \(space.index)?"
        var info = "Moves + resizes \(windows.count) window(s) to match this layout."
        if hasComet {
            info += "\n\n⚠️ Comet is open here — re-tiling has squished/lost its windows before."
        }
        alert.informativeText = info
        alert.alertStyle = hasComet ? .warning : .informational
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let display = snap.displays.first(where: { $0.index == space.display }) else {
            showInfo(title: "Display not found", message: "Could not read the frame for display \(space.display).")
            return
        }
        let cfg = snap.config
        let outer = Frame(
            x: display.frame.x + cfg.left,
            y: display.frame.y + cfg.top,
            w: display.frame.w - cfg.left - cfg.right,
            h: display.frame.h - cfg.top - cfg.bottom
        )
        let placements = Layout.compute(outer: outer, windows: windows, gap: cfg.gap, mode: req.mode, activeFirst: activeFirst)

        // Bracket the write so the poll can't cache a half-applied state; float
        // first so yabai stops managing these windows, then place each.
        Engine.shared.beginWrite()
        YabaiClient.setLayout(spaceIndex: space.index, layout: "float")
        for p in placements {
            YabaiClient.moveWindowAbs(id: p.win.id, x: p.rect.x, y: p.rect.y)
            YabaiClient.resizeWindowAbs(id: p.win.id, w: p.rect.w, h: p.rect.h)
        }
        Engine.shared.forceRefresh()
        Engine.shared.endWrite()
    }

    @objc private func openSearch() {
        // Match ⌃⌥⌘Space's mode (jump) — the menu item carries that label.
        SearchPanelController.shared.toggle(jump: true)
    }

    @objc private func snapshotLayout() {
        // Build a routing profile from where the oracles sit RIGHT NOW: each fleet
        // window (WezTerm, real non-shell title) → its current space. One per title.
        let windows = Engine.shared.snapshot?.windows ?? YabaiClient.windows()
        let shells: Set<String> = ["zsh", "sh", "-zsh", "bash", "-bash"]
        var seen = Set<String>()
        var rules: [OracleRule] = []
        for w in windows where w.app == "WezTerm" {
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = title.lowercased()
            if title.isEmpty || shells.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            rules.append(OracleRule(match: title, display: nil, space: w.space, label: nil, grid: nil))
        }
        guard !rules.isEmpty else {
            showInfo(title: "Nothing to snapshot", message: "No titled WezTerm (oracle) windows found.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Snapshot \(rules.count) oracle(s) → Profile?"
        alert.informativeText = "Saves each oracle's CURRENT space. The existing profile is backed up, then overwritten:\n\(OracleProfile.path)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Snapshot")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let backup = try OracleProfile.save(rules)
            var msg = "\(rules.count) oracle(s) saved to the profile."
            if let backup { msg += "\nBackup: \((backup as NSString).lastPathComponent)" }
            showInfo(title: "📸 Snapshot saved", message: msg)
        } catch {
            showInfo(title: "Snapshot failed", message: "\(error)")
        }
    }

    @objc private func arrangeOracles() {
        let rules = OracleProfile.load()
        guard !rules.isEmpty else {
            showInfo(
                title: "No profile found",
                message: "Create \(OracleProfile.path) — a JSON array of "
                    + "{\"match\": \"title substring\", \"display\": N, \"grid\": \"rows:cols:x:y:w:h\"} (grid optional)."
            )
            return
        }

        let windows = Engine.shared.snapshot?.windows ?? YabaiClient.windows()
        let planned: [(YabaiWindow, OracleRule)] = windows.compactMap { window in
            guard let rule = rules.first(where: {
                window.title.localizedCaseInsensitiveContains($0.match)
                    || window.app.localizedCaseInsensitiveContains($0.match)
            }), rule.target != nil else { return nil } // skip rules with no display/space target
            return (window, rule)
        }

        guard !planned.isEmpty else {
            showInfo(title: "No matches", message: "None of the \(windows.count) open windows matched a rule in the profile.")
            return
        }

        let summary = planned
            .map { "• \($0.0.app) — \($0.0.title)  →  \($0.1.targetDescription)" }
            .joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "Arrange \(planned.count) window(s)?"
        alert.informativeText = summary
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Arrange")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Engine.shared.beginWrite()
            for (window, rule) in planned {
                switch rule.target {
                case .space(let selector): YabaiClient.moveWindow(id: window.id, toSpace: selector)
                case .display(let display): YabaiClient.moveWindow(id: window.id, toDisplay: display)
                case nil: break
                }
                if let grid = rule.grid { YabaiClient.setGrid(id: window.id, grid: grid) }
            }
            Engine.shared.forceRefresh()
            Engine.shared.endWrite()
        }
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
