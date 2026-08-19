import Foundation

// Swift port of lib/bsp.ts's server-facing surface: computeLayoutFromSnapshot,
// applyLayout (float-first + move-then-resize + 2px skip-in-place), retileSpace,
// gatherToMain, and the SVG renderers. Layout.swift holds the pure geometry;
// this file is the snapshot→plan→apply pipeline the HTTP routes call.
public enum Arranger {
    public struct SnapshotData {
        public let ts: Double // epoch ms when sampled
        public let displays: [YabaiDisplay]
        public let spaces: [YabaiSpace]
        public let windows: [YabaiWindow]
        public let config: SpaceConfig

        public init(ts: Double, displays: [YabaiDisplay], spaces: [YabaiSpace],
                    windows: [YabaiWindow], config: SpaceConfig) {
            self.ts = ts; self.displays = displays; self.spaces = spaces
            self.windows = windows; self.config = config
        }
    }

    public struct ComputedLayout {
        public let spaceIndex: Int
        public let displayIndex: Int
        public let displayFrame: Frame
        public let outer: Frame
        public let leaves: [Placement]
        public let total: Int
        public let mode: LayoutMode
    }

    public enum ArrangeError: Error, CustomStringConvertible {
        case spaceNotFound(Int)
        case displayNotFound(Int)
        public var description: String {
            switch self {
            case .spaceNotFound(let i): return "space \(i) not in snapshot"
            case .displayNotFound(let d): return "display \(d) not in snapshot"
            }
        }
    }

    // The web app's MODE_LABEL strings (lib/layout-core.ts) — the SVG titles must
    // match the Bun server's byte-for-byte, so these are the TS strings, NOT
    // LayoutMode.label (the menu's shorter names).
    public static func modeLabel(_ mode: LayoutMode) -> String {
        switch mode {
        case .spiral: return "Spiral — Fibonacci, largest first (left)"
        case .flip: return "Flip — largest right, curls down"
        case .flipup: return "Flip ↑ — largest right, curls up"
        case .grid: return "Grid — near-square equal cells"
        case .columns: return "Columns — one row, side by side"
        case .rows: return "Rows — one column, stacked"
        }
    }

    public static func parseMode(_ raw: String?) -> LayoutMode {
        raw.flatMap(LayoutMode.init(rawValue:)) ?? .spiral
    }

    public static func outerRect(displayFrame f: Frame, config c: SpaceConfig) -> Frame {
        Frame(x: f.x + c.left, y: f.y + c.top,
              w: f.w - c.left - c.right, h: f.h - c.top - c.bottom)
    }

    public static func computeLayout(snapshot s: SnapshotData, spaceIndex: Int,
                                     mode: LayoutMode, activeFirst: Bool) throws -> ComputedLayout {
        guard let space = s.spaces.first(where: { $0.index == spaceIndex }) else {
            throw ArrangeError.spaceNotFound(spaceIndex)
        }
        guard let display = s.displays.first(where: { $0.index == space.display }) else {
            throw ArrangeError.displayNotFound(space.display)
        }
        let windows = s.windows.filter { $0.space == spaceIndex && Layout.isTileable($0) }
        let outer = outerRect(displayFrame: display.frame, config: s.config)
        let leaves = Layout.compute(outer: outer, windows: windows, gap: s.config.gap,
                                    mode: mode, activeFirst: activeFirst)
        return ComputedLayout(spaceIndex: spaceIndex, displayIndex: space.display,
                              displayFrame: display.frame, outer: outer,
                              leaves: leaves, total: windows.count, mode: mode)
    }

    // Skip-in-place: within 2px on all of x/y/w/h → untouched, so settled windows
    // never blink. All-in-place → zero yabai writes and no float step.
    static func inPlace(_ f: Frame?, _ r: Frame) -> Bool {
        guard let f else { return false }
        return abs(f.x - r.x) < 2 && abs(f.y - r.y) < 2 && abs(f.w - r.w) < 2 && abs(f.h - r.h) < 2
    }

    @discardableResult
    public static func applyLayout(snapshot s: SnapshotData, spaceIndex: Int,
                                   mode: LayoutMode, activeFirst: Bool) throws -> Int {
        let layout = try computeLayout(snapshot: s, spaceIndex: spaceIndex,
                                       mode: mode, activeFirst: activeFirst)
        let todo = layout.leaves.filter { !inPlace($0.win.frame, $0.rect) }
        guard !todo.isEmpty else { return 0 }
        if let space = s.spaces.first(where: { $0.index == spaceIndex }), space.type != "float" {
            YabaiClient.setLayout(spaceIndex: spaceIndex, layout: "float")
        }
        for p in todo {
            YabaiClient.moveWindowAbs(id: p.win.id, x: p.rect.x, y: p.rect.y)
            YabaiClient.resizeWindowAbs(id: p.win.id, w: p.rect.w, h: p.rect.h)
        }
        return todo.count
    }

    // The app default (flip + active-first) — used to fill the gap a parked
    // window leaves behind.
    public static func retileSpace(snapshot s: SnapshotData, spaceIndex: Int) {
        _ = try? applyLayout(snapshot: s, spaceIndex: spaceIndex, mode: .flip, activeFirst: true)
    }

