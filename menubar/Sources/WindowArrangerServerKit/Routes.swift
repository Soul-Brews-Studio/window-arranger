import Foundation
import CoreGraphics
import WindowArrangerCore

// The full server.ts route surface, ported per the map-server-port-spec workflow.
// Contracts preserved: loopback-only POSTs (fail closed), X-Arrange-Source
// public-queue allowlist + remote-control.off kill-switch + audit.jsonl, the
// never-500 rule for census-button routes (focus/park/arrange-profile), and the
// beginWrite/forceRefresh/endWrite bracket on every window-mutating route.
enum Routes {
    static let confDir = WAEnv.home
        .appendingPathComponent(".config/window-arranger-oracle")
    static var remoteOffPath: String { confDir.appendingPathComponent("remote-control.off").path }
    static var auditPath: String { confDir.appendingPathComponent("audit.jsonl").path }

    // Repo root — used to locate public/index.html for /legacy.
    // Defaults to the current working directory rather than a literal checkout
    // path, which was only ever correct on one machine. Set WA_ROOT to override.
    static let repoRoot = ProcessInfo.processInfo.environment["WA_ROOT"]
        ?? FileManager.default.currentDirectoryPath

    // Shadow mode: background loops off, publishDisplayMap suppressed — two
    // arrangers must never both enforce pins or double-publish while the Bun
    // server is still authoritative on :8900.
    static var shadowMode = false

    static func publicAllowed(_ path: String) -> Bool {
        if path == "/api/arrange-profile" || path == "/api/snapshot-profile" || path == "/api/park" {
            return true
        }
        let parts = path.split(separator: "/").map(String.init)
        // /api/space/<digits>/(apply|focus) — digits ONLY, like Bun's /\d+/;
        // Int() also parses "+5"/"-3", which the allowlist must reject.
        return parts.count == 4 && parts[0] == "api" && parts[1] == "space"
            && !parts[2].isEmpty && parts[2].allSatisfy { $0.isASCII && $0.isNumber }
            && (parts[3] == "apply" || parts[3] == "focus")
    }

    // JS Date.toISOString() always carries milliseconds — census greps audit
    // lines across both servers, so keep the stamp format identical.
    static let auditTS: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let auditLock = NSLock()

