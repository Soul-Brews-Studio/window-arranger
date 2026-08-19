import Foundation

// Mirrors display-census/scripts/arrange-windows.swift's title-substring
// matching, ported into the native app. A rule targets EITHER a display (coarse:
// the window lands on that display's active space) OR a specific space — by index
// or by a stable label. `yabai -m window --space` is verified to work in non-SA
// mode (SIP enabled, no scripting addition) — see CLAUDE.md "Key Technical Finding".
public struct OracleRule: Codable {
    public let match: String
    public let display: Int?   // yabai display index (coarse — display's currently-active space)
    public let space: Int?     // yabai space index (finer — a specific space)
    public let label: String?  // stable space label; preferred over `space` (survives renumbering)
    public let grid: String?   // "rows:cols:x:y:w:h", forwarded to `yabai -m window --grid`

    public init(match: String, display: Int?, space: Int?, label: String?, grid: String?) {
        self.match = match; self.display = display; self.space = space
        self.label = label; self.grid = grid
    }

    // Resolved move target — label > space index > display. nil = no target (rule skipped).
    // yabai's `--space` selector accepts a bare index OR a label, so both collapse to a string.
    public var target: OracleTarget? {
        if let label { return .space(label) }
        if let space { return .space(String(space)) }
        if let display { return .display(display) }
        return nil
    }

    // Human-readable target for the confirmation dialog.
    public var targetDescription: String {
        switch target {
        case .space(let sel): return "space \(sel)"
        case .display(let d): return "display \(d)"
        case nil: return "(no target)"
        }
    }
}

public enum OracleTarget {
    case display(Int)
    case space(String) // index-as-string or a label — yabai --space accepts either
}

public enum OracleProfile {
    public static let path: String = {
        WAEnv.home
            .appendingPathComponent(".config/window-arranger-oracle/oracle-profile.json")
            .path
    }()

    public static func load() -> [OracleRule] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([OracleRule].self, from: data)) ?? []
    }

    // Overwrite the single profile, backing up any existing one first (Nothing is
    // Deleted). Returns the backup path if one was made.
    @discardableResult
    public static func save(_ rules: [OracleRule]) throws -> String? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: String?
        if fm.fileExists(atPath: path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            backup = path + ".bak." + stamp
            try? fm.copyItem(atPath: path, toPath: backup!)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rules).write(to: url)
        return backup
    }
}
