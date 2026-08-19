import Foundation
import WindowArrangerServerKit

// Native port of server.ts — thin CLI over ServerRuntime (the same runtime the
// menu bar app embeds). Usage:
//   WindowArrangerServer                 → port 8900, loops ON (authoritative)
//   WindowArrangerServer --shadow        → port 8901, loops OFF (diff vs Bun)
//   WindowArrangerServer --port N        → explicit port
var port: UInt16 = 8900
var shadow = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--shadow":
        shadow = true
        if port == 8900 { port = 8901 }
    case "--port":
        if let p = args.next().flatMap({ UInt16($0) }) { port = p }
    default:
        FileHandle.standardError.write("unknown arg: \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

try ServerRuntime.start(port: port, shadow: shadow)
RunLoop.main.run()
