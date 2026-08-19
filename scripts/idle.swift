// idle — print seconds since the last human input (integer, stdout).
// min over mouse-move/click/key/scroll via CGEventSource, the SAME formula as
// display-census's active-watch.swift — the whole fleet shares one idle clock,
// so the wall's "(idle)" badge and our whenIdleOnly pins arm at the same second.
// Build (scripts/bin/ is gitignored — required on every fresh checkout, or ALL
// whenIdleOnly pins silently sit out):
//   swiftc -O scripts/idle.swift -o scripts/bin/idle     (or: bun run build:tools)
import CoreGraphics

let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
let secs = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
print(String(format: "%.0f", secs))
