import Foundation

// Swift port of lib/who.ts — the FROZEN /api/who v1.4 contract. census polls it
// at 1 Hz and republishes it PUBLICLY: field names, nesting, and the idle privacy
// clamp are load-bearing. Wire key order matches the TS return literal:
// ts, fleet, windows, displays, spaces, profile, idle.
public enum Who {
    public static let shells: Set<String> = ["zsh", "sh", "-zsh", "bash", "-bash"]

    public static func report(snapshot s: Arranger.SnapshotData) -> JSON {
        let names = Displays.names()
        let pins = Pins.load()

        func windowDisplay(_ w: YabaiWindow) -> Int? {
            w.display ?? s.displays.first { $0.spaces.contains(w.space) }?.index
        }
        func displayName(forIndex idx: Int) -> String? {
            guard let d = s.displays.first(where: { $0.index == idx }) else { return nil }
            return names[String(d.id)] ?? "display \(d.index)"
        }

        // fleet — WezTerm roster.
        struct FleetSeed {
            let title: String; let id: Int; let display: Int; let space: Int; let focus: Bool
        }
        let fleetSeeds: [FleetSeed] = s.windows.compactMap { w in
            guard w.app == "WezTerm" else { return nil }
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let disp = windowDisplay(w) else { return nil }
            return FleetSeed(title: title, id: w.id, display: disp, space: w.space, focus: w.hasFocus)
        }
        var dupCount: [String: Int] = [:]
        for f in fleetSeeds { dupCount[f.title.lowercased(), default: 0] += 1 }
        let fleet: [JSON] = fleetSeeds.map { f in
            .obj([
                ("title", .s(f.title)),
                ("app", .s("WezTerm")),
                ("id", .i(f.id)),
                ("display", .i(f.display)),
                ("space", .i(f.space)),
                ("focus", .b(f.focus)),
                ("dup", .i(dupCount[f.title.lowercased()] ?? 1)),
                ("displayName", displayName(forIndex: f.display).map(JSON.s) ?? .null),
                ("isShell", .b(shells.contains(f.title.lowercased()))),
            ])
        }

        // windows — the v1.2 mini-map: all apps, all spaces, real frames only.
        let windows: [JSON] = s.windows.compactMap { w in
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let disp = windowDisplay(w),
                  w.frame.w >= 80, w.frame.h >= 60 else { return nil }
            let pinned = pins.contains { Pins.matches(w, $0) }
            let idleOnly = pins.contains { $0.whenIdleOnly && Pins.matches(w, $0) }
            return .obj([
                ("id", .i(w.id)),
                ("app", .s(w.app)),
                ("title", .s(title)),
                ("space", .i(w.space)),
                ("display", .i(disp)),
                ("focus", .b(w.hasFocus)),
                ("pinned", .b(pinned)),
                ("whenIdleOnly", .b(idleOnly)),
                ("frame", .obj([("x", .n(w.frame.x)), ("y", .n(w.frame.y)),
                                ("w", .n(w.frame.w)), ("h", .n(w.frame.h))])),
            ])
        }

        let displays: [JSON] = s.displays.map { d in
            .obj([
                ("index", .i(d.index)),
                ("name", .s(names[String(d.id)] ?? "display \(d.index)")),
                ("frame", .obj([("x", .n(d.frame.x)), ("y", .n(d.frame.y)),
                                ("w", .n(d.frame.w)), ("h", .n(d.frame.h))])),
            ])
        }

        let spaces: [JSON] = s.spaces.map { sp in
            let pinned = pins.contains { p in
                p.space == sp.index || (p.label != nil && p.label == sp.label)
            }
            return .obj([
                ("index", .i(sp.index)),
                ("display", .i(sp.display)),
                ("isVisible", .b(sp.isVisible)),
                ("hasFocus", .b(sp.hasFocus)),
                ("pinned", .b(pinned)),
            ])
        }

        let profile = profileStatus(fleetSeeds: fleetSeeds.map { ($0.title, $0.space) },
                                    spaces: s.spaces, pins: pins)

        // idle — privacy-clamped for the public wall: 10s grain, capped at the
        // threshold (a live "seconds since Nat touched input" is a burglar clock).
        // `armed` uses the TRUE unclamped value.
        let idleSecs = Idle.effectiveSeconds()
        let clamped: JSON = idleSecs.map { .n(min(Idle.thresholdSec, ($0 / 10).rounded(.down) * 10)) } ?? .null
        let armed = idleSecs != nil && idleSecs! >= Idle.thresholdSec
            && pins.contains { $0.whenIdleOnly }
        let idle: JSON = .obj([
            ("seconds", clamped),
            ("threshold", .n(Idle.thresholdSec)),
            ("visibleThreshold", .n(Idle.thresholdSec * Idle.visibleMultiplier)),
            ("armed", .b(armed)),
        ])

        return .obj([
            ("ts", .n(s.ts)),
            ("fleet", .arr(fleet)),
            ("windows", .arr(windows)),
            ("displays", .arr(displays)),
            ("spaces", .arr(spaces)),
            ("profile", profile),
            ("idle", idle),
        ])
    }

    // {stale, reason?} | null. Two stale signals, reasons joined with "; ":
    // lost pin labels (synthetic ⭐ ones excluded) and ≥2 oracles off their profile
    // space (one drifter is tolerated — it's indistinguishable from an intent).
    static func profileStatus(fleetSeeds: [(title: String, space: Int)],
                              spaces: [YabaiSpace], pins: [PinRule]) -> JSON {
        let profile = OracleProfile.load()
        guard !profile.isEmpty else { return .null }
        var reasons: [String] = []

        let liveLabels = Set(spaces.compactMap { $0.label }.filter { !$0.isEmpty })
        let lost = pins.compactMap { $0.label }
            .filter { !liveLabels.contains($0) && !Pins.isSyntheticLabel($0) }
        var seenLost = Set<String>()
        let uniqueLost = lost.filter { seenLost.insert($0).inserted }
        if !uniqueLost.isEmpty {
            reasons.append("pin label(s) lost after reboot: \(uniqueLost.joined(separator: ", "))")
        }

        var mismatched = 0
        for f in fleetSeeds where !shells.contains(f.title.lowercased()) {
            let t = f.title.lowercased()
            // Oracle titles are single tokens (repo names); a spaced title is a
            // status pane ("2 awaiting input · claude agents", "Copy mode: …")
            // whose substring can steal a real rule (…awai-TING…) and fake a drift.
            if t.contains(" ") { continue }
            guard let rule = profile.first(where: { r in
                let m = r.match.lowercased()
                // JS includes("") is true — Pins.has replicates that.
                return Pins.has(t, m) || Pins.has(m, t)
            }), let want = rule.space else { continue }
            if want != f.space { mismatched += 1 }
        }
        if mismatched >= 2 {
            reasons.append("\(mismatched) oracle(s) off their profile space (likely space renumber)")
        }

        if reasons.isEmpty { return .obj([("stale", .b(false))]) }
        return .obj([("stale", .b(true)), ("reason", .s(reasons.joined(separator: "; ")))])
    }
}
