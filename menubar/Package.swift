// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowArrangerMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Foundation-only fleet/yabai core shared by the menu bar app and the
        // native HTTP server (the server must never import AppKit).
        .target(
            name: "WindowArrangerCore",
            path: "Sources/WindowArrangerCore"
        ),
        // The :8900 server as a LIBRARY (ServerRuntime + HTTP/Routes/Engine) so
        // the standalone binary and the menu bar app boot the same runtime —
        // รวมร่าง (Nat 2026-07-15).
        .target(
            name: "WindowArrangerServerKit",
            dependencies: ["WindowArrangerCore"],
            path: "Sources/WindowArrangerServerKit"
        ),
        .executableTarget(
            name: "WindowArrangerMenuBar",
            dependencies: ["WindowArrangerCore", "WindowArrangerServerKit"],
            path: "Sources/WindowArrangerMenuBar"
        ),
        // Native port of server.ts — thin CLI main over ServerRuntime.
        .executableTarget(
            name: "WindowArrangerServer",
            dependencies: ["WindowArrangerCore", "WindowArrangerServerKit"],
            path: "Sources/WindowArrangerServer"
        ),
        // "อยากได้แอป กดดูง่าย" (Nat 2026-07-15): a plain double-clickable app
        // that opens the ONE web face (census local → public fallback) in its
        // own window. Deliberately a separate binary: the menubar binary holds
        // the Accessibility grant (hotkeys) and must never change path.
        .executableTarget(
            name: "WindowArrangerViewer",
            path: "Sources/WindowArrangerViewer"
        ),
    ]
)