    // Main = display whose global frame origin is (0,0); fallback min index.
    public static func mainDisplayIndex(_ displays: [YabaiDisplay]) -> Int {
        displays.first { $0.frame.x == 0 && $0.frame.y == 0 }?.index
            ?? displays.map(\.index).min() ?? 1
    }

    public static func gatherToMain(snapshot s: SnapshotData) -> (moved: Int, mainIndex: Int, total: Int) {
        let main = mainDisplayIndex(s.displays)
        let tileable = s.windows.filter(Layout.isTileable)
        var moved = 0
        for w in tileable {
            let disp = w.display ?? s.displays.first { $0.spaces.contains(w.space) }?.index
            if let disp, disp != main {
                YabaiClient.moveWindow(id: w.id, toDisplay: main)
                moved += 1
            }
        }
        return (moved, main, tileable.count)
    }

    // --- SVG (matches bsp.ts svgFromItems byte-structure) ---------------------

    static let palette = ["#e94560", "#0f3460", "#16213e", "#53354a", "#903749",
                          "#e3b23c", "#2b7a78", "#5c6b73", "#a06cd5", "#f26430"]

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func winLabel(_ w: YabaiWindow) -> String {
        let title = w.title
        guard !title.isEmpty else { return w.app }
        // JS slice(0, 22) counts UTF-16 code units (an emoji costs 2), not
        // grapheme clusters — match it so SVG bodies stay byte-identical.
        let cut = String(decoding: Array(title.utf16.prefix(22)), as: UTF16.self)
        return "\(w.app): \(cut)"
    }

    // JS-style number printing: whole values render as integers.
    static func num(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(v)
    }

    // Byte-matches bsp.ts svgFromItems, template-literal whitespace included —
    // the shadow diff compares bodies verbatim.
    static func svgFromItems(title: String, displayFrame f: Frame,
                             items: [(win: YabaiWindow, rect: Frame)]) -> String {
        let margin = 8.0, labelH = 26.0, canvasW = 1000.0
        let scale = (canvasW - margin * 2) / f.w
        let drawH = f.h * scale
        let canvasH = (drawH + margin * 2 + labelH).rounded()
        let offsetX = margin, offsetY = margin + labelH

        var rects = ""
        for (i, item) in items.enumerated() {
            let x = offsetX + (item.rect.x - f.x) * scale
            let y = offsetY + (item.rect.y - f.y) * scale
            let w = item.rect.w * scale
            let h = item.rect.h * scale
            let color = palette[i % palette.count]
            rects += "<rect x=\"\(num(x))\" y=\"\(num(y))\" width=\"\(num(w))\" height=\"\(num(h))\" fill=\"\(color)\" stroke=\"#fff\" stroke-width=\"1.5\" opacity=\"0.85\"/>\n"
            rects += "      <text x=\"\(num(x + 6))\" y=\"\(num(y + 16))\" fill=\"white\" font-family=\"monospace\" font-size=\"11\">\(esc(winLabel(item.win)))</text>"
        }

        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(num(canvasW))" height="\(num(canvasH))" viewBox="0 0 \(num(canvasW)) \(num(canvasH))">
            <rect width="\(num(canvasW))" height="\(num(canvasH))" fill="#0a0e14"/>
            <text x="\(num(margin))" y="18" fill="#8fd3ff" font-family="monospace" font-size="14">\(esc(title))</text>
            <rect x="\(num(offsetX))" y="\(num(offsetY))" width="\(num(f.w * scale))" height="\(num(drawH))" fill="none" stroke="#444" stroke-dasharray="4,4"/>
            \(rects)
          </svg>
        """
    }

    // PROPOSED layout for a space.
    public static func renderPreviewSVG(snapshot s: SnapshotData, spaceIndex: Int,
                                        mode: LayoutMode, activeFirst: Bool) throws -> String {
        let layout = try computeLayout(snapshot: s, spaceIndex: spaceIndex,
                                       mode: mode, activeFirst: activeFirst)
        let title = "\(modeLabel(mode))\(activeFirst ? " · active-first" : "") · space \(layout.spaceIndex) / display \(layout.displayIndex) · \(layout.total) windows"
        return svgFromItems(title: title, displayFrame: layout.displayFrame,
                            items: layout.leaves.map { ($0.win, $0.rect) })
    }

    // CURRENT real arrangement — windows at their actual yabai frames.
    public static func renderCurrentSVG(snapshot s: SnapshotData, spaceIndex: Int) throws -> String {
        guard let space = s.spaces.first(where: { $0.index == spaceIndex }) else {
            throw ArrangeError.spaceNotFound(spaceIndex)
        }
        guard let display = s.displays.first(where: { $0.index == space.display }) else {
            throw ArrangeError.displayNotFound(space.display)
        }
        let items = s.windows
            .filter { $0.space == spaceIndex && Layout.isTileable($0) }
            .map { ($0, $0.frame) }
        let title = "CURRENT arrangement · space \(spaceIndex) / display \(space.display) · \(items.count) windows"
        return svgFromItems(title: title, displayFrame: display.frame, items: items)
    }
}
