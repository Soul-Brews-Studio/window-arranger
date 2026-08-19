import Foundation

// Swift port of lib/oracle-profile.ts's pin system: 📌 continuously-enforced
// routing rules in ~/.config/window-arranger-oracle/pins.json.
//
// Rules are kept as raw JSON dictionaries (PinRule wraps one) so unknown fields
// (`note`, future keys) survive the two rewrite paths (space-pin, auto-heal).
// pins.json is hand-edited live — re-read EVERY tick, never cache across ticks.
public struct PinRule {
    public let dict: [String: Any]
    public init(_ dict: [String: Any]) { self.dict = dict }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        return nil
    }

    public var match: String { dict["match"] as? String ?? "" }
    public var app: String? { dict["app"] as? String }
    public var display: Int? { PinRule.int(dict["display"]) }
    public var displayName: String? { dict["displayName"] as? String }
    public var space: Int? { PinRule.int(dict["space"]) }
    public var label: String? { dict["label"] as? String }
    public var grid: String? { dict["grid"] as? String }
    public var whenIdleOnly: Bool { dict["whenIdleOnly"] as? Bool ?? false }
    public var origin: String? { dict["origin"] as? String }
}

public enum Pins {
    // Serializes every pins/profile file mutation. Bun is single-threaded by
    // runtime; here setSpacePin (HTTP queue), setEnabled (HTTP queue), and
    // auto-heal (timer queue) would otherwise read-modify-write concurrently
    // and lose each other's updates.
    static let fileLock = NSLock()

    static let confDir = WAEnv.home
        .appendingPathComponent(".config/window-arranger-oracle")
    public static var pinsPath: String { confDir.appendingPathComponent("pins.json").path }
    public static var pinsOffPath: String { confDir.appendingPathComponent("pins.json.off").path }
    // touch = stop the 60s auto-heal loop (Nat 2026-07-17: "just disable but have
    // a button to do it manually"). Manual 🩹 heal + ♻️ restore still work when set.
    public static var autoHealOffPath: String { confDir.appendingPathComponent("auto-heal.off").path }
    public static func autoHealEnabled() -> Bool { !FileManager.default.fileExists(atPath: autoHealOffPath) }
    @discardableResult
    public static func setAutoHeal(_ on: Bool) -> Bool {
        let fm = FileManager.default
        if on { try? fm.removeItem(atPath: autoHealOffPath) }
        else { fm.createFile(atPath: autoHealOffPath, contents: Data(ISO8601DateFormatter().string(from: Date()).utf8)) }
        return autoHealEnabled()
    }

    public static let synthLabelPrefix = "⭐"
    public static func isSyntheticLabel(_ l: String) -> Bool { l.hasPrefix(synthLabelPrefix) }
    public static func spacePinTag(_ label: String) -> String { "space-pin:" + label }

    public static func enabled() -> Bool { FileManager.default.fileExists(atPath: pinsPath) }

