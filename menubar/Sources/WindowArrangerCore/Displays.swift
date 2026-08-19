import Foundation

// Swift port of lib/displays.ts — monitor names. yabai display `id` is the macOS
// CGDirectDisplayID, so system_profiler names map by id. Cached (hand-editable)
// at ~/.config/window-arranger-oracle/displays.json.
public enum Displays {
    public static let configPath: String = {
        WAEnv.home
            .appendingPathComponent(".config/window-arranger-oracle/displays.json").path
    }()

    // id (as String) → monitor name. File is a bare {"<id>": "<name>"} map
    // (lib/displays.ts). Missing/unparseable file → empty map.
    public static func names() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj.compactMapValues { $0 as? String }
    }

    // Detect via system_profiler: _spdisplays_displayID → _name.
    public static func detect() throws -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPDisplaysDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gpus = root["SPDisplaysDataType"] as? [[String: Any]] else {
            throw NSError(domain: "Displays", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "system_profiler failed"])
        }
        var out: [String: String] = [:]
        for gpu in gpus {
            for screen in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                guard let name = screen["_name"] as? String,
                      let rawID = screen["_spdisplays_displayID"] else { continue }
                out[String(describing: rawID)] = name
            }
        }
        return out
    }

    // Merge-preserving refresh: detected names win, hand-edited extras survive.
    @discardableResult
    public static func refresh() throws -> [String: String] {
        let merged = names().merging(try detect()) { _, new in new }
        let url = URL(fileURLWithPath: configPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: merged,
                                              options: [.prettyPrinted, .sortedKeys])
        data.append(Data("\n".utf8))
        try data.write(to: url)
        return merged
    }
}
