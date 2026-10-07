import Foundation

// NS-EEL, the expression language of Milkdrop presets: statements separated by ';', variables
// (case-insensitive, all doubles), assignments (= += -= *= /= %=), arithmetic, comparisons, and functions
// such as sin, above, if, rand, sigmoid, megabuf. Code is compiled once into a tree of closures over a flat
// register file, then run every frame (per-frame code) or for every mesh vertex (per-pixel code).

/// Variables shared by the programs of one preset part. Slots are stable, so compiled code reads and writes
/// them through a raw pointer.
final class EELContext {
    private(set) var slots: [String: Int] = [:]
    let mem: UnsafeMutablePointer<Double>
    let capacity = 1024
    /// megabuf()/gmegabuf() memory.
    var megabuf = [Double](repeating: 0, count: 1 << 16)
    var gmegabuf: EELGlobal

    init(global: EELGlobal = EELGlobal()) {
        mem = .allocate(capacity: capacity)
        mem.initialize(repeating: 0, count: capacity)
        gmegabuf = global
    }

    deinit { mem.deallocate() }

    func slot(_ name: String) -> Int {
        let n = name.lowercased()
        if let s = slots[n] { return s }
        let s = min(slots.count, capacity - 1)
        slots[n] = s
        return s
    }

    subscript(_ name: String) -> Double {
        get { mem[slot(name)] }
        set { mem[slot(name)] = newValue }
    }
}

final class EELGlobal { var mem = [Double](repeating: 0, count: 1 << 16) }

/// A compiled program. An empty source compiles to a no-op.
struct EELProgram {
    let run: () -> Double
    let isEmpty: Bool
    static let empty = EELProgram(run: { 0 }, isEmpty: true)
}

enum EELError: Error, CustomStringConvertible {
    case syntax(String, Int)
    var description: String { if case .syntax(let m, let p) = self { return "\(m) (pos \(p))" }; return "" }
}

enum EEL {
    /// Compiles `source`; on a syntax error the statements before it are kept (Milkdrop is lenient too).
    static func compile(_ source: String, _ ctx: EELContext) -> EELProgram {
        let src = stripComments(source)
        if src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        var p = Parser(tokens: tokenize(src), ctx: ctx)
        let node = p.statements()
        return EELProgram(run: node, isEmpty: false)
    }

