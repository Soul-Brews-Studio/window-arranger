import Cocoa

// Hold-a-key in the search field should REPEAT (type/delete rapidly), like a
// terminal — not pop macOS's press-and-hold accent picker over the field
// (Nat 2026-07-13). Registered before any NSTextField exists so the input
// system sees it; scoped to this process only (not a global `defaults write`).
UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