    static func audit(path: String, source: String, blocked: String?) {
        var entry: [(String, JSON)] = [
            ("ts", .s(auditTS.string(from: Date()))),
            ("path", .s(path)),
            ("source", .s(source)),
            ("allowed", .b(blocked == nil)),
        ]
        if let blocked { entry.append(("blocked", .s(blocked))) }
        let line = JSON.obj(entry).encoded() + "\n"
        // Audit must never take the write path down; the lock keeps concurrent
        // POSTs from interleaving/clobbering each other's appends.
        auditLock.lock(); defer { auditLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: auditPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: URL(fileURLWithPath: auditPath))
        }
    }

    /// Optional display-map publisher. OPT-IN via `WA_DISPLAY_MAP_PUBLISH`; unset
    /// means off and nothing is spawned.
    ///
    /// Previously this hardcoded an absolute path to one person's bun install and
    /// a script inside a private repo, so on any other machine it spawned a
    /// nonexistent binary every 60s with output discarded. `bun` is now resolved
    /// through PATH via /usr/bin/env rather than an absolute home directory.
    static func publishDisplayMap() {
        guard !shadowMode else { return }
        guard let script = ProcessInfo.processInfo.environment["WA_DISPLAY_MAP_PUBLISH"],
              !script.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["bun", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run() // fire-and-forget
    }

    static func err(_ message: String, status: Int) -> HTTPResponse {
        .json(JSONish(jsonText: JSON.obj([("error", .s(message))]).encoded()), status: status)
    }

    static func body(_ req: HTTPRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
    }

    // --- entry point ---------------------------------------------------------

    static func handle(_ req: HTTPRequest) -> HTTPResponse {
        // Resolve the route FIRST: Elysia's onBeforeHandle never runs for
        // unmatched paths, so an unknown POST must 404 without the guard, an
        // allowlist check, or an audit line.
        guard let route = resolve(req) else {
            return HTTPResponse(status: 404, contentType: "text/plain", body: Data("NOT_FOUND".utf8))
        }

        // Global POST guard (GETs have none, matching server.ts).
        if req.method == "POST" {
            guard req.remoteIsLoopback else {
                return err("writes are loopback-only (run this from the machine itself)", status: 403)
            }
            let source = req.headers["x-arrange-source"] ?? "local"
            var blocked: String?
            if source == "public-queue" {
                if FileManager.default.fileExists(atPath: remoteOffPath) {
                    blocked = "remoteControl is off (remove remote-control.off to re-enable)"
                } else if !publicAllowed(req.path) {
                    blocked = "action not in the phase-1 public allowlist"
                }
                if blocked == nil { Idle.noteRemoteHumanAction() } // iPad command = human driving
            }
            audit(path: req.path, source: source, blocked: blocked)
            if let blocked { return err(blocked, status: 403) }
        }

        return route()
    }

    static func resolve(_ req: HTTPRequest) -> (() -> HTTPResponse)? {
        let parts = req.path.split(separator: "/").map(String.init)
        switch (req.method, req.path) {
        case ("GET", "/"): return { signpost() }
        case ("GET", "/legacy"): return { legacy() }
        case ("GET", "/api/state"): return { state() }
        case ("GET", "/api/who"): return { who() }
        case ("GET", "/api/pins"): return { pinsStatus() }
        case ("POST", "/api/pins/toggle"): return { pinsToggle() }
        case ("POST", "/api/park"): return { park() }
        case ("POST", "/api/gather-to-main"): return { gatherToMain() }
        case ("POST", "/api/refresh-displays"): return { refreshDisplays() }
        case ("POST", "/api/snapshot-profile"): return { snapshotProfile() }
        case ("POST", "/api/arrange-profile"): return { arrangeProfile() }
        case ("GET", "/api/auto-heal"): return { autoHealStatus() }
        case ("POST", "/api/auto-heal/toggle"): return { autoHealToggle() }
        case ("POST", "/api/heal"): return { heal() }
        default: break
        }
        // Parameterized: /api/preview/:space, /api/current/:space, /api/space/:space/*
        if parts.count == 3, parts[0] == "api", parts[1] == "preview", req.method == "GET" {
            return { preview(spaceRaw: parts[2], query: req.query) }
        }
        if parts.count == 3, parts[0] == "api", parts[1] == "current", req.method == "GET" {
            return { current(spaceRaw: parts[2]) }
        }
        if parts.count == 4, parts[0] == "api", parts[1] == "space", req.method == "POST",
           let space = Int(parts[2]) {
            switch parts[3] {
            case "apply": return { apply(space: space, body: body(req)) }
            case "focus": return { focus(space: space, body: body(req)) }
            case "layout": return { layoutRoute(space: space, body: body(req)) }
            case "pin": return { spacePin(space: space, body: body(req)) }
            default: break
            }
        }
        return nil
    }

    // --- reads ---------------------------------------------------------------

    static func state() -> HTTPResponse {
        guard let s = ServerEngine.shared.current() else { return err("no snapshot", status: 500) }
        // Raw yabai passthrough with `name` appended to each display object.
        // Splice at the TEXT level: a dictionary round-trip would keep the
        // unmodeled fields but scramble yabai's key order (caught by the
        // conformance suite — TS preserves insertion order).
        let names = Displays.names()
        let displaysText = String(data: s.rawDisplays, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "[]"
        let spacesText = String(data: s.rawSpaces, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "[]"
        let out = JSON.obj([
            ("displays", .raw(spliceNames(displaysText, names: names))),
            ("spaces", .raw(spacesText)),
        ])
        return .json(JSONish(jsonText: out.encoded()))
    }

    // Insert `"name": …` as the last field of every top-level object in a raw
    // JSON array, leaving all other bytes untouched.
    static func spliceNames(_ raw: String, names: [String: String]) -> String {
        let chars = Array(raw)
        var out = ""
        out.reserveCapacity(raw.count + 64)
        var i = 0, depth = 0, objStart = -1
        var inString = false, escape = false
        while i < chars.count {
            let ch = chars[i]
            if inString {
                if escape { escape = false }
                else if ch == "\\" { escape = true }
                else if ch == "\"" { inString = false }
            } else {
                switch ch {
                case "\"": inString = true
                case "{", "[":
                    if depth == 1 && ch == "{" && objStart < 0 { objStart = i }
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 1 && ch == "}" && objStart >= 0 {
                        let objText = String(chars[objStart...i])
                        let id = (try? JSONSerialization.jsonObject(with: Data(objText.utf8)) as? [String: Any])
                            .flatMap { obj -> String? in
                                if let v = obj?["id"] as? Int { return String(v) }
                                if let v = obj?["id"] as? Double { return String(Int(v)) }
                                return nil
                            }
                        let nameJSON = id.flatMap { names[$0] }.map { JSON.s($0).encoded() } ?? "null"
                        out.append(String(chars[objStart..<i]))
                        out.append(",\"name\":\(nameJSON)}")
                        objStart = -1
                        i += 1
                        continue
                    }
                default: break
                }
            }
            if objStart < 0 { out.append(ch) }
            i += 1
        }
        return out
    }

    static func who() -> HTTPResponse {
        guard let s = ServerEngine.shared.current() else { return err("no snapshot", status: 500) }
        return .json(JSONish(jsonText: Who.report(snapshot: s.typed).encoded()))
    }

    static func preview(spaceRaw: String, query: [String: String]) -> HTTPResponse {
        guard let s = ServerEngine.shared.current(), let space = Int(spaceRaw) else {
            return err("bad space", status: 500)
        }
        let mode = Arranger.parseMode(query["mode"])
        let active = query["active"] == "1" || query["active"] == "true"
        do {
            let svg = try Arranger.renderPreviewSVG(snapshot: s.typed, spaceIndex: space,
                                                    mode: mode, activeFirst: active)
            return HTTPResponse(contentType: "image/svg+xml", body: Data(svg.utf8))
        } catch {
            return err(String(describing: error), status: 500)
        }
    }

    static func current(spaceRaw: String) -> HTTPResponse {
        guard let s = ServerEngine.shared.current(), let space = Int(spaceRaw) else {
            return err("bad space", status: 500)
        }
        do {
            let svg = try Arranger.renderCurrentSVG(snapshot: s.typed, spaceIndex: space)
            return HTTPResponse(contentType: "image/svg+xml", body: Data(svg.utf8))
        } catch {
            return err(String(describing: error), status: 500)
        }
    }

    static func pinsStatus() -> HTTPResponse {
        .json(JSONish(jsonText: JSON.obj([
            ("enabled", .b(Pins.enabled())),
            ("rules", .i(Pins.ruleCount())),
        ]).encoded()))
    }

    // --- writes --------------------------------------------------------------

    static func apply(space: Int, body: [String: Any]) -> HTTPResponse {
        let mode = Arranger.parseMode(body["mode"] as? String)
        let activeFirst = (body["activeFirst"] as? Bool) == true
        // Fresh sample at write time — Bun re-queries yabai live for every write;
        // a ≤1.5s-stale cache would move windows to frames they've already left.
        guard let s = ServerEngine.shared.forceRefresh() else { return err("no snapshot", status: 500) }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite(); publishDisplayMap() }
        do {
            let moved = try Arranger.applyLayout(snapshot: s.typed, spaceIndex: space,
                                                 mode: mode, activeFirst: activeFirst)
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(true)), ("space", .i(space)), ("mode", .s(mode.rawValue)),
                ("activeFirst", .b(activeFirst)), ("moved", .i(moved)),
            ]).encoded()))
        } catch {
            return err(String(describing: error), status: 500)
        }
    }

    static func focus(space: Int, body: [String: Any]) -> HTTPResponse {
        let keepMouse = (body["keepMouse"] as? Bool) == true
        // Never 500 — census's iPad button gets an honest {ok:false} instead
        // (yabai's rapid-fire "mission-control is active" no-op is real and
        // common; reporting it as success would lie to the button).
        let pos: CGPoint? = keepMouse ? CGEvent(source: nil)?.location : nil
        defer {
            if let pos {
                CGWarpMouseCursorPosition(pos)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
                    CGWarpMouseCursorPosition(pos) // switch animation can re-warp
                }
            }
        }
        if let failure = YabaiClient.focusSpaceChecked(index: space) {
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(false)), ("space", .i(space)), ("error", .s(failure)),
            ]).encoded()))
        }
        ServerEngine.shared.forceRefresh()
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("space", .i(space)), ("keepMouse", .b(keepMouse)),
        ]).encoded()))
    }

    static func layoutRoute(space: Int, body: [String: Any]) -> HTTPResponse {
        guard body["layout"] as? String == "float" else {
            return err("only float is applied via yabai layout; use /apply for tiling", status: 400)
        }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite() }
        YabaiClient.setLayout(spaceIndex: space, layout: "float")
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("space", .i(space)), ("layout", .s("float")),
        ]).encoded()))
    }

    static func gatherToMain() -> HTTPResponse {
        // Fresh at write time (see apply()).
        guard let s = ServerEngine.shared.forceRefresh() else { return err("no snapshot", status: 500) }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite(); publishDisplayMap() }
        let r = Arranger.gatherToMain(snapshot: s.typed)
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("moved", .i(r.moved)),
            ("mainIndex", .i(r.mainIndex)), ("total", .i(r.total)),
        ]).encoded()))
    }

    static func park() -> HTTPResponse {
        let enabled = Pins.enabled() // read BEFORE the park: "pins off" ≠ "nothing to park"
        guard let s = ServerEngine.shared.forceRefresh() else { // fresh, matching parkAndRetile
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(false)), ("pinsEnabled", .b(enabled)), ("error", .s("no snapshot")),
            ]).encoded()))
        }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite(); publishDisplayMap() }
        let result = Pins.parkNow(windows: s.typed.windows, spaces: s.typed.spaces,
                                  displays: s.typed.displays, names: Displays.names())
        // Re-tile from a POST-park sample — the pre-park snapshot still lists the
        // parked window on its source space, so retiling from it would lay out
        // around a phantom leaf (gap never fills) or drag the window right back
        // (the exact bug lib/park.ts re-queries live to avoid).
        var retiled: [Int] = []
        if !result.movedFrom.isEmpty, let fresh = ServerEngine.shared.forceRefresh() {
            for space in Set(result.movedFrom).sorted() {
                Arranger.retileSpace(snapshot: fresh.typed, spaceIndex: space)
                retiled.append(space)
            }
        }
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("pinsEnabled", .b(enabled)),
            ("moved", .arr(result.moved.map(JSON.s))),
            ("retiled", .arr(retiled.map(JSON.i))),
        ]).encoded()))
    }

    static func pinsToggle() -> HTTPResponse {
        let newState = Pins.setEnabled(!Pins.enabled())
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("enabled", .b(newState)), ("rules", .i(Pins.ruleCount())),
        ]).encoded()))
    }

    // 🩹 auto-heal manual + toggle (Nat 2026-07-17: "just disable but have a button
    // to do it manually"). The 60s loop is gated on auto-heal.off; these read/flip
    // that flag and fire a one-shot heal on demand (works even while auto is off).
    static func autoHealStatus() -> HTTPResponse {
        .json(JSONish(jsonText: JSON.obj([("enabled", .b(Pins.autoHealEnabled()))]).encoded()))
    }
    static func autoHealToggle() -> HTTPResponse {
        let newState = Pins.setAutoHeal(!Pins.autoHealEnabled())
        return .json(JSONish(jsonText: JSON.obj([("ok", .b(true)), ("enabled", .b(newState))]).encoded()))
    }
    static func heal() -> HTTPResponse {
        guard let s = ServerEngine.shared.forceRefresh() ?? ServerEngine.shared.current() else { return err("no snapshot", status: 500) }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite(); publishDisplayMap() }
        Pins.autoHeal(windows: s.typed.windows, spaces: s.typed.spaces)
        return .json(JSONish(jsonText: JSON.obj([("ok", .b(true))]).encoded()))
    }

    static func spacePin(space: Int, body: [String: Any]) -> HTTPResponse {
        guard let s = ServerEngine.shared.current() else { return err("no snapshot", status: 500) }
        guard let sp = s.typed.spaces.first(where: { $0.index == space }) else {
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(false)), ("error", .s("no space with index \(space)")),
            ]).encoded()), status: 400)
        }
        let pinned = (body["pinned"] as? Bool) == true
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite() }
        var label = (sp.label ?? "").trimmingCharacters(in: .whitespaces)
        if pinned, label.isEmpty {
            label = Pins.synthLabelPrefix + String(space)
            YabaiClient.labelSpace(index: space, label: label)
        }
        let windows = s.typed.windows.filter { $0.space == space }
        let count = Pins.setSpacePin(label: label, windows: windows, pinned: pinned)
        if !pinned, Pins.isSyntheticLabel(label) {
            YabaiClient.labelSpace(index: space, label: "")
        }
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("space", .i(space)), ("pinned", .b(pinned)),
            ("count", .i(count)), ("pinsEnabled", .b(Pins.enabled())),
        ]).encoded()))
    }

    static func refreshDisplays() -> HTTPResponse {
        do {
            let names = try Displays.refresh()
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(true)),
                ("config", .s(Displays.configPath)),
                ("names", .obj(names.sorted { $0.key < $1.key }.map { ($0.key, JSON.s($0.value)) })),
            ]).encoded()))
        } catch {
            return err(String(describing: error), status: 500)
        }
    }

    static func snapshotProfile() -> HTTPResponse {
        // The saved rules become tomorrow's targets — read at write-grade
        // freshness (same standard as apply/gather), not the ≤1.5s poll cache.
        guard let s = ServerEngine.shared.forceRefresh() ?? ServerEngine.shared.current() else { return err("no snapshot", status: 500) }
        var seen = Set<String>()
        var rules: [OracleRule] = []
        for w in s.typed.windows where w.app == "WezTerm" {
            let title = w.title.trimmingCharacters(in: .whitespaces)
            let key = title.lowercased()
            if title.isEmpty || Who.shells.contains(key) || seen.contains(key) { continue }
            // Oracle titles are single tokens (repo names); a spaced title is a
            // status pane ("2 awaiting input · claude agents", "Copy mode: …") —
            // saving it as a rule lets its substring steal a real oracle's match.
            if title.contains(" ") { continue }
            seen.insert(key)
            rules.append(OracleRule(match: title, display: nil, space: w.space, label: nil, grid: nil))
        }
        do {
            let backup = try OracleProfile.save(rules)
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(true)), ("saved", .i(rules.count)),
                ("backup", backup.map(JSON.s) ?? .null),
            ]).encoded()))
        } catch {
            return err(String(describing: error), status: 500)
        }
    }

    static func arrangeProfile() -> HTTPResponse {
        let profile = OracleProfile.load()
        guard !profile.isEmpty else {
            // Never 500 — census button gets an honest reply, before any write bracket.
            return .json(JSONish(jsonText: JSON.obj([
                ("ok", .b(false)), ("error", .s("no profile saved — snapshot one first")),
            ]).encoded()))
        }
        guard let s = ServerEngine.shared.forceRefresh() else { return err("no snapshot", status: 500) }
        ServerEngine.shared.beginWrite()
        defer { ServerEngine.shared.forceRefresh(); ServerEngine.shared.endWrite(); publishDisplayMap() }
        // Mirrors arrangeByProfile exactly: NO already-there skip — yabai treats
        // a same-place move as a tolerated no-op, `moved` counts every matched
        // window with a target, and a display rule re-applies its --grid every
        // run (that's how a dragged window snaps back on the next arrange).
        // Untitled windows still match by app substring (title is not guarded).
        var matched = 0, moved = 0
        for w in s.typed.windows {
            let title = w.title.lowercased()
            let app = w.app.lowercased()
            guard let rule = profile.first(where: { r in
                let m = r.match.lowercased()
                return Pins.has(title, m) || Pins.has(app, m)
            }) else { continue }
            matched += 1
            switch rule.target {
            case .space(let sel):
                YabaiClient.moveWindow(id: w.id, toSpace: sel)
                moved += 1
            case .display(let d):
                YabaiClient.moveWindow(id: w.id, toDisplay: d)
                if let grid = rule.grid { YabaiClient.setGrid(id: w.id, grid: grid) }
                moved += 1
            case nil:
                continue
            }
        }
        return .json(JSONish(jsonText: JSON.obj([
            ("ok", .b(true)), ("rules", .i(profile.count)),
            ("matched", .i(matched)), ("moved", .i(moved)),
        ]).encoded()))
    }

    // --- static pages --------------------------------------------------------

    static func signpost() -> HTTPResponse {
        let html = """
        <!doctype html><meta charset="utf-8">
        <title>window-arranger → display-census</title>
        <body style="background:#0a0e14;color:#cbd5e1;font-family:ui-monospace,monospace;display:grid;place-items:center;min-height:95vh">
        <div style="max-width:32rem;text-align:center;line-height:1.9">
          <div style="font-size:2.2rem">🎭 → 👁️</div>
          <p>UI ย้ายบ้านแล้ว — เว็บเดียวคือ <b>display-census</b><br>(กำลังพาไป…)</p>
          <p><a style="color:#8fd3ff" href="http://localhost:8899/">localhost:8899 (local, เร็ว)</a> ·
             <a style="color:#8fd3ff" href="/legacy">this server's UI</a></p>
          <p style="color:#64748b;font-size:.85rem">หน้าเดิมยังอยู่ที่ <a style="color:#94a3b8" href="/legacy">/legacy</a> (break-glass ตอนเน็ตล่ม) · API :8900 ทำงานปกติ</p>
        </div>
        <script>
          // prefer the local census view when it answers; fall back to the public URL.
          // no-cors: an opaque response still proves the server is up (CORS headers
          // aren't needed just to detect reachability), network error = not running.
          fetch("http://localhost:8899/api/state",{mode:"no-cors",signal:AbortSignal.timeout(1200)})
            .then(()=>location.replace("http://localhost:8899/"))
            .catch(()=>location.replace("/legacy"));
        </script></body>
        """
        var resp = HTTPResponse(contentType: "text/html", body: Data(html.utf8))
        resp.extraHeaders.append(("Cache-Control", "no-store"))
        return resp
    }

    static func legacy() -> HTTPResponse {
        let path = repoRoot + "/public/index.html"
        guard let data = FileManager.default.contents(atPath: path) else {
            return HTTPResponse(status: 404, contentType: "text/plain", body: Data("legacy UI not found".utf8))
        }
        var resp = HTTPResponse(contentType: "text/html", body: data)
        resp.extraHeaders.append(("Cache-Control", "no-store"))
        return resp
    }
}
