import Foundation
import CoreGraphics

// Swift port of lib/idle.ts — the fleet-shared human-idle clock.
// Unlike the TS side (which forks the gitignored scripts/bin/idle binary), this
// calls CGEventSource directly, removing the missing-binary failure mode by
// construction. The FORMULA must stay identical to census's active-watch.swift:
// min over the 5 event types below — one fleet-wide clock, so census's "(idle)"
// badge and the whenIdleOnly pins arm at the same second.
public enum Idle {
    public static let thresholdSec: Double = 300           // = census active-watch IDLE_SEC
    public static let visibleMultiplier: Double = 3        // visible-space windows wait 3×

    private static let eventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel,
    ]

    // 2s cache — census polls /api/who at 1 Hz; reporting doesn't need per-request
    // sampling. Enforcement decisions MUST pass fresh: a 2s-stale value can read
    // "≥300s" right as Nat sits back down at the 299→300 crossing.
    private static var cached: (value: Double?, at: Date)?
    private static let lock = NSLock()

    // Remote-human clock: an iPad command through census's public queue is a human
    // driving even though local HID is silent. Every allowed public-queue write
    // bumps this so whenIdleOnly pins don't yank a window mid-command.
    private static var lastRemoteHumanMs: Double = 0

    public static func noteRemoteHumanAction() {
        lock.lock(); defer { lock.unlock() }
        lastRemoteHumanMs = Date().timeIntervalSince1970 * 1000
    }

    private static func sample() -> Double? {
        let secs = eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min()
        guard let secs, secs.isFinite else { return nil }
        // The TS clock parses scripts/bin/idle's %.0f output — whole seconds,
        // half-up. Round the same so armed/threshold crossings match the fleet.
        return secs.rounded()
    }

    // min(local HID idle, seconds since last remote human action). nil = cannot
    // prove idle → callers must move NOTHING (fail safe, never guess).
    public static func effectiveSeconds(fresh: Bool = false) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let local: Double?
        if !fresh, let c = cached, Date().timeIntervalSince(c.at) < 2 {
            local = c.value
        } else {
            local = sample()
            cached = (local, Date())
        }
        guard let local else { return nil }
        guard lastRemoteHumanMs > 0 else { return local }
        let sinceRemote = Date().timeIntervalSince1970 - lastRemoteHumanMs / 1000
        return min(local, sinceRemote)
    }
}
