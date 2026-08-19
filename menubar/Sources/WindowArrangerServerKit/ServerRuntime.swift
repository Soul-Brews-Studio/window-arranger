import Foundation
import WindowArrangerCore

// The whole :8900 server as a callable — the standalone WindowArrangerServer
// binary and the menu bar app (รวมร่าง, Nat 2026-07-15: "เปิดมามี Status Bar
// แล้วก็ Run Server ด้วย") boot the exact same runtime. Everything inside is
// queue/timer-based; the caller only has to keep a run loop alive.
public enum ServerRuntime {
    static var server: HTTPServer?
    static var timers: [DispatchSourceTimer] = []
    public private(set) static var running = false

    public static func start(port: UInt16, shadow: Bool) throws {
        Routes.shadowMode = shadow
        ServerEngine.shared.start(intervalMs: 1500)
        do {
            try Displays.refresh() // CGDirectDisplayIDs reshuffle across reboots
        } catch {
            log("display-name refresh failed (using cached): \(error)")
        }

        let s = try HTTPServer(port: port) { Routes.handle($0) }
        s.start()
        server = s
        running = true
        log("WindowArrangerServer listening on 127.0.0.1:\(port)\(shadow ? " (shadow — loops off)" : "")")

        // Shadow mode exists so this can run NEXT TO an authoritative server:
        // two pin-enforcement loops would fight over the same windows.
        guard !shadow else { return }
        let loopQueue = DispatchQueue(label: "com.soulbrews.server.loops", qos: .utility)

        // 📌 pin enforcement — every 10s, fresh idle ALWAYS (a 2s-stale value could
        // fire a park exactly as Nat sits back down at the 299→300 crossing).
        let pinTick = DispatchSource.makeTimerSource(queue: loopQueue)
        pinTick.schedule(deadline: .now() + 10, repeating: 10)
        pinTick.setEventHandler {
            let pins = Pins.load()
            guard !pins.isEmpty, let s = ServerEngine.shared.snapshot else { return }
            let result = Pins.enforce(windows: s.typed.windows, spaces: s.typed.spaces,
                                      displays: s.typed.displays, names: Displays.names(),
                                      pins: pins, idle: Idle.effectiveSeconds(fresh: true))
            if !result.moved.isEmpty {
                log("📌 pins: snapped back \(result.moved.joined(separator: ", "))")
                ServerEngine.shared.beginWrite()
                ServerEngine.shared.forceRefresh()
                ServerEngine.shared.endWrite()
                Routes.publishDisplayMap()
            }
        }
        pinTick.resume()

        // 🩹 auto-heal — every 60s (lost labels + pure renumber; never real drift).
        let healTick = DispatchSource.makeTimerSource(queue: loopQueue)
        healTick.schedule(deadline: .now() + 60, repeating: 60)
        healTick.setEventHandler {
            guard Pins.autoHealEnabled() else { return } // auto-heal.off — Nat drives 🩹 heal manually
            guard let s = ServerEngine.shared.snapshot else { return }
            Pins.autoHeal(windows: s.typed.windows, spaces: s.typed.spaces)
        }
        healTick.resume()

        // 🗺️ display-map publish — every 60s, same as the Bun server.
        let publishTick = DispatchSource.makeTimerSource(queue: loopQueue)
        publishTick.schedule(deadline: .now() + 60, repeating: 60)
        publishTick.setEventHandler { Routes.publishDisplayMap() }
        publishTick.resume()

        timers = [pinTick, healTick, publishTick]
    }

    static func log(_ s: String) {
        FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    }
}
