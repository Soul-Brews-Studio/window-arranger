import Foundation

// Swift port of lib/bsp.ts orderByHumanRecency. Orders windows by "where the
// human is working": the timestamp of the last HUMAN-typed message in each
// oracle's Claude Code session log (~/.claude/projects/<repo>/*.jsonl, tail-
// scanned), with the yabai focused window treated as most-recent.
public enum Recency {
    private static var projectsDir: URL {
        WAEnv.home.appendingPathComponent(".claude/projects")
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static func parseTS(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

    // A WezTerm title like "argus" maps to the repo dir ending in "-argus" or
    // e.g. "-my-project".
    private static func dir(forTitle title: String, dirs: [String]) -> String? {
        let t = title.lowercased().replacingOccurrences(of: " ", with: "-")
        return dirs.first { name in
            let l = name.lowercased()
            return l.hasSuffix("-" + t) || l.hasSuffix("-" + t + "-oracle")
        }
    }

    private static func latestJsonl(inDir dir: URL) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    // The typed text of a "user" entry, or nil (tool results, assistant turns).
    private static func humanText(_ obj: [String: Any]) -> String? {
        guard obj["type"] as? String == "user" else { return nil }
        let content = (obj["message"] as? [String: Any])?["content"]
        if let s = content as? String { return s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
        if let arr = content as? [[String: Any]] {
            if let t = arr.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
               !t.trimmingCharacters(in: .whitespaces).isEmpty { return t }
        }
        return nil
    }

    // Scan only the tail so this stays cheap on multi-MB logs. Returns 0 when
    // nothing in the window passes `accept` — callers choose their fallback.
    private static func lastTypedTime(_ url: URL, window: UInt64 = 65536, accept: (String) -> Bool = { _ in true }) -> Double {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start: UInt64 = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return 0 }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let text = humanText(obj), accept(text),
                  let ts = obj["timestamp"] as? String, let date = parseTS(ts)
            else { continue }
            return date.timeIntervalSince1970
        }
        return 0
    }

    private static func lastHumanTime(_ url: URL) -> Double {
        let t = lastTypedTime(url)
        if t > 0 { return t }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return mtime.timeIntervalSince1970 // no human msg in tail — fall back to mtime
    }

    // ---- "ล่าสุด Nat คุยกับใคร" (Swift twin of scripts/who.ts --last) ----
    // A message only counts as NAT-typed if it isn't oracle-to-oracle traffic or
    // harness injection: maw relays open with a "[host:oracle]"-style header;
    // "/command" invocations inject the skill body and local-command caveats.
    private static let relayHeader = try! NSRegularExpression(pattern: "^\\s*\\[[^\\]\\n]{1,80}\\]")
    private static func isNatTyped(_ t: String) -> Bool {
        if t.hasPrefix("Base directory for this skill") || t.hasPrefix("<local-command") { return false }
        let probe = String(t.prefix(120)) // header is at the very start — no need to range the whole text
        return relayHeader.firstMatch(in: probe, range: NSRange(probe.startIndex..., in: probe)) == nil
    }

    public struct LastTalk { public let window: YabaiWindow; public let time: Double }

    // Unique fleet oracles ordered by when Nat last actually typed to them.
    // 256KB tail: relay bursts can bury Nat's real message deeper than 64KB.
    public static func lastTalkedTo(_ windows: [YabaiWindow], limit: Int = 5) -> [LastTalk] {
        let shells: Set<String> = ["zsh", "sh", "-zsh", "bash", "-bash"]
        let base = projectsDir
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        var seen = Set<String>()
        var out: [LastTalk] = []
        for w in windows where w.app == "WezTerm" {
            let title = w.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = title.lowercased()
            if title.isEmpty || shells.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            guard let d = dir(forTitle: title, dirs: dirs),
                  let jsonl = latestJsonl(inDir: base.appendingPathComponent(d)) else { continue }
            let t = lastTypedTime(jsonl, window: 262144, accept: isNatTyped)
            if t > 0 { out.append(LastTalk(window: w, time: t)) }
        }
        return Array(out.sorted { $0.time > $1.time }.prefix(limit))
    }

    // Batch "when did Nat last type to <name>" lookups — feeds the search
    // palette's recent-on-top ordering. Keys echo the input names verbatim
    // (the caller picks its normalization); 0 = unknown (no repo dir/jsonl),
    // which sorts to the bottom.
    public static func lastHumanTimes(names: [String]) -> [String: Double] {
        let base = projectsDir
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        var out: [String: Double] = [:]
        for name in Set(names) {
            guard let d = dir(forTitle: name, dirs: dirs),
                  let jsonl = latestJsonl(inDir: base.appendingPathComponent(d)) else {
                out[name] = 0
                continue
            }
            out[name] = lastHumanTime(jsonl)
        }
        return out
    }

    public static func order(_ windows: [YabaiWindow]) -> [YabaiWindow] {
        let base = projectsDir
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        func time(for w: YabaiWindow) -> Double {
            if w.hasFocus { return .greatestFiniteMagnitude } // active now → most recent
            guard let d = dir(forTitle: w.title, dirs: dirs),
                  let jsonl = latestJsonl(inDir: base.appendingPathComponent(d)) else { return 0 }
            return lastHumanTime(jsonl)
        }
        return windows.map { ($0, time(for: $0)) }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
