// cursor — microtool: print or warp the mouse cursor (global coordinates).
//   cursor            → "x y" (current position)
//   cursor <x> <y>    → warp to that position (no click, no events)
// Built once via: swiftc -O scripts/cursor.swift -o scripts/bin/cursor
// Used by the /api/space/:space/focus route to keep the cursor still while
// yabai's non-SA display-focus trick warps it (Nat: "จอเปลี่ยน แต่เมาส์ต้องนิ่ง").
import CoreGraphics

let args = CommandLine.arguments
if args.count == 3, let x = Double(args[1]), let y = Double(args[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
} else {
    guard let loc = CGEvent(source: nil)?.location else { exit(1) }
    print("\(loc.x) \(loc.y)")
}
