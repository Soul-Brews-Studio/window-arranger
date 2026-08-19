import Foundation

public enum YabaiClient {
    // Query commands read yabai's live compositor state directly — this is the
    // fix for the CGWindowListCopyWindowInfo staleness bug found in display-census:
    // yabai's own view of window/space state is always current, CGWindowList isn't.
    private static let candidatePaths = [
        "/opt/homebrew/bin/yabai",
        "/usr/local/bin/yabai",
    ]

    private static var binaryPath: String? = {
        // YABAI_BIN lets the conformance suite point every implementation at the
        // same fake binary; unset in normal operation.
        if let override = ProcessInfo.processInfo.environment["YABAI_BIN"], !override.isEmpty {
            return override
        }
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    @discardableResult
    private static func run(_ args: [String]) -> Data? {
        guard let binaryPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    public static var isAvailable: Bool { binaryPath != nil }

    // Raw query output for API passthrough: /api/state must forward yabai's own
    // JSON (uuid, label, is-native-fullscreen, …) — a typed re-serialization
    // would silently drop every field the structs don't model.
    public static func queryRaw(_ what: String) -> Data? {
        run(["-m", "query", what])
    }

    public static func displays() -> [YabaiDisplay] {
        guard let data = run(["-m", "query", "--displays"]) else { return [] }
        return (try? JSONDecoder().decode([YabaiDisplay].self, from: data)) ?? []
    }

    public static func spaces() -> [YabaiSpace] {
        guard let data = run(["-m", "query", "--spaces"]) else { return [] }
        return (try? JSONDecoder().decode([YabaiSpace].self, from: data)) ?? []
    }

    public static func windows() -> [YabaiWindow] {
        guard let data = run(["-m", "query", "--windows"]) else { return [] }
        return (try? JSONDecoder().decode([YabaiWindow].self, from: data)) ?? []
    }

    public static func windows(space index: Int) -> [YabaiWindow] {
        guard let data = run(["-m", "query", "--windows", "--space", String(index)]) else { return [] }
        return (try? JSONDecoder().decode([YabaiWindow].self, from: data)) ?? []
    }

    public static func display(index: Int) -> YabaiDisplay? {
        guard let data = run(["-m", "query", "--displays", "--display", String(index)]) else { return nil }
        return try? JSONDecoder().decode(YabaiDisplay.self, from: data)
    }

    // Reads a per-space integer config (paddings, window_gap). Output is a bare
    // number, not JSON.
    public static func configValue(space index: Int, key: String) -> Int {
        guard let data = run(["-m", "config", "--space", String(index), key]),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let v = Int(s) else { return 0 }
        return v
    }

    // Global config (padding/gap) — one sample per engine tick, not per space.
    public static func globalConfig() -> SpaceConfig {
        func v(_ key: String) -> Double {
            guard let data = run(["-m", "config", key]),
                  let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let n = Double(s) else { return 0 }
            return n
        }
        return SpaceConfig(top: v("top_padding"), bottom: v("bottom_padding"),
                           left: v("left_padding"), right: v("right_padding"), gap: v("window_gap"))
    }

    public static func focusSpace(index: Int) {
        run(["-m", "space", "--focus", String(index)])
    }

    public static func setLayout(spaceIndex: Int, layout: String) {
        run(["-m", "space", String(spaceIndex), "--layout", layout])
    }

    // Move a window to a display (lands on that display's active space). Verified
    // to work in non-SA mode.
    public static func moveWindow(id: Int, toDisplay display: Int) {
        run(["-m", "window", String(id), "--display", String(display)])
    }

    // Move a window to a specific space. `selector` is a space index (as a string)
    // OR a space label — yabai's `--space` accepts both. Verified in non-SA mode:
    // a window jumps to an off-screen space and back cleanly (no scripting addition).
    public static func moveWindow(id: Int, toSpace selector: String) {
        run(["-m", "window", String(id), "--space", selector])
    }

    // Place a window within its space via yabai's grid ("rows:cols:x:y:w:h").
    public static func setGrid(id: Int, grid: String) {
        run(["-m", "window", String(id), "--grid", grid])
    }

    // Focus a window (macOS switches to its space if needed). Works non-SA.
    public static func focusWindow(id: Int) {
        run(["-m", "window", String(id), "--focus"])
    }

    // Attach a stable label to a space (positional selector — `space <idx> --label`).
    // Labels survive index renumbering, so profiles can target `--space <label>`.
    public static func labelSpace(index: Int, label: String) {
        run(["-m", "space", String(index), "--label", label])
    }

    // JS Math.round = floor(x + 0.5) — half toward +∞. Swift's .rounded() is
    // half-away-from-zero, which drifts 1px on negative .5 coords (left displays).
    static func jsRound(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    // Absolute move/resize — only valid on floating windows (float the space
    // first). Coordinates are global (a display left of primary has negative x).
    public static func moveWindowAbs(id: Int, x: Double, y: Double) {
        run(["-m", "window", String(id), "--move", "abs:\(jsRound(x)):\(jsRound(y))"])
    }

    public static func resizeWindowAbs(id: Int, w: Double, h: Double) {
        run(["-m", "window", String(id), "--resize", "abs:\(jsRound(w)):\(jsRound(h))"])
    }

    // Checked variant for routes that must report failure honestly (the Bun
    // side's YabaiError contract). Returns nil on success or a TOLERATED no-op
    // (window/space vanished mid-flight), else the stderr text. Unlike run(),
    // this observes exit status and stderr.
    private static let noOpPattern = try! NSRegularExpression(
        pattern: "already|could not (find|locate)|does not exist", options: [.caseInsensitive])

    public static func runChecked(_ args: [String]) -> String? {
        guard let binaryPath else { return "yabai binary not found" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return String(describing: error) }
        // Drain both pipes BEFORE waitUntilExit — an undrained pipe can deadlock.
        _ = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(stderr.startIndex..., in: stderr)
        if noOpPattern.firstMatch(in: stderr, range: range) != nil { return nil } // tolerated no-op
        return stderr.isEmpty ? "yabai exited \(process.terminationStatus)" : stderr
    }

    // Focus a space and report failure (e.g. yabai's rapid-fire "mission-control
    // is active" no-op) — census's iPad button relies on an honest {ok:false}.
    public static func focusSpaceChecked(index: Int) -> String? {
        runChecked(["-m", "space", "--focus", String(index)])
    }
}