    // The file writers (space-pin, auto-heal) target: pins.json when it exists OR
    // when .off doesn't (default to pins.json when neither exists); only .off when
    // pins are toggled off — so toggling never loses rules.
    static func activeFile() -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: pinsPath) || !fm.fileExists(atPath: pinsOffPath) { return pinsPath }
        return pinsOffPath
    }

    // Active rules. Missing file (incl. toggled off) → [] silently — pins genuinely
    // aren't enforced while off. Parse error → [] but LOUD (a syntax error in a
    // hand-edited file must not fail quietly).
    public static func load() -> [PinRule] {
        guard let data = FileManager.default.contents(atPath: pinsPath) else { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            FileHandle.standardError.write(
                "⚠️ pins.json parse error (all pins disabled until fixed)\n".data(using: .utf8)!)
            return []
        }
        return arr.map(PinRule.init)
    }

    // Rule count from whichever file exists — the UI shows it even while disabled.
    public static func ruleCount() -> Int {
        let fm = FileManager.default
        let path = fm.fileExists(atPath: pinsPath) ? pinsPath : pinsOffPath
        guard let data = fm.contents(atPath: path),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return 0 }
        return arr.count
    }

    // Rename pins.json ⇄ pins.json.off. A pre-existing stale .off gets shelved to
    // .off.bak.<stamp> first (Nothing is Deleted). Returns the NEW enabled state.
    @discardableResult
    public static func setEnabled(_ on: Bool) -> Bool {
        fileLock.lock(); defer { fileLock.unlock() }
        let fm = FileManager.default
        if on {
            if !fm.fileExists(atPath: pinsPath), fm.fileExists(atPath: pinsOffPath) {
                try? fm.moveItem(atPath: pinsOffPath, toPath: pinsPath)
            }
        } else if fm.fileExists(atPath: pinsPath) {
            if fm.fileExists(atPath: pinsOffPath) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
                try? fm.moveItem(atPath: pinsOffPath, toPath: pinsOffPath + ".bak." + stamp)
            }
            try? fm.moveItem(atPath: pinsPath, toPath: pinsOffPath)
        }
        return enabled()
    }

    static func write(_ rules: [[String: Any]], to path: String) {
        guard var data = try? JSONSerialization.data(withJSONObject: rules,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        data.append(Data("\n".utf8))
        try? data.write(to: URL(fileURLWithPath: path))
    }

    // --- matching -----------------------------------------------------------

    // NOTE: JS "".includes("") is true — an empty `match` matches every window of
    // the rule's app (all 4 live park rules use match: ""). Swift contains("")
    // is FALSE, so empty needles must short-circuit or no park rule ever fires.
    public static func has(_ haystack: String, _ needle: String) -> Bool {
        needle.isEmpty || haystack.contains(needle)
    }

    public static func matches(_ w: YabaiWindow, _ pin: PinRule) -> Bool {
        // JS trim() strips newlines too — .whitespaces alone doesn't.
        let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let app = pin.app {
            return has(w.app.lowercased(), app.lowercased())
                && has(title.lowercased(), pin.match.lowercased())
        }
        return w.app == "WezTerm" && !title.isEmpty
            && has(title.lowercased(), pin.match.lowercased())
    }

    // --- enforcement --------------------------------------------------------

    public struct EnforceResult {
        public var moved: [String] = []
        public var movedFrom: [Int] = []
    }

    // One pass over (pins × windows). `idle` nil = cannot prove idle → whenIdleOnly
    // pins sit out (fail safe); .infinity = manual-force sentinel (park-now).
    public static func enforce(windows: [YabaiWindow], spaces: [YabaiSpace],
                               displays: [YabaiDisplay], names: [String: String],
                               pins: [PinRule], idle: Double?) -> EnforceResult {
        var result = EnforceResult()
        func idleGateOk(_ pin: PinRule, _ w: YabaiWindow) -> Bool {
            if !pin.whenIdleOnly { return true }
            guard let idle else { return false }
            let visible = spaces.first { $0.index == w.space }?.isVisible ?? false
            let need = Idle.thresholdSec * (visible ? Idle.visibleMultiplier : 1)
            return idle >= need
        }
        for pin in pins {
            // Display pin wins first; space/label ignored on display rules.
            if pin.displayName != nil || pin.display != nil {
                var targetDisp: Int?
                if let wantName = pin.displayName {
                    // Sort by id so two monitors sharing one name resolve the
                    // SAME way every launch (Swift Dictionary order is seeded).
                    if let idEntry = names.sorted(by: { $0.key < $1.key })
                        .first(where: { $0.value == wantName }),
                       let id = Int(idEntry.key),
                       let live = displays.first(where: { $0.id == id }) {
                        targetDisp = live.index
                    }
                } else {
                    targetDisp = pin.display
                }
                guard let disp = targetDisp,
                      displays.contains(where: { $0.index == disp }) else { continue } // never guess
                for w in windows where matches(w, pin) {
                    let from = displays.first { $0.spaces.contains(w.space) }?.index
                    if from == disp { continue } // already home
                    guard idleGateOk(pin, w) else { continue }
                    result.movedFrom.append(w.space) // capture PRE-move (yabai list lag)
                    YabaiClient.moveWindow(id: w.id, toDisplay: disp)
                    if let grid = pin.grid { YabaiClient.setGrid(id: w.id, grid: grid) }
                    result.moved.append("\(w.title.trimmingCharacters(in: .whitespacesAndNewlines)) (d\(from ?? -1)→d\(disp))")
                }
                continue
            }
            // Space pin: label (survives renumbering) > raw index.
            var target: Int?
            if let label = pin.label {
                target = spaces.first { $0.label == label }?.index
            } else {
                target = pin.space
            }
            guard let dst = target, spaces.contains(where: { $0.index == dst }) else { continue }
            for w in windows where matches(w, pin) {
                if w.space == dst { continue }
                guard idleGateOk(pin, w) else { continue }
                result.movedFrom.append(w.space)
                YabaiClient.moveWindow(id: w.id, toSpace: String(dst))
                result.moved.append("\(w.title.trimmingCharacters(in: .whitespacesAndNewlines)) (s\(w.space)→s\(dst))")
            }
        }
        return result
    }

    // Manual 🅿️: whenIdleOnly pins only, idle gate forced open.
    public static func parkNow(windows: [YabaiWindow], spaces: [YabaiSpace],
                               displays: [YabaiDisplay], names: [String: String]) -> EnforceResult {
        let parkPins = load().filter { $0.whenIdleOnly }
        guard !parkPins.isEmpty else { return EnforceResult() }
        return enforce(windows: windows, spaces: spaces, displays: displays,
                       names: names, pins: parkPins, idle: .infinity)
    }

    // --- ⭐ space-pin --------------------------------------------------------

    static let shells: Set<String> = ["zsh", "sh", "-zsh", "bash", "-bash"]

    // Pin: one origin-tagged rule per unique window on the space. Unpin: remove
    // exactly our own origin-tagged rules, never Nat's hand-written ones.
    // Returns the number of rules added (0 on unpin).
    public static func setSpacePin(label: String, windows: [YabaiWindow], pinned: Bool) -> Int {
        fileLock.lock(); defer { fileLock.unlock() }
        let tag = spacePinTag(label)
        let file = activeFile()
        var rest: [[String: Any]] = []
        if let data = FileManager.default.contents(atPath: file),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rest = arr.filter { ($0["origin"] as? String) != tag }
        }
        var added: [[String: Any]] = []
        if pinned {
            var seen = Set<String>()
            for w in windows {
                let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty || shells.contains(title.lowercased()) { continue }
                let key = w.app + "|" + title.lowercased() // TS dedupes case-insensitively
                if seen.contains(key) { continue }
                seen.insert(key)
                var rule: [String: Any] = ["match": title, "label": label, "origin": tag]
                if w.app != "WezTerm" { rule["app"] = w.app }
                added.append(rule)
            }
        }
        write(rest + added, to: file)
        return added.count
    }

    // --- auto-heal (60s tick) -------------------------------------------------
    // Heals only what needs NO intent interpretation; real drift keeps the stale
    // badge for a human to resolve.

    public static func autoHeal(windows: [YabaiWindow], spaces: [YabaiSpace]) {
        healLostLabels(windows: windows, spaces: spaces)
        healPureRenumber(windows: windows, spaces: spaces)
    }

    // (a) Labels die on reboot. A pin's matched windows usually sit ON its space,
    // so if all of them agree on one space, relabel it. whenIdleOnly pins NEVER
    // heal — inverse evidence: their windows sit AWAY from the target by design
    // (Comet lives on the working space, visits 'park' only when idle); healing
    // would relabel the WORKING space as parking and snap the browser into it.
    static func healLostLabels(windows: [YabaiWindow], spaces: [YabaiSpace]) {
        let liveLabels = Set(spaces.compactMap { $0.label }.filter { !$0.isEmpty })
        for pin in load() {
            guard let label = pin.label, !liveLabels.contains(label), !pin.whenIdleOnly else { continue }
            let hits = windows.filter { matches($0, pin) }
            let hitSpaces = Set(hits.map { $0.space })
            guard hitSpaces.count == 1, let home = hitSpaces.first else { continue } // ambiguous → human
            YabaiClient.labelSpace(index: home, label: label)
            FileHandle.standardError.write(
                "🩹 auto-heal: relabeled space \(home) as \"\(label)\"\n".data(using: .utf8)!)
        }
    }

    // (b) Pure-renumber remap: evidence = fleet windows whose title contains a
    // profile rule's match, all agreeing on one live space. Apply only when the
    // mapping is consistent, injective, and ≥2 groups moved (one moved group is
    // indistinguishable from an intentional move). Also shifts raw-index pin rules
    // and rewrites their space-pin origins.
    static func healPureRenumber(windows: [YabaiWindow], spaces: [YabaiSpace]) {
        // Work on the RAW profile dicts, not the typed OracleRule — a struct
        // round-trip would silently drop app/displayName/whenIdleOnly/origin/
        // note and any future keys from Nat's hand-edited file.
        let profilePath = OracleProfile.path
        guard let profileData = FileManager.default.contents(atPath: profilePath),
              let profileRaw = try? JSONSerialization.jsonObject(with: profileData) as? [[String: Any]],
              !profileRaw.isEmpty else { return }
        let fleet = windows.filter {
            $0.app == "WezTerm" && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        var mapping: [Int: Int] = [:]
        for rule in profileRaw {
            guard let saved = PinRule.int(rule["space"]) else { continue }
            let match = (rule["match"] as? String ?? "").lowercased()
            let members = fleet.filter { has($0.title.lowercased(), match) }
            let liveSpaces = Set(members.map { $0.space })
            guard liveSpaces.count == 1, let live = liveSpaces.first else { continue }
            if let prior = mapping[saved], prior != live { return } // split group = real drift
            mapping[saved] = live
        }
        // ≥2 DISTINCT saved-space groups must have moved — one moved group is
        // indistinguishable from an intentional move. (Counting per rule would
        // let two rules on the same space defeat the guard.)
        let movedGroups = mapping.filter { $0.key != $0.value }.count
        guard movedGroups >= 2 else { return }
        let targets = mapping.values
        guard Set(targets).count == targets.count else { return } // must be injective

        fileLock.lock(); defer { fileLock.unlock() }
        // Rewrite the profile through the mapping, unknown keys intact, with a
        // timestamped backup first (Nothing is Deleted — mirrors saveProfile).
        let remapped = profileRaw.map { rule -> [String: Any] in
            var r = rule
            if let s = PinRule.int(r["space"]), let new = mapping[s], new != s { r["space"] = new }
            return r
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
        try? FileManager.default.copyItem(atPath: profilePath, toPath: profilePath + ".bak." + stamp)
        write(remapped, to: profilePath)
        // Shift raw-index pin rules by the same mapping (label pins need none).
        let file = activeFile()
        if let data = FileManager.default.contents(atPath: file),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var changed = false
            let shifted = arr.map { rule -> [String: Any] in
                var r = rule
                if let s = PinRule.int(r["space"]), let new = mapping[s], new != s {
                    r["space"] = new
                    if let origin = r["origin"] as? String, origin.hasPrefix("space-pin:") {
                        r["origin"] = "space-pin:s\(new)"
                    }
                    changed = true
                }
                return r
            }
            if changed { write(shifted, to: file) }
        }
        FileHandle.standardError.write(
            "🩹 auto-heal: remapped \(movedGroups) renumbered space group(s)\n".data(using: .utf8)!)
    }
}
