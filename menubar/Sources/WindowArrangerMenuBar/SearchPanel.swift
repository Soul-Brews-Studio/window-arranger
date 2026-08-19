import Cocoa
import Carbon
import WindowArrangerCore

// Spotlight-style quick search for the oracle fleet. TWO global hotkeys open the
// same panel in different DEFAULT modes (so plain Enter does what the hotkey
// implies — Cmd+Return is unreliable in an NSSearchField, AppKit routes it to
// menu key-equivalents before the field editor, so we don't depend on it):
//   ⌃⌥⌘Space → JUMP mode:  Enter focuses the oracle where it lives; macOS follows
//   ⌃⌥⌘G     → BRING mode: Enter moves the oracle's window to your space + focus
//   (swapped 2026-07-13 per Nat: Space = ไปหา, G = พามา)
//   (⌘Enter still flips to the OTHER action if AppKit happens to deliver it)
//   ⌥Enter   → MIRROR: open a 2nd WezTerm window on the SAME tmux session — a live
//              clone of the same soul on your space; the original window stays put.
//              (Option+Return arrives as insertNewlineIgnoringFieldEditor, which
//              AppKit delivers reliably, unlike Cmd+Return.)
//   Esc      = close
// The list shows TWO kinds of rows:
//   • windows — live WezTerm windows (from the Engine snapshot; opens instantly
//     from cache, freshened right after first paint), matched by WINDOW TITLE.
//   • ghosts  — tmux sessions with NO on-screen titled window, matched by SESSION
//     NAME. Covers headless oracles (zero clients) AND attached-but-untitled ones:
//     a fresh / never-logged-in oracle shows "✳ Claude Code" as its title, not its
//     name, so a title-only search can't see it (Nat 2026-07-13, oracle-dig-ui).
//     Enter opens a WezTerm window attached to the session (re-embody a headless
//     one, or a drivable view onto an untitled one), landing on your current space.
//   • catalog — DORMANT oracles from `maw oracle ls` (no window, no session),
//     matched by NAME/org/repo, shown only when you type. Enter wakes the oracle
//     (`maw wake --no-attach`) and attaches a WezTerm window — Quicksilver launch.
//
// A nonactivating panel that can still take keyboard focus — the Spotlight
// pattern: the panel gets key WITHOUT activating the app, so it works from a
// Carbon hotkey no matter which app is frontmost, and never self-hides.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // ⌘Enter never reaches the field editor's insertNewline: AppKit looks for a menu
    // key-equivalent for Cmd+Return first, finds none, and BEEPS (Nat 2026-07-13
    // "ต๊อก ๆ"). The window's performKeyEquivalent runs BEFORE the menu, so intercept
    // Return-with-modifiers here where it's delivered reliably.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if SearchPanelController.shared.handleReturnKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// One oracle from `maw oracle ls --json` → .oracles[]. Codable (not just
// Decodable) so the disk mirror can round-trip.
struct OracleCatalogEntry: Codable {
    let name: String
    let org: String?
    let repo: String?
    let localPath: String?
    let session: String?   // ⚠ stale-prone (exact-name-match only) — NEVER use for dormancy
    let awake: Bool?       // same caveat: 65-window-arranger was live yet awake:false
    enum CodingKeys: String, CodingKey {
        case name, org, repo, session, awake
        case localPath = "local_path"
    }
}

// Quicksilver-style catalog cache: load once at launch, timer ~5min, stale-gated
// refresh on panel open. NEVER exec'd per keystroke — applyFilter only reads
// `entries` (main-thread published, Engine.swift publish-on-main discipline).
final class OracleCatalog {
    static let shared = OracleCatalog()
    private(set) var entries: [OracleCatalogEntry] = []   // read on main only
    private(set) var loadedAt: Date?
    private var timer: Timer?
    private var refreshing = false

    private struct MawOracleLs: Decodable { let oracles: [OracleCatalogEntry]? }
    private struct DiskCache: Codable { let ts: Double; let oracles: [OracleCatalogEntry] }
    private static let cachePath = WAEnv.home
        .appendingPathComponent(".config/window-arranger-oracle/oracle-catalog.json").path