    static func stripComments(_ s: String) -> String {
        var out = "", i = s.startIndex
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("//") || rest.hasPrefix("\\\\") {
                i = s[i...].firstIndex(of: "\n") ?? s.endIndex
            } else if rest.hasPrefix("/*") {
                i = s[s.index(i, offsetBy: 2)...].range(of: "*/")?.upperBound ?? s.endIndex
            } else {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    // MARK: Tokens

    enum Tok: Equatable { case num(Double), ident(String), op(String), end }

    static func tokenize(_ s: String) -> [Tok] {
        var toks: [Tok] = []
        let c = Array(s.unicodeScalars)
        var i = 0
        let ops3 = ["<<=", ">>="], ops2 = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&=", "<<", ">>"]
        while i < c.count {
            let ch = c[i]
            if CharacterSet.whitespacesAndNewlines.contains(ch) { i += 1; continue }
            if CharacterSet.decimalDigits.contains(ch) || (ch == "." && i + 1 < c.count && CharacterSet.decimalDigits.contains(c[i + 1])) {
                var j = i
                if ch == "0", j + 1 < c.count, c[j + 1] == "x" || c[j + 1] == "X" {
                    j += 2
                    while j < c.count, CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(c[j]) { j += 1 }
                    toks.append(.num(Double(UInt64(String(String.UnicodeScalarView(c[(i + 2)..<j])), radix: 16) ?? 0)))
                    i = j
                    continue
                }
                while j < c.count, CharacterSet.decimalDigits.contains(c[j]) || c[j] == "." { j += 1 }
                if j < c.count, c[j] == "e" || c[j] == "E" {
                    var k = j + 1
                    if k < c.count, c[k] == "+" || c[k] == "-" { k += 1 }
                    if k < c.count, CharacterSet.decimalDigits.contains(c[k]) {
                        j = k
                        while j < c.count, CharacterSet.decimalDigits.contains(c[j]) { j += 1 }
                    }
                }
                toks.append(.num(Double(String(String.UnicodeScalarView(c[i..<j]))) ?? 0))
                i = j
                continue
            }
            if CharacterSet.letters.contains(ch) || ch == "_" || ch == "$" || ch == "#" {
                var j = i
                while j < c.count, CharacterSet.alphanumerics.contains(c[j]) || c[j] == "_" || c[j] == "$" || c[j] == "#" || c[j] == "." { j += 1 }
                let name = String(String.UnicodeScalarView(c[i..<j])).lowercased()
                if name == "$pi" { toks.append(.num(.pi)) } else if name == "$e" { toks.append(.num(M_E)) } else if name == "$phi" { toks.append(.num(1.61803398874989)) } else { toks.append(.ident(name)) }
                i = j
                continue
            }
            let rest = String(String.UnicodeScalarView(c[i..<min(c.count, i + 3)]))
            if let o = ops3.first(where: { rest.hasPrefix($0) }) { toks.append(.op(o)); i += 3; continue }
            if let o = ops2.first(where: { rest.hasPrefix($0) }) { toks.append(.op(o)); i += 2; continue }
            toks.append(.op(String(ch)))
            i += 1
        }
        toks.append(.end)
        return toks
    }

    // MARK: Parser → closures

    typealias Node = () -> Double

    @inline(__always) static func truth(_ v: Double) -> Bool { abs(v) > 0.00001 }

    struct Parser {
        let tokens: [Tok]
        let ctx: EELContext
        var pos = 0

        init(tokens: [Tok], ctx: EELContext) {
            self.tokens = tokens
            self.ctx = ctx
        }

        var peek: Tok { tokens[pos] }
        mutating func next() -> Tok { let t = tokens[pos]; if pos < tokens.count - 1 { pos += 1 }; return t }
        mutating func accept(_ o: String) -> Bool { if peek == .op(o) { pos += 1; return true }; return false }

        /// `a; b; c` → value of the last one. Stray tokens are skipped so one bad statement does not kill the rest.
        mutating func statements(until close: Set<String> = []) -> Node {
            var list: [Node] = []
            func closing(_ t: Tok) -> Bool { if case .op(let o) = t { return close.contains(o) }; return false }
            while peek != .end {
                if closing(peek) { break }
                if accept(";") { continue }
                let before = pos
                list.append(assignment())
                if pos == before { _ = next() }   // unparseable token: skip it
                if !accept(";") {
                    if closing(peek) || peek == .end { break }
                }
            }
            switch list.count {
            case 0: return { 0 }
            case 1: return list[0]
            case 2: let (a, b) = (list[0], list[1]); return { _ = a(); return b() }
            default: return { var v = 0.0; for n in list { v = n() }; return v }
            }
        }

        mutating func assignment() -> Node {
            // Look ahead for `ident op=`.
            if case .ident(let name) = peek, pos + 1 < tokens.count, case .op(let o) = tokens[pos + 1],
               ["=", "+=", "-=", "*=", "/=", "%=", "^=", "|=", "&="].contains(o) {
                pos += 2
                let rhs = assignment()
                let m = ctx.mem, s = ctx.slot(name)
                switch o {
                case "=": return { let v = rhs(); m[s] = v; return v }
                case "+=": return { m[s] += rhs(); return m[s] }
                case "-=": return { m[s] -= rhs(); return m[s] }
                case "*=": return { m[s] *= rhs(); return m[s] }
                case "/=": return { let d = rhs(); m[s] = d == 0 ? 0 : m[s] / d; return m[s] }
                case "%=": return { m[s] = EEL.mod(m[s], rhs()); return m[s] }
                case "^=": return { m[s] = pow(m[s], rhs()); return m[s] }
                case "|=": return { m[s] = Double(Int64(m[s]) | Int64(rhs())); return m[s] }
                default: return { m[s] = Double(Int64(m[s]) & Int64(rhs())); return m[s] }
                }
            }
            // megabuf(i) = v
            if case .ident(let name) = peek, name == "megabuf" || name == "gmegabuf" {
                let save = pos
                pos += 1
                if accept("(") {
                    let idx = assignment()
                    if accept(")"), accept("=") {
                        let rhs = assignment()
                        if name == "megabuf" {
                            let c = ctx
                            return { let i = Int(idx()); let v = rhs(); if i >= 0 && i < c.megabuf.count { c.megabuf[i] = v }; return v }
                        }
                        let g = ctx.gmegabuf
                        return { let i = Int(idx()); let v = rhs(); if i >= 0 && i < g.mem.count { g.mem[i] = v }; return v }
                    }
                }
                pos = save
            }
            return ternary()
        }

        mutating func ternary() -> Node {
            let c = logicOr()
            if accept("?") {
                let a = assignment()
                let b: Node = accept(":") ? assignment() : { 0 }
                return { EEL.truth(c()) ? a() : b() }
            }
            return c
        }

        mutating func logicOr() -> Node {
            var l = logicAnd()
            while accept("||") { let a = l, b = logicAnd(); l = { EEL.truth(a()) || EEL.truth(b()) ? 1 : 0 } }
            return l
        }

        mutating func logicAnd() -> Node {
            var l = bitOr()
            while accept("&&") { let a = l, b = bitOr(); l = { EEL.truth(a()) && EEL.truth(b()) ? 1 : 0 } }
            return l
        }

        mutating func bitOr() -> Node {
            var l = bitAnd()
            while accept("|") { let a = l, b = bitAnd(); l = { Double(Int64(a()) | Int64(b())) } }
            return l
        }

        mutating func bitAnd() -> Node {
            var l = comparison()
            while accept("&") { let a = l, b = comparison(); l = { Double(Int64(a()) & Int64(b())) } }
            return l
        }

        mutating func comparison() -> Node {
            var l = additive()
            while true {
                let a = l
                if accept("==") { let b = additive(); l = { abs(a() - b()) < 0.00001 ? 1 : 0 } }
                else if accept("!=") { let b = additive(); l = { abs(a() - b()) >= 0.00001 ? 1 : 0 } }
                else if accept("<=") { let b = additive(); l = { a() <= b() ? 1 : 0 } }
                else if accept(">=") { let b = additive(); l = { a() >= b() ? 1 : 0 } }
                else if accept("<") { let b = additive(); l = { a() < b() ? 1 : 0 } }
                else if accept(">") { let b = additive(); l = { a() > b() ? 1 : 0 } }
                else { return l }
            }
        }

        mutating func additive() -> Node {
            var l = multiplicative()
            while true {
                let a = l
                if accept("+") { let b = multiplicative(); l = { a() + b() } }
                else if accept("-") { let b = multiplicative(); l = { a() - b() } }
                else { return l }
            }
        }

        mutating func multiplicative() -> Node {
            var l = unary()
            while true {
                let a = l
                if accept("*") { let b = unary(); l = { a() * b() } }
                else if accept("/") { let b = unary(); l = { let d = b(); return d == 0 ? 0 : a() / d } }
                else if accept("%") { let b = unary(); l = { EEL.mod(a(), b()) } }
                else { return l }
            }
        }

        mutating func unary() -> Node {
            if accept("-") { let a = unary(); return { -a() } }
            if accept("+") { return unary() }
            if accept("!") { let a = unary(); return { EEL.truth(a()) ? 0 : 1 } }
            return power()
        }

        mutating func power() -> Node {
            let base = primary()
            if accept("^") { let e = unary(); return { EEL.pow(base(), e()) } }
            return base
        }

        mutating func primary() -> Node {
            switch next() {
            case .num(let v): return { v }
            case .op("("):
                let n = statements(until: [")"])
                _ = accept(")")
                return n
            case .ident(let name):
                if peek == .op("(") {
                    pos += 1
                    var args: [Node] = []
                    if !accept(")") {
                        repeat { args.append(statements(until: [",", ")"])) } while accept(",")
                        _ = accept(")")
                    }
                    return call(name, args)
                }
                let m = ctx.mem, s = ctx.slot(name)
                return { m[s] }
            default:
                return { 0 }
            }
        }

        mutating func call(_ name: String, _ a: [Node]) -> Node {
            func arg(_ i: Int) -> Node { i < a.count ? a[i] : { 0 } }
            let x = arg(0), y = arg(1), z = arg(2)
            switch name {
            case "sin": return { Foundation.sin(x()) }
            case "cos": return { Foundation.cos(x()) }
            case "tan": return { Foundation.tan(x()) }
            case "asin": return { Foundation.asin(max(-1, min(1, x()))) }
            case "acos": return { Foundation.acos(max(-1, min(1, x()))) }
            case "atan": return { Foundation.atan(x()) }
            case "atan2": return { Foundation.atan2(x(), y()) }
            case "sqr": return { let v = x(); return v * v }
            case "sqrt": return { Foundation.sqrt(abs(x())) }
            case "invsqrt": return { let v = abs(x()); return v == 0 ? 0 : 1 / Foundation.sqrt(v) }
            case "pow": return { EEL.pow(x(), y()) }
            case "exp": return { Foundation.exp(x()) }
            case "log": return { let v = x(); return v > 0 ? Foundation.log(v) : 0 }
            case "log10": return { let v = x(); return v > 0 ? Foundation.log10(v) : 0 }
            case "abs": return { abs(x()) }
            case "min": return { Swift.min(x(), y()) }
            case "max": return { Swift.max(x(), y()) }
            case "sign": return { let v = x(); return v > 0 ? 1 : (v < 0 ? -1 : 0) }
            case "int", "floor": return name == "int" ? { x().rounded(.towardZero) } : { Foundation.floor(x()) }
            case "ceil": return { Foundation.ceil(x()) }
            case "fmod": return { EEL.mod(x(), y()) }
            case "rand": return { let n = x(); return n < 1 ? Double.random(in: 0..<1) * n : Double(Int.random(in: 0..<Swift.max(1, Int(n)))) }
            case "above": return { x() > y() ? 1 : 0 }
            case "below": return { x() < y() ? 1 : 0 }
            case "equal": return { abs(x() - y()) < 0.00001 ? 1 : 0 }
            case "if": return { EEL.truth(x()) ? y() : z() }
            case "band": return { EEL.truth(x()) && EEL.truth(y()) ? 1 : 0 }
            case "bor": return { EEL.truth(x()) || EEL.truth(y()) ? 1 : 0 }
            case "bnot": return { EEL.truth(x()) ? 0 : 1 }
            case "sigmoid": return { let t = 1 + Foundation.exp(-x() * y()); return abs(t) > 0.00001 ? 1 / t : 0 }
            case "exec2": return { _ = x(); return y() }
            case "exec3": return { _ = x(); _ = y(); return z() }
            case "loop": return { var v = 0.0; let n = Swift.min(Int(x()), 1_000_000); if n > 0 { for _ in 0..<n { v = y() } }; return v }
            case "while": return { var v = 0.0, guardN = 0; while guardN < 1_000_000 { guardN += 1; v = x(); if !EEL.truth(v) { break } }; return v }
            case "megabuf":
                let c = ctx
                return { let i = Int(x()); return i >= 0 && i < c.megabuf.count ? c.megabuf[i] : 0 }
            case "gmegabuf":
                let g = ctx.gmegabuf
                return { let i = Int(x()); return i >= 0 && i < g.mem.count ? g.mem[i] : 0 }
            case "memset", "freembuf", "memcpy": return { 0 }
            default: return { 0 }
            }
        }
    }

    static let functionNames: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sqr", "sqrt", "invsqrt", "pow",
        "exp", "log", "log10", "abs", "min", "max", "sign", "int", "floor", "ceil", "fmod", "rand", "above", "below", "equal",
        "if", "band", "bor", "bnot", "sigmoid", "exec2", "exec3", "loop", "while", "megabuf", "gmegabuf", "memset", "freembuf", "memcpy"]

    @inline(__always) static func mod(_ a: Double, _ b: Double) -> Double {
        let ib = Int64(b)
        return ib == 0 ? 0 : Double(Int64(a) % ib)
    }

    @inline(__always) static func pow(_ a: Double, _ b: Double) -> Double {
        let v = Foundation.pow(a, b)
        return v.isFinite ? v : 0
    }
}
