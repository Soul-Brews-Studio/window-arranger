import Foundation
import WindowArrangerCore

// The server's snapshot cache — the Swift twin of lib/engine.ts. One sample
// yields BOTH the raw yabai JSON (kept as text for /api/state passthrough) and
// the typed views (for who/layout/pins math), so the two can never disagree.
// Thread-safe via a lock: HTTP handlers run on Network.framework queues.
final class ServerEngine {
    static let shared = ServerEngine()

    struct Sample {
        let ts: Double // epoch ms
        let rawDisplays: Data
        let rawSpaces: Data
        let typed: Arranger.SnapshotData
    }

    private let lock = NSLock()
    private var sample: Sample?
    private var writesInFlight = 0
    private var lastConfig: SpaceConfig?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.soulbrews.server.engine", qos: .utility)

    func start(intervalMs: Int = 1500) {
        forceRefresh()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let busy = self.writesInFlight > 0
            self.lock.unlock()
            if !busy { self.refresh(reuseConfig: true) }
        }
        t.resume()
        timer = t
    }

    func beginWrite() { lock.lock(); writesInFlight += 1; lock.unlock() }
    func endWrite() { lock.lock(); writesInFlight = max(0, writesInFlight - 1); lock.unlock() }

    var snapshot: Sample? {
        lock.lock(); defer { lock.unlock() }
        return sample
    }

    func current() -> Sample? { snapshot ?? forceRefresh() }

    @discardableResult
    func forceRefresh() -> Sample? { refresh(reuseConfig: false) }

    @discardableResult
    private func refresh(reuseConfig: Bool) -> Sample? {
        guard YabaiClient.isAvailable,
              let rawDisplays = YabaiClient.queryRaw("--displays"),
              let rawSpaces = YabaiClient.queryRaw("--spaces"),
              let rawWindows = YabaiClient.queryRaw("--windows") else { return nil }
        let dec = JSONDecoder()
        guard let displays = try? dec.decode([YabaiDisplay].self, from: rawDisplays),
              let spaces = try? dec.decode([YabaiSpace].self, from: rawSpaces),
              let windows = try? dec.decode([YabaiWindow].self, from: rawWindows) else { return nil }
        // Config rarely changes — poll ticks reuse it; writes/cold-start re-read.
        lock.lock()
        let cached = lastConfig
        lock.unlock()
        let config = (reuseConfig ? cached : nil) ?? YabaiClient.globalConfig()
        let typed = Arranger.SnapshotData(ts: Date().timeIntervalSince1970 * 1000,
                                          displays: displays, spaces: spaces,
                                          windows: windows, config: config)
        let s = Sample(ts: typed.ts, rawDisplays: rawDisplays, rawSpaces: rawSpaces, typed: typed)
        lock.lock()
        sample = s
        lastConfig = config
        lock.unlock()
        return s
    }
}
