import Foundation

// Conformance sandboxing: WA_HOME overrides the root every config/state path
// hangs off (~/.config/window-arranger-oracle, ~/.claude/projects), so a test
// instance never touches the real files. Swift's homeDirectoryForCurrentUser
// reads passwd, NOT $HOME — hence an explicit env var (TS side uses $HOME).
public enum WAEnv {
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["WA_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

public struct Frame: Codable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

// Per-space padding + gap (all global today). Doubles for layout math.
public struct SpaceConfig {
    public let top: Double
    public let bottom: Double
    public let left: Double
    public let right: Double
    public let gap: Double
}

public struct YabaiDisplay: Codable {
    public let id: Int
    public let index: Int
    public let frame: Frame
    public let spaces: [Int]

    public enum CodingKeys: String, CodingKey {
        case id, index, frame, spaces
    }
}

public struct YabaiSpace: Codable {
    public let id: Int
    public let index: Int
    public let type: String
    public let display: Int
    public let windows: [Int]
    public let hasFocus: Bool
    public let isVisible: Bool
    public let label: String?

    public enum CodingKeys: String, CodingKey {
        case id, index, type, display, windows, label
        case hasFocus = "has-focus"
        case isVisible = "is-visible"
    }
}

public struct YabaiWindow: Codable {
    public let id: Int
    public let app: String
    public let title: String
    public let space: Int
    public let display: Int?
    public let frame: Frame
    public let hasFocus: Bool
    public let isFloating: Bool
    public let isSticky: Bool
    public let isMinimized: Bool
    public let isHidden: Bool
    // optional: absent in older fixtures — treat missing as "yes, it can"
    public let canMove: Bool?
    public let canResize: Bool?

    public enum CodingKeys: String, CodingKey {
        case id, app, title, space, display, frame
        case hasFocus = "has-focus"
        case isFloating = "is-floating"
        case isSticky = "is-sticky"
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
        case canMove = "can-move"
        case canResize = "can-resize"
    }
}