    func start() {                       // call once, on main, at launch
        loadDiskCache()                  // instant cold start (~208 names before first exec)
        refreshAsync()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshAsync()
        }
        timer?.tolerance = 30
    }

    func refreshIfStale(maxAge: TimeInterval = 120, completion: (() -> Void)? = nil) {
        if let t = loadedAt, Date().timeIntervalSince(t) < maxAge { completion?(); return }
        refreshAsync(completion: completion)
    }

    func refreshAsync(completion: (() -> Void)? = nil) {
        guard !refreshing else { completion?(); return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var list: [OracleCatalogEntry] = []
            if let data = SearchPanelController.runMaw(["oracle", "ls", "--json"]),
               let parsed = try? JSONDecoder().decode(MawOracleLs.self, from: data) {
                // drop spurious entries like "--help" that `maw oracle ls --json` can emit
                list = (parsed.oracles ?? [])
                    .filter { !$0.name.hasPrefix("-") }
                    .sorted { $0.name.lowercased() < $1.name.lowercased() }
            } else {
                FileHandle.standardError.write("search: catalog → maw oracle ls FAILED\n".data(using: .utf8)!)
            }
            DispatchQueue.main.async {
                self?.refreshing = false
                if !list.isEmpty {
                    self?.entries = list
                    self?.loadedAt = Date()
                    self?.saveDiskCache(list)
                }
                completion?()
            }
        }
    }

    private func loadDiskCache() {
        guard let data = FileManager.default.contents(atPath: Self.cachePath),
              let cache = try? JSONDecoder().decode(DiskCache.self, from: data) else { return }
        entries = cache.oracles
        // loadedAt deliberately left nil → disk copy always counts as stale,
        // so the first panel open triggers a real refresh.
    }

    // The disk mirror is a cache artifact (overwrite-on-refresh), NOT hand-edited
    // config — the Pins.swift "re-read every tick" rule does not apply here.
    private func saveDiskCache(_ list: [OracleCatalogEntry]) {
        DispatchQueue.global(qos: .utility).async {
            let url = URL(fileURLWithPath: Self.cachePath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if var data = try? enc.encode(DiskCache(ts: Date().timeIntervalSince1970 * 1000, oracles: list)) {
                data.append(0x0A)                       // trailing newline (Displays.refresh idiom)
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// Quicksilver-style use tracker: how many times each oracle was launched from
// this panel and when last — persisted to oracle-usage.json. Drives the catalog's
// "recently used" order + the ×N frequency counter. Access is main-thread-only in
// practice (the sort/render read on main; bump hops its mutation + tiny disk write
// to main). First touch is always a main-thread applyFilter (you must type to see a
// catalog row before you can launch one), so init races can't occur.
final class OracleUsage {
    static let shared = OracleUsage()
    private var counts: [String: Int] = [:]
    private var lasts: [String: Double] = [:]        // epoch ms of last launch
    private struct Disk: Codable { var counts: [String: Int]; var lasts: [String: Double] }
    private static let path = WAEnv.home
        .appendingPathComponent(".config/window-arranger-oracle/oracle-usage.json").path

    init() {
        guard let d = FileManager.default.contents(atPath: Self.path),
              let disk = try? JSONDecoder().decode(Disk.self, from: d) else { return }
        counts = disk.counts; lasts = disk.lasts
    }
    func count(_ name: String) -> Int { counts[name.lowercased()] ?? 0 }
    func lastUsed(_ name: String) -> Double { lasts[name.lowercased()] ?? 0 }

    func bump(_ name: String) {                       // record a launch (any thread)
        let k = name.lowercased(), ms = Date().timeIntervalSince1970 * 1000
        DispatchQueue.main.async {
            self.counts[k] = (self.counts[k] ?? 0) + 1
            self.lasts[k] = ms
            let url = URL(fileURLWithPath: Self.path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(Disk(counts: self.counts, lasts: self.lasts)) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

final class SearchPanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = SearchPanelController()

    // Everything we READ about the fleet goes through `maw` (see runMaw) — the
    // fleet's one tmux choke point, so this panel always agrees with `maw ls`
    // (Nat 2026-07-13: "ทำผ่าน maw ได้ป่ะ มันจะได้ง่าย ไปทางเดียวกัน"). tmux is
    // invoked DIRECTLY for one thing only: attaching a client (mirror/re-embody),
    // with -S pinning the standard socket — under launchd a bare `tmux` resolves
    // its socket dir to $TMPDIR, where no server exists.
    private static let tmuxSocket = "/private/tmp/tmux-\(getuid())/default"

    // maw-rs binary: shells see an alias/function; Process needs the real path.
    // fileprivate (not private): OracleCatalog — a sibling top-level type in this
    // file — execs maw through this same launchd-hardened choke point, and Swift
    // `private` on a type member is invisible even to same-file siblings.
    fileprivate static let mawPath: String = {
        let home = NSHomeDirectory()
        for p in ["\(home)/.local/bin/maw", "\(home)/.bun/bin/maw", "/opt/homebrew/bin/maw"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/usr/local/bin/maw"
    }()

    // Run maw with a PATH that includes /opt/homebrew/bin — maw shells out to
    // `tmux` by name, and the launchd default PATH lacks homebrew (verified: maw
    // under launchd returns EMPTY without this). Returns stdout, nil on failure.
    fileprivate static func runMaw(_ args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: mawPath)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // launchd provides no locale, so tmux (inside maw) treats every non-ASCII
        // char as unprintable and prints '_' instead — "✳ …" and Thai pane titles
        // came out as underscore soup (Nat 2026-07-13, pixel-perfect pass).
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        if env["LC_ALL"] == nil { env["LC_ALL"] = "en_US.UTF-8" }
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        // null, not an undrained Pipe — a filled pipe buffer would deadlock the child
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }

    private static let weztermPath: String = {
        for p in ["/Applications/WezTerm.app/Contents/MacOS/wezterm", "/opt/homebrew/bin/wezterm"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/bin/wezterm"
    }()

    private enum Row {
        case window(YabaiWindow)
        case ghost(session: String, oracle: String)
        case catalog(OracleCatalogEntry)
    }

    private var panel: NSPanel?
    private var field: NSSearchField!
    private var table: NSTableView!
    private var hint: NSTextField!
    private var fleet: [YabaiWindow] = []
    // Every fleet session (from `maw ls --json`). applyFilter shows the ones with
    // no on-screen titled window as 👻 rows matched by SESSION NAME — covers both
    // headless oracles and attached-but-untitled ones (a fresh oracle's pane says
    // only "✳ Claude Code", never its name), which a title-only search misses.
    private var ghosts: [(session: String, oracle: String, alt: String?)] = []
    // oracle name (session minus numeric prefix, lowercased) → the CURRENTLY VISIBLE
    // pane's title (e.g. "✳ oracle-dig-mcp-tool"). Lets search match what you SEE on
    // screen (the task label), not just the WezTerm window title (Nat 2026-07-13).
    private var paneTitles: [String: String] = [:]
    // window title (normalized, spinner stripped) → the FOLDER the pane is cd'd
    // into (from `wezterm cli list` cwd). A window wears whatever title its
    // program sets — the session building census's space wall was titled
    // "3d-space-travel-visualizer" while working in display-census/, so "displ"
    // found nothing (Nat 2026-07-13 round 2). Searching the folder too means a
    // window is findable by WHERE it works, whatever its title says.
    private var cwds: [String: String] = [:]
    // name (normalized title / oracle stem, lowercased) → when Nat last TYPED to
    // that oracle (Recency's jsonl tail-scan — the same clock as active-first).
    // Drives recent-on-top ordering: the list opens with "ใครคุยล่าสุด" first,
    // not 3e-infra/agora/ajfon A-Z (Nat via census, 2026-07-13).
    private var recencyTs: [String: Double] = [:]
    private var rows: [Row] = []
    private var spacesByIndex: [Int: YabaiSpace] = [:]

    private func ts(_ win: YabaiWindow) -> Double {
        recencyTs[SearchPanelController.normTitle(win.title)] ?? 0
    }
    private func ts(ghost g: (session: String, oracle: String, alt: String?)) -> Double {
        max(recencyTs[g.oracle.lowercased()] ?? 0,
            g.alt.flatMap { recencyTs[$0.lowercased()] } ?? 0)
    }

    // Key titles with the animated spinner stripped — Claude's title cycles
    // through BOTH braille frames (⠐/⠂, U+2800–28FF) and asterisk frames
    // (✳/✻/✽/…), and yabai vs wezterm can catch different frames of the same
    // window — so "⠐ name", "✳ name" and "name" all key identically.
    private static let spinnerEdges = CharacterSet(charactersIn: "✳✻✽✺✷*·…⏺").union(.whitespaces)
    private static func normTitle(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x2800...0x28FF).contains(Int($0.value)) }))
            .trimmingCharacters(in: spinnerEdges).lowercased()
    }

    // Titles shared by 2+ windows can't claim a folder (see reloadFleet).
    private var dupNormTitles: Set<String> = []

    private func cwdRepo(_ win: YabaiWindow) -> String? {
        let key = SearchPanelController.normTitle(win.title)
        guard !dupNormTitles.contains(key) else { return nil }
        return cwds[key]
    }

    // Carbon global hotkeys — work app-side without touching skhdrc. TWO ids:
    // 1 = ⌃⌥⌘Space (JUMP mode), 2 = ⌃⌥⌘G (BRING mode). The one handler reads the
    // fired hotkey's id from the event and opens the panel in the matching mode.
    func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installErr = InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let jump = (hkID.id == 1)
            DispatchQueue.main.async { SearchPanelController.shared.toggle(jump: jump) }
            return noErr
        }, 1, &eventType, nil, nil)
        let sig = OSType(0x5741_5243) // 'WARC'
        var refSpace: EventHotKeyRef?
        var refG: EventHotKeyRef?
        // kVK_Space = 49 → JUMP (id 1); kVK_ANSI_G = 5 → BRING (id 2). ⌃⌥⌘ = ctrl|opt|cmd.
        // (⌃⌥⌘K is NOT free — skhd binds it to window --focus north.)
        let regSpace = RegisterEventHotKey(49, UInt32(controlKey | optionKey | cmdKey),
                                           EventHotKeyID(signature: sig, id: 1), GetApplicationEventTarget(), 0, &refSpace)
        let regG = RegisterEventHotKey(5, UInt32(controlKey | optionKey | cmdKey),
                                       EventHotKeyID(signature: sig, id: 2), GetApplicationEventTarget(), 0, &refG)
        FileHandle.standardError.write("search: install=\(installErr) reg-space=\(regSpace) reg-g=\(regG)\n".data(using: .utf8)!)
        // One-shot startup probe: confirms tmux is reachable from THIS launchd context
        // (computeGhosts logs its own count). If this ever reads 0 again, the socket
        // path drifted.
        DispatchQueue.global(qos: .utility).async { _ = SearchPanelController.computeGhosts() }
        // Catalog: load disk mirror instantly, then maw refresh + 5-min timer.
        // registerHotKey runs on main during applicationDidFinishLaunching — a
        // valid runloop for Timer.scheduledTimer.
        OracleCatalog.shared.start()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    // When true, plain Enter JUMPS to the oracle (opened via ⌃⌥⌘Space); when false,
    // Enter BRINGS it here (⌃⌥⌘G). Set per-open by toggle(jump:).
    private var defaultJump = false

    func toggle(jump: Bool = false) {
        if panel?.isVisible == true { hide() } else { show(jump: jump) }
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func show(jump: Bool = false) {
        defaultJump = jump
        buildIfNeeded()
        // INSTANT open: render from the CACHED snapshot (0 forks). Ghosts (a tmux
        // exec) and a fresh yabai sample load in the BACKGROUND and re-render when
        // ready — nothing forks on the main thread while the panel is up, so
        // typing stays smooth (Nat 2026-07-12 "มันควรจะ native").
        reloadFleet(from: Engine.shared.snapshot)

        field.stringValue = ""
        // Placeholder tells you which mode you opened — the two hotkeys look
        // identical once the panel is up, so name the Enter action.
        field.placeholderString = defaultJump ? "ไปหา oracle…  (⏎ ไปหา · ⌘⏎ ย้ายมา · ⌥⏎ โคลน)"
                                              : "เรียก oracle มาหา…  (⏎ ย้ายมา · ⌘⏎ ไปหา · ⌥⏎ โคลน)"
        applyFilter("")

        // Ghosts: background tmux exec → re-filter on main when it returns.
        loadGhostsAsync { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            self.applyFilter(self.field.stringValue)
        }
        // Catalog: refetch only if the in-memory copy is older than ~2 min (the
        // 5-min timer covers the rest). maw's own scan cache makes this cheap.
        OracleCatalog.shared.refreshIfStale(maxAge: 120) { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            self.applyFilter(self.field.stringValue)
        }
        // Freshen the yabai snapshot off the main thread, then re-render.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            Engine.shared.refreshAsync { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.reloadFleet(from: Engine.shared.snapshot)
                self.applyFilter(self.field.stringValue)
            }
        }

        // Center on the screen that currently has keyboard focus, Spotlight-height.
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let f = screen.frame
        let w: CGFloat = 640, h: CGFloat = 340
        panel?.setFrame(NSRect(x: f.midX - w / 2, y: f.midY - h / 2 + f.height * 0.12, width: w, height: h), display: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(field)
    }

    private func reloadFleet(from snap: Snapshot?) {
        let shells: Set<String> = ["zsh", "sh", "-zsh", "bash", "-bash"]
        fleet = (snap?.windows ?? [])
            .filter { $0.app == "WezTerm" }
            .filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .filter { !shells.contains($0.title.lowercased()) }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
        spacesByIndex = Dictionary(uniqueKeysWithValues: (snap?.spaces ?? []).map { ($0.index, $0) })
        // Titles carried by MORE THAN ONE window: the wezterm cwd map is keyed
        // by title, so a shared title can't be attributed to one window — one
        // window's folder was landing on its twin's row (Nat's "window-arranger
        // ×2 both 📁 display-census" screenshot). Never guess: no cwd for dups.
        var seen = Set<String>(), dups = Set<String>()
        for w in fleet {
            let key = SearchPanelController.normTitle(w.title)
            if !seen.insert(key).inserted { dups.insert(key) }
        }
        dupNormTitles = dups
    }

    // Fleet sessions + pane titles, via TWO maw execs (~20ms each) OFF the main
    // thread; results land + the panel re-filters back on main (Nat 2026-07-12: no
    // forks on the typing hot path).
    //
    // WHY maw and not raw tmux (Nat 2026-07-13, the "violet ไม่เจอ" incident): a
    // tmux client with no TTY — which is what launchd gives this app — SANITIZES
    // control chars in its output, so a TAB separator in a -F format comes out as
    // '_' and tab-splitting silently parses 0 sessions while the identical command
    // works in any shell. maw --json has no such trap, and going through maw keeps
    // this panel in exact agreement with `maw ls` — one road for the whole fleet.
    private func loadGhostsAsync(_ completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let g = SearchPanelController.computeGhosts()
            var p = SearchPanelController.computePaneTitles()
            // Pane titles are keyed by the session STEM, but a live window may be
            // titled with the oracle's ALT (repo) name — mirror the entry under the
            // alias so the window row's title lookup hits too.
            for ghost in g {
                if let alt = ghost.alt?.lowercased(), p[alt] == nil, let t = p[ghost.oracle.lowercased()] {
                    p[alt] = t
                }
            }
            let c = SearchPanelController.computeCwds()
            // Recency ranks for recent-on-top: one jsonl tail-scan per name,
            // HERE (off main, once per panel open) so per-keystroke sorting is
            // a dict lookup, never file I/O.
            var names = g.map { $0.oracle.lowercased() } + g.compactMap { $0.alt?.lowercased() }
            names += DispatchQueue.main.sync { self?.fleet.map { SearchPanelController.normTitle($0.title) } ?? [] }
            let r = Recency.lastHumanTimes(names: names)
            DispatchQueue.main.async {
                self?.ghosts = g; self?.paneTitles = p; self?.cwds = c; self?.recencyTs = r
                completion()
            }
        }
    }

    private struct WezPane: Decodable { let title: String?; let cwd: String? }

    // Normalized window title → the folder its pane works in, via
    // `wezterm cli list` (each fleet window is one wezterm window/pane; the cli
    // exposes the cwd the title can't be trusted to reveal).
    private static func computeCwds() -> [String: String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: weztermPath)
        proc.arguments = ["cli", "list", "--format", "json"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [:] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let panes = try? JSONDecoder().decode([WezPane].self, from: data) else { return [:] }
        var map: [String: String] = [:]
        for pane in panes {
            guard let title = pane.title, !title.isEmpty,
                  let cwd = pane.cwd, let url = URL(string: cwd) else { continue }
            // A pane parked at $HOME would make its folder name match everything.
            guard url.path != NSHomeDirectory() else { continue }
            let repo = url.lastPathComponent
            guard !repo.isEmpty, repo != "/" else { continue }
            map[normTitle(title)] = repo
        }
        FileHandle.standardError.write("search: computeCwds → \(map.count) folders via wezterm\n".data(using: .utf8)!)
        return map
    }

    private struct MawLs: Decodable {
        struct Entry: Decodable { let session: String; let oracle: String? }
        let sessions: [Entry]?
    }

    private static func computeGhosts() -> [(session: String, oracle: String, alt: String?)] {
        guard let data = runMaw(["ls", "--json"]),
              let parsed = try? JSONDecoder().decode(MawLs.self, from: data) else {
            FileHandle.standardError.write("search: computeGhosts → maw ls FAILED (path \(mawPath))\n".data(using: .utf8)!)
            return []
        }
        let all = (parsed.sessions ?? []).map { e -> (session: String, oracle: String, alt: String?) in
            let stem = e.session.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            // maw often knows the oracle's REPO name too (101-fireman → oracle:
            // "fireman-oracle") and the on-screen WezTerm window can be titled with
            // EITHER form (fireman's says "fireman-oracle", digger's says "digger"),
            // so carry the repo name as an alias for dedup / mirror / title lookups.
            let alt = (e.oracle?.isEmpty == false && e.oracle != stem) ? e.oracle : nil
            return (session: e.session, oracle: stem, alt: alt)
        }.sorted { $0.oracle.lowercased() < $1.oracle.lowercased() }
        FileHandle.standardError.write("search: computeGhosts → \(all.count) sessions via maw\n".data(using: .utf8)!)
        return all
    }

    private struct MawLsVerbose: Decodable {
        struct Pane: Decodable { let session: String; let title: String?; let agent: Bool? }
        let panes: [Pane]?
    }

    // oracle name → its pane titles (joined) from `maw ls -v --json`. The pane
    // title is the on-screen task label (e.g. "✳ oracle-dig-mcp-tool"), which often
    // differs from the WezTerm window title — searching it finds what the eye sees.
    private static func computePaneTitles() -> [String: String] {
        guard let data = runMaw(["ls", "-v", "--json"]),
              let parsed = try? JSONDecoder().decode(MawLsVerbose.self, from: data) else { return [:] }
        var map: [String: String] = [:]
        for pane in parsed.panes ?? [] {
            // AGENT panes only, deduped, no tiny titles (bare hostname "m5" panes
            // false-matched 6 oracles), and no idle "✳ Claude Code" boilerplate —
            // it says nothing and would make "claude" match every idle oracle.
            guard pane.agent == true, let title = pane.title, title.count >= 3,
                  title.range(of: #"^\W*Claude Code$"#, options: .regularExpression) == nil else { continue }
            let oracle = pane.session
                .replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
                .lowercased()
            if let existing = map[oracle] {
                if !existing.contains(title) { map[oracle] = "\(existing) · \(title)" }
            } else {
                map[oracle] = title
            }
        }
        return map
    }

    private func buildIfNeeded() {
        guard panel == nil else { return }

        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 340),
                             styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = self
        p.collectionBehavior = [.canJoinAllSpaces, .transient] // follow me to any space
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView()
        p.contentView = content

        field = NSSearchField()
        field.placeholderString = "Search oracle…  (⏎ bring · ⌥⏎ mirror)"
        field.font = NSFont.systemFont(ofSize: 18)
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        let col = NSTableColumn(identifier: .init("oracle"))
        col.width = 600
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint = NSTextField(labelWithString: "")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(scroll)
        content.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        panel = p
    }

    // ---- filtering ----

    private func applyFilter(_ q: String) {
        let needle = q.trimmingCharacters(in: .whitespaces).lowercased()
        // Recent-on-top within every tier: last-typed-to first (the Recency
        // clock), alphabetical only as the tiebreak for never-typed-to names.
        let byRecency: (YabaiWindow, YabaiWindow) -> Bool = { [self] a, b in
            let (ta, tb) = (ts(a), ts(b))
            return ta != tb ? ta > tb : a.title.lowercased() < b.title.lowercased()
        }
        let winMatches: [YabaiWindow]
        if needle.isEmpty {
            winMatches = fleet.sorted(by: byRecency)
        } else {
            // Match the window TITLE or its on-screen pane/task title (what you SEE —
            // e.g. arra-oracle-v3's pane reads "✳ oracle-dig-mcp-tool", so "dig"/"mcp"
            // find it). Substring first, then subsequence fuzzy ("wda" → window-arranger).
            let sub = fleet.filter { winSubMatch($0, needle) }.sorted(by: byRecency)
            let fuzzy = fleet.filter { winFuzzyMatch($0, needle) }.sorted(by: byRecency)
            winMatches = sub + fuzzy
        }
        // A session already shown as an on-screen window (its oracle name == a live
        // WezTerm title) is dropped here to avoid a duplicate row. Everything else —
        // headless OR attached-but-untitled — is matched by SESSION NAME (and by its
        // pane/task title, same as windows), so an oracle that never set its window
        // title (pane says only "✳ Claude Code") is still findable.
        let liveTitles = Set(fleet.map { $0.title.lowercased() })
        let ghostMatches = ghosts
            .filter { g in
                // on-screen already (window titled with either name form) → no ghost row
                if liveTitles.contains(g.oracle.lowercased()) { return false }
                if let alt = g.alt?.lowercased(), liveTitles.contains(alt) { return false }
                return true
            }
            .filter { g in
                if needle.isEmpty { return true }
                let o = g.oracle.lowercased()
                if o.contains(needle) || isSubsequence(needle, of: o) { return true }
                if let alt = g.alt?.lowercased(), alt.contains(needle) || isSubsequence(needle, of: alt) { return true }
                let p = (paneTitles[o] ?? "").lowercased()
                return !p.isEmpty && p.contains(needle)
            }
            .sorted { a, b in
                let (ta, tb) = (ts(ghost: a), ts(ghost: b))
                return ta != tb ? ta > tb : a.oracle.lowercased() < b.oracle.lowercased()
            }
        // Tier 3 — DORMANT catalog oracles (Quicksilver launch tier). Pure in-memory:
        // no exec ever happens per keystroke. Dedup against liveTitles AND ghost
        // names (both stem + alt forms, matched against both entry.name and
        // entry.repo) — the catalog's OWN session/awake fields are stale-prone
        // (exact-name-match only) and must never be trusted for dormancy.
        let ghostNames = Set(ghosts.flatMap { [$0.oracle.lowercased(), $0.alt?.lowercased()].compactMap { $0 } })
        let dormant = OracleCatalog.shared.entries.filter { e in
            let n = e.name.lowercased(), r = (e.repo ?? "").lowercased()
            if liveTitles.contains(n) || (!r.isEmpty && liveTitles.contains(r)) { return false }
            if ghostNames.contains(n) || (!r.isEmpty && ghostNames.contains(r)) { return false }
            return true
        }
        let catMatches: [OracleCatalogEntry]
        if needle.isEmpty {
            catMatches = []   // 200+ rows would drown windows+ghosts; hint still counts them
        } else {
            let hay: (OracleCatalogEntry) -> String = { "\($0.name) \($0.org ?? "")/\($0.repo ?? "")".lowercased() }
            let sub = dormant.filter { hay($0).contains(needle) }
            let fuzzy = dormant.filter { !hay($0).contains(needle) && isSubsequence(needle, of: $0.name.lowercased()) }
            catMatches = (sub + Array(fuzzy.prefix(15))).sorted { a, b in
                // Quicksilver order: recently-USED first, then by use-frequency,
                // then message-recency, then alphabetical.
                let (ua, ub) = (OracleUsage.shared.lastUsed(a.name), OracleUsage.shared.lastUsed(b.name))
                if ua != ub { return ua > ub }
                let (ca, cb) = (OracleUsage.shared.count(a.name), OracleUsage.shared.count(b.name))
                if ca != cb { return ca > cb }
                let (ta, tb) = (recencyTs[a.name.lowercased()] ?? 0, recencyTs[b.name.lowercased()] ?? 0)
                return ta != tb ? ta > tb : a.name.lowercased() < b.name.lowercased()
            }
        }
        rows = winMatches.map(Row.window)
            + ghostMatches.map { Row.ghost(session: $0.session, oracle: $0.oracle) }
            + catMatches.map(Row.catalog)
        table.reloadData()
        if !rows.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        let dormantCount = needle.isEmpty ? dormant.count : catMatches.count
        hint.stringValue = "\(winMatches.count) on screen · \(ghostMatches.count) off-screen 👻 · \(dormantCount) dormant 🗂"
    }

    // Row subtitles render a single line — clip long joined pane titles (matching
    // still uses the FULL string, so nothing becomes unfindable by clipping).
    private static func clip(_ s: String, max: Int = 56) -> String {
        s.count > max ? String(s.prefix(max)) + "…" : s
    }

    private func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.startIndex
        for ch in needle {
            guard let found = hay[it...].firstIndex(of: ch) else { return false }
            it = hay.index(after: found)
        }
        return true
    }

    // A window matches on its title, its on-screen pane/task title (what you
    // SEE), or the FOLDER it works in (where it lives — titles lie, cwd doesn't).
    private func winSubMatch(_ win: YabaiWindow, _ needle: String) -> Bool {
        let t = win.title.lowercased()
        if t.contains(needle) { return true }
        let p = (paneTitles[t] ?? "").lowercased()
        if !p.isEmpty && p.contains(needle) { return true }
        let c = (cwdRepo(win) ?? "").lowercased()
        return !c.isEmpty && c.contains(needle)
    }

    private func winFuzzyMatch(_ win: YabaiWindow, _ needle: String) -> Bool {
        if winSubMatch(win, needle) { return false }
        let t = win.title.lowercased()
        if isSubsequence(needle, of: t) { return true }
        let p = (paneTitles[t] ?? "").lowercased()
        if !p.isEmpty && isSubsequence(needle, of: p) { return true }
        let c = (cwdRepo(win) ?? "").lowercased()
        return !c.isEmpty && isSubsequence(needle, of: c)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(field.stringValue)
    }

    // Arrow keys navigate the list; Enter acts; Esc closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            table.selectRowIndexes([min(table.selectedRow + 1, rows.count - 1)], byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
            return true
        case #selector(NSResponder.moveUp(_:)):
            table.selectRowIndexes([max(table.selectedRow - 1, 0)], byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Enter = bring (or jump if opened via ⌃⌥⌘Space). Modifiers refine it: ⌥Enter
            // = mirror (a 2nd live view), ⌘Enter flips bring↔jump IF AppKit delivers it
            // (often it doesn't — hence the dedicated JUMP hotkey). ⌥Enter usually
            // arrives as insertNewlineIgnoringFieldEditor (below); the .option check
            // here is a belt-and-suspenders in case it comes through as plain newline.
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            if mods.contains(.option) {
                act(onRow: table.selectedRow, action: .mirror)
            } else {
                act(onRow: table.selectedRow, action: (defaultJump != mods.contains(.command)) ? .jump : .bring)
            }
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // ⌥Enter → mirror the selected oracle onto this space (same tmux soul).
            act(onRow: table.selectedRow, action: .mirror)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }

    // Reliable ⌘Enter / ⌥Enter handling — the panel forwards its performKeyEquivalent
    // here so these chords act even though AppKit won't deliver them to the field
    // editor (⌘Return beeps against the empty menu; see KeyablePanel). Returns false
    // for plain Return so the field editor's insertNewline still drives the base action.
    func handleReturnKeyEquivalent(_ event: NSEvent) -> Bool {
        guard panel?.isVisible == true, table.selectedRow >= 0 else { return false }
        guard event.keyCode == 36 || event.keyCode == 76 else { return false } // Return / numpad Enter
        let mods = event.modifierFlags.intersection([.command, .option])
        if mods.contains(.option) {                       // ⌥Enter → mirror
            act(onRow: table.selectedRow, action: .mirror)
            return true
        }
        if mods.contains(.command) {                      // ⌘Enter → flip the base action
            act(onRow: table.selectedRow, action: defaultJump ? .bring : .jump)
            return true
        }
        return false                                      // plain Return → insertNewline
    }

    @objc private func rowDoubleClicked() {
        act(onRow: table.clickedRow, action: .bring)
    }

    // ---- actions: bring here / jump to it / mirror (2nd live view) / open a ghost ----

    private enum Action { case bring, jump, mirror }

    private func act(onRow row: Int, action: Action) {
        guard row >= 0, row < rows.count else { return }
        let target = rows[row]
        let here = Engine.shared.snapshot?.spaces.first(where: { $0.hasFocus })?.index
        // The current display's frame, for centering a brought window (from the
        // same snapshot as `here`, read on main before we hop threads).
        let hereFrame: Frame? = {
            guard let snap = Engine.shared.snapshot,
                  let hereSpace = snap.spaces.first(where: { $0.hasFocus }) else { return nil }
            return snap.displays.first(where: { $0.index == hereSpace.display })?.frame
        }()
        // Resolve the tmux session behind a live-window row (needed for mirror) while
        // still on main — `ghosts` now holds EVERY session, so map window title →
        // oracle name → session. Nil if no session's name matches this window's title.
        let sessionForWindow: String? = {
            guard case .window(let win) = target else { return nil }
            let t = win.title.lowercased()
            return ghosts.first { $0.oracle.lowercased() == t || $0.alt?.lowercased() == t }?.session
        }()
        hide() // panel vanishes instantly — the work runs off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            switch target {
            case .window(let win):
                // BRING = move to this space, then land it CENTERED on this display —
                // a summoned window should appear in front of you, not wherever it sat
                // on its old space (Nat 2026-07-13 "ย้ายมาปุ๊บ จัด center"). Abs move
                // only affects floating windows; m5's spaces are float by default. A
                // window already on this space is just focused — its position is yours.
                func bringHere() {
                    if let here, here != win.space {
                        YabaiClient.moveWindow(id: win.id, toSpace: String(here))
                        if let f = hereFrame {
                            YabaiClient.moveWindowAbs(id: win.id,
                                                      x: f.x + (f.w - win.frame.w) / 2,
                                                      y: f.y + (f.h - win.frame.h) / 2)
                        }
                    }
                    YabaiClient.focusWindow(id: win.id)
                }
                switch action {
                case .jump:
                    YabaiClient.focusWindow(id: win.id) // macOS follows the window to its space
                case .bring:
                    bringHere()
                case .mirror:
                    // A live 2nd view of the SAME tmux soul on this space; the original
                    // window is left untouched. If we can't find its session (window
                    // title doesn't match any session name), fall back to bringing it.
                    if let session = sessionForWindow {
                        SearchPanelController.spawnMirror(session: session)
                    } else {
                        bringHere()
                    }
                }
            case .ghost(let session, let oracle):
                // A ghost has no on-screen window, so every action resolves to "open a
                // view": a WezTerm window attached to the session. Re-embodies a headless
                // oracle, or gives a drivable window onto an attached-untitled one (e.g.
                // to run /login on a fresh, never-logged-in oracle).
                OracleUsage.shared.bump(oracle)
                SearchPanelController.spawnMirror(session: session)
            case .catalog(let entry):
                // Quicksilver "launch": a dormant oracle has no window AND no session,
                // so every action (Enter/⌘Enter/⌥Enter/double-click) = start + attach.
                OracleUsage.shared.bump(entry.name)
                SearchPanelController.wakeAndAttach(entry)
            }
            // no forceRefresh needed — the engine poll self-corrects within ≤3s
        }
    }

    // Spawn a WezTerm window attached to `session` — a 2nd tmux client is a live
    // MIRROR of the same instance (type in either view, both update; same soul, same
    // tmux). window-size=largest keeps the ORIGINAL client full-size: a smaller mirror
    // letterboxes instead of shrinking everyone (Nat 2026-07-13, "instance เดียวกัน,
    // ต้นฉบับไม่ถูกบีบ"). The new window lands on the current space and takes focus itself.
    private static func spawnMirror(session: String) {
        let tmux = "/opt/homebrew/bin/tmux"
        let sized = Process()
        sized.executableURL = URL(fileURLWithPath: tmux)
        sized.arguments = ["-S", tmuxSocket, "set-option", "-t", session, "window-size", "largest"]
        sized.standardOutput = Pipe(); sized.standardError = Pipe()
        try? sized.run(); sized.waitUntilExit()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/wezterm")
        proc.arguments = ["cli", "spawn", "--new-window", "--", tmux, "-S", tmuxSocket, "attach", "-t", session]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
    }

    // Wake a DORMANT catalog oracle, then attach a WezTerm window to it — the
    // Quicksilver launch action. `maw wake <name> --no-attach` (verified via
    // --dry-run: line-timeline → session '09-line-timeline', window 'line-timeline');
    // --attach is avoided because this Process has no TTY. runMaw supplies the
    // launchd-safe PATH/locale env. Called off-main (inside act's async block) —
    // maw wake spawns a claude session and can take seconds.
    private static func wakeAndAttach(_ entry: OracleCatalogEntry) {
        guard runMaw(["wake", entry.name, "--no-attach"]) != nil else {
            // maw unavailable/failed → fall back to opening the repo folder
            if let path = entry.localPath {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = [path]
                try? p.run()
            }
            FileHandle.standardError.write("search: wake \(entry.name) FAILED → open fallback\n".data(using: .utf8)!)
            return
        }
        // NN prefix is maw-assigned — re-resolve the real session name from maw ls.
        func resolveSession() -> String? {
            guard let data = runMaw(["ls", "--json"]),
                  let parsed = try? JSONDecoder().decode(MawLs.self, from: data) else { return nil }
            return parsed.sessions?.first {
                $0.session.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression) == entry.name
            }?.session
        }
        var session = resolveSession()
        if session == nil { Thread.sleep(forTimeInterval: 1.0); session = resolveSession() }  // wake may register late
        if let session { spawnMirror(session: session) }   // WezTerm window on current space
        OracleCatalog.shared.refreshAsync()                // it's not dormant anymore
    }

    // ---- table ----

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // Spotlight-style row: name + task flow together on the LEFT (related info
    // stays adjacent — a strict 3-column grid read WORSE: a dominant repetitive
    // middle column and a void after short names; Nat 2026-07-13). The location
    // is a dim RIGHT-ALIGNED column, so the one field that benefits from
    // alignment gets it, at the edge, out of the reading flow.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let name: NSTextField
        let whereStr: String
        var task = ""
        var taskIsHint = false
        switch rows[row] {
        case .window(let win):
            name = NSTextField(labelWithString: win.title)
            name.textColor = .labelColor
            let space = spacesByIndex[win.space]
            whereStr = space != nil ? "space \(win.space) · display \(space!.display)" : "space \(win.space)"
            // The on-screen task label, when it adds info beyond the title —
            // it's what the eye reads and what search matches.
            let pane = SearchPanelController.clip(paneTitles[win.title.lowercased()] ?? "")
            let paneClean = pane.trimmingCharacters(in: CharacterSet(charactersIn: "✳✻✽✺✷*… ").union(.whitespaces))
            if !paneClean.isEmpty && paneClean.lowercased() != win.title.lowercased() { task = pane }
            // Show the working folder when it says something the title doesn't —
            // the "3d-space-travel-visualizer working in display-census/" case.
            if let repo = cwdRepo(win),
               !SearchPanelController.normTitle(win.title).contains(repo.lowercased()) {
                task = task.isEmpty ? "📁 \(repo)" : task + " · 📁 \(repo)"
            }
        case .ghost(let session, let oracle):
            name = NSTextField(labelWithString: "👻 \(oracle)")
            name.textColor = .systemOrange
            whereStr = session
            let pane = SearchPanelController.clip(paneTitles[oracle.lowercased()] ?? "")
            task = pane.isEmpty ? "Enter to open a window" : pane
            taskIsHint = pane.isEmpty
        case .catalog(let e):
            let used = OracleUsage.shared.count(e.name)                    // frequency counter
            name = NSTextField(labelWithString: "🗂 \(e.name)" + (used > 0 ? "  ·  \(used)×" : ""))
            name.textColor = .tertiaryLabelColor              // dim — not running
            whereStr = (e.org != nil && e.repo != nil) ? "\(e.org!)/\(e.repo!)" : (e.localPath ?? "")
            task = used > 0 ? "used \(used)× · Enter to wake" : "Enter to wake + attach"
            taskIsHint = true
        }
        name.font = .systemFont(ofSize: 14, weight: .medium)

        let whereLabel = NSTextField(labelWithString: whereStr)
        whereLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        whereLabel.textColor = .tertiaryLabelColor
        whereLabel.alignment = .right

        let taskLabel = NSTextField(labelWithString: task)
        taskLabel.font = .systemFont(ofSize: 11)
        taskLabel.textColor = taskIsHint ? .tertiaryLabelColor : .secondaryLabelColor

        for l in [name, whereLabel, taskLabel] {
            l.maximumNumberOfLines = 1
            l.lineBreakMode = .byTruncatingTail
            l.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(l)
            l.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        }
        // The location never truncates and never stretches; the task yields first.
        whereLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        whereLabel.setContentHuggingPriority(.required, for: .horizontal)
        taskLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            taskLabel.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            taskLabel.trailingAnchor.constraint(lessThanOrEqualTo: whereLabel.leadingAnchor, constant: -12),
            whereLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])
        return cell
    }
}
