import Foundation

/// A JSON value for building and reading sing-box configs without `[String: Any]`.
nonisolated enum J: Hashable, Sendable {
    case s(String), i(Int), b(Bool), a([J]), o([String: J])

    static func strings(_ v: [String]) -> J { .a(v.map(J.s)) }

    var str: String? { if case .s(let v) = self { v } else { nil } }
    var int: Int? { if case .i(let v) = self { v } else { nil } }
    var bool: Bool? { if case .b(let v) = self { v } else { nil } }
    var list: [J]? { if case .a(let v) = self { v } else { nil } }
    var obj: [String: J]? { if case .o(let v) = self { v } else { nil } }
    var strs: [String]? { list?.compactMap(\.str) }

    subscript(key: String) -> J? {
        get { obj?[key] }
        set { if case .o(var d) = self { d[key] = newValue; self = .o(d) } }
    }
    subscript(index: Int) -> J? { list.flatMap { $0.indices.contains(index) ? $0[index] : nil } }

    /// Compact JSON with sorted keys, so the same value always serializes to the same text.
    var string: String {
        switch self {
        case .s(let v): Self.quote(v)
        case .i(let v): String(v)
        case .b(let v): v ? "true" : "false"
        case .a(let v): "[" + v.map(\.string).joined(separator: ",") + "]"
        case .o(let v): "{" + v.keys.sorted().map { Self.quote($0) + ":" + v[$0]!.string }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}

nonisolated extension J: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral v: String) { self = .s(v) }
    init(integerLiteral v: Int) { self = .i(v) }
    init(booleanLiteral v: Bool) { self = .b(v) }
    init(arrayLiteral v: J...) { self = .a(v) }
    init(dictionaryLiteral v: (String, J)...) { self = .o(Dictionary(v) { $1 }) }
}
