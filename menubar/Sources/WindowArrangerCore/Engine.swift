import Foundation

// Swift port of lib/engine.ts: one cached Snapshot sampled from yabai, so the
// whole menu build reads from ONE sample instead of scattered per-item queries.
// A light poll keeps it warm; menu-open also forceRefreshes for exactness; writes
// bracket with beginWrite/endWrite so a poll tick can't cache a half-applied state.
public struct Snapshot {
    public let displays: [YabaiDisplay]
    public let spaces: [YabaiSpace]
    public let windows: [YabaiWindow]
    public let config: SpaceConfig
}

public final class Engine {
    public static let shared = Engine()

    public private(set) var snapshot: Snapshot?
    private var timer: Timer?
    private var writesInFlight = 0
    // One sample is ~8 yabai forks. NEVER run them on the main thread while the
    // poll ticks — that froze the search panel every 3s as you typed (Nat
    // 2026-07-12 "มันกระตุก"). The poll samples here and publishes on main.
    private let pollQueue = DispatchQueue(label: "com.soulbrews.engine.poll", qos: .utility)

    public func start(interval: TimeInterval = 3.0) {
        forceRefresh() // one synchronous sample at launch so the first open has data
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.writesInFlight == 0 else { return }
            self.refreshAsync() // OFF the main thread — the whole point of this fix
        }
    }

    public func beginWrite() { writesInFlight += 1 }
    public func endWrite() { writesInFlight = max(0, writesInFlight - 1) }

    // Synchronous — for the menu build + post-write refresh (deliberate, modal,
    // off the typing hot path). Blocks the CALLER's thread by design.
    @discardableResult
    public func forceRefresh() -> Snapshot? { snapshot = Engine.sampleSnapshot(); return snapshot }

    // Background sample, publish on main. Used by the poll and the panel's freshen
    // so neither ever forks yabai on the main thread. `completion` runs on main
    // after `snapshot` is updated. All writes to `snapshot` land on main → no race.
    public func refreshAsync(completion: (() -> Void)? = nil) {
        pollQueue.async { [weak self] in
            let snap = Engine.sampleSnapshot()
            DispatchQueue.main.async { self?.snapshot = snap; completion?() }
        }
    }

    private static func sampleSnapshot() -> Snapshot? {
        guard YabaiClient.isAvailable else { return nil }
        return Snapshot(
            displays: YabaiClient.displays(),
            spaces: YabaiClient.spaces(),
            windows: YabaiClient.windows(),
            config: YabaiClient.globalConfig()
        )
    }
}
