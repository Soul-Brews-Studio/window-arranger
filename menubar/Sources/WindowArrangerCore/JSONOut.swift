import Foundation

// Minimal ordered JSON writer. JSONSerialization can't control key order, but
// /api/who's wire order is part of the (frozen) census contract, so responses
// are built from this instead. `.raw` embeds pre-serialized text verbatim —
// that's how /api/state passes yabai's own JSON through untouched.
public indirect enum JSON {
    case s(String)
    case n(Double)
    case i(Int)
    case b(Bool)
    case null
    case arr([JSON])
    case obj([(String, JSON)])
    case raw(String)

    public func encoded() -> String {
        switch self {
        case .s(let v): return JSON.escape(v)
        case .n(let v):
            if v.isNaN || v.isInfinite { return "null" }
            // Whole doubles print as integers (623 not 623.0) — matches JS.
            if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
            return String(v)
        case .i(let v): return String(v)
        case .b(let v): return v ? "true" : "false"
        case .null: return "null"
        case .arr(let items): return "[" + items.map { $0.encoded() }.joined(separator: ",") + "]"
        case .obj(let pairs):
            return "{" + pairs.map { JSON.escape($0.0) + ":" + $0.1.encoded() }.joined(separator: ",") + "}"
        case .raw(let text): return text
        }
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out + "\""
    }
}
