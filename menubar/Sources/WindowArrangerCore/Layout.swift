import Foundation

// Swift port of lib/bsp.ts — the same three deterministic layouts the web app
// uses, so the menu bar and web UI arrange windows identically. We compute our
// own layout and apply it with explicit --move/--resize (see YabaiClient) rather
// than yabai's insertion-order-dependent auto-bsp.
public enum LayoutMode: String, CaseIterable {
    case spiral, flip, flipup, grid, columns, rows

    public var label: String {
        switch self {
        case .spiral: return "Fibonacci Spiral"
        case .flip: return "Flip (largest right, curls down)"
        case .flipup: return "Flip ↑ (largest right, curls up)"
        case .grid: return "Grid"
        case .columns: return "Columns (one row)"
        case .rows: return "Rows (one column)"
        }
    }
}

public struct Placement {
    public let win: YabaiWindow
    public let rect: Frame
}

public enum Layout {
    // Matches yabai's own notion of "tileable" for the flags the query exposes.
    // can-move/can-resize=false (e.g. Wispr Flow's untitled overlay) would claim
    // a slot then snap back to center, leaving a hole in the layout.
    public static func isTileable(_ w: YabaiWindow) -> Bool {
        !w.isFloating && !w.isSticky && !w.isMinimized && !w.isHidden
            && w.canMove != false && w.canResize != false
    }

    // 50/50 Fibonacci spiral: largest window takes the first (left/top) half,
    // the rest recurse into the second half, axis chosen by aspect ratio.
    public static func spiral(_ rect: Frame, _ wins: [YabaiWindow], gap: Double) -> [Placement] {
        guard wins.count > 1 else {
            return wins.map { Placement(win: $0, rect: rect) }
        }
        let first: Frame
        let rest: Frame
        if rect.w >= rect.h {
            let halfW = (rect.w - gap) / 2
            first = Frame(x: rect.x, y: rect.y, w: halfW, h: rect.h)
            rest = Frame(x: rect.x + halfW + gap, y: rect.y, w: halfW, h: rect.h)
        } else {
            let halfH = (rect.h - gap) / 2
            first = Frame(x: rect.x, y: rect.y, w: rect.w, h: halfH)
            rest = Frame(x: rect.x, y: rect.y + halfH + gap, w: rect.w, h: halfH)
        }
        return [Placement(win: wins[0], rect: first)] + spiral(rest, Array(wins.dropFirst()), gap: gap)
    }

    // Horizontal mirror within the outer rect.
    public static func mirrorX(_ placements: [Placement], outer: Frame) -> [Placement] {
        placements.map { p in
            Placement(win: p.win, rect: Frame(
                x: outer.x + outer.w - (p.rect.x - outer.x) - p.rect.w,
                y: p.rect.y, w: p.rect.w, h: p.rect.h
            ))
        }
    }

    // Vertical mirror. mirrorX + mirrorY == 180° rotation of the spiral.
    public static func mirrorY(_ placements: [Placement], outer: Frame) -> [Placement] {
        placements.map { p in
            Placement(win: p.win, rect: Frame(
                x: p.rect.x,
                y: outer.y + outer.h - (p.rect.y - outer.y) - p.rect.h,
                w: p.rect.w, h: p.rect.h
            ))
        }
    }

    // Equal cells; column count picked to fill cleanly with reasonable aspect.
    public static func grid(_ outer: Frame, _ wins: [YabaiWindow], gap: Double) -> [Placement] {
        let n = wins.count
        guard n > 0 else { return [] }
        var best = (cols: 1, rows: n, score: Double.infinity)
        for cols in 1...n {
            let rows = Int((Double(n) / Double(cols)).rounded(.up))
            let empty = Double(cols * rows - n)
            let cellW = (outer.w - Double(cols - 1) * gap) / Double(cols)
            let cellH = (outer.h - Double(rows - 1) * gap) / Double(rows)
            let aspectDev = abs(log(cellW / cellH))
            let score = empty * 2 + aspectDev
            if score < best.score { best = (cols, rows, score) }
        }
        let cols = best.cols, rows = best.rows
        let cellW = (outer.w - Double(cols - 1) * gap) / Double(cols)
        let cellH = (outer.h - Double(rows - 1) * gap) / Double(rows)
        return wins.enumerated().map { i, win in
            let r = i / cols, c = i % cols
            return Placement(win: win, rect: Frame(
                x: outer.x + Double(c) * (cellW + gap),
                y: outer.y + Double(r) * (cellH + gap),
                w: cellW, h: cellH
            ))
        }
    }

    // One horizontal row of equal, full-height columns (1 | 2 | 3 | …).
    public static func columns(_ outer: Frame, _ wins: [YabaiWindow], gap: Double) -> [Placement] {
        let n = wins.count
        guard n > 0 else { return [] }
        let w = (outer.w - Double(n - 1) * gap) / Double(n)
        return wins.enumerated().map { i, win in
            Placement(win: win, rect: Frame(x: outer.x + Double(i) * (w + gap), y: outer.y, w: w, h: outer.h))
        }
    }

    // One vertical column of equal, full-width rows, stacked top→bottom.
    public static func rows(_ outer: Frame, _ wins: [YabaiWindow], gap: Double) -> [Placement] {
        let n = wins.count
        guard n > 0 else { return [] }
        let h = (outer.h - Double(n - 1) * gap) / Double(n)
        return wins.enumerated().map { i, win in
            Placement(win: win, rect: Frame(x: outer.x, y: outer.y + Double(i) * (h + gap), w: outer.w, h: h))
        }
    }

    // activeFirst reorders windows by human-active recency (Recency.order) before
    // the base layout, so the window you last typed in lands in the biggest slot.
    public static func compute(outer: Frame, windows: [YabaiWindow], gap: Double, mode: LayoutMode, activeFirst: Bool = false) -> [Placement] {
        let tileable = windows.filter(isTileable)
        let wins = activeFirst ? Recency.order(tileable) : tileable
        guard !wins.isEmpty else { return [] }
        switch mode {
        // grid/columns + active-first: mirror so the active window lands on the RIGHT.
        case .grid: return activeFirst ? mirrorX(grid(outer, wins, gap: gap), outer: outer) : grid(outer, wins, gap: gap)
        case .columns: return activeFirst ? mirrorX(columns(outer, wins, gap: gap), outer: outer) : columns(outer, wins, gap: gap)
        // rows + active-first: no mirror — wins[0] is already top, the prime slot.
        case .rows: return rows(outer, wins, gap: gap)
        case .flip: return mirrorX(spiral(outer, wins, gap: gap), outer: outer)
        case .flipup: return mirrorY(mirrorX(spiral(outer, wins, gap: gap), outer: outer), outer: outer)
        case .spiral: return spiral(outer, wins, gap: gap)
        }
    }
}
