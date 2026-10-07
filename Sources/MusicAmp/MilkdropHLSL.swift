import Foundation

// Translates Milkdrop 2 preset shaders (HLSL, Shader Model 2/3 style) to Metal Shading Language.
// HLSL converts vector sizes implicitly (float3 x = tex2D(...) drops .w, float3 v = 0 splats) and Metal
// does not, so this is a small compiler: it parses the shader, infers expression types and inserts the
// conversions, maps tex2D/lerp/frac/mul… to Metal, and routes Milkdrop's globals (time, q1…q32, samplers)
// through hidden parameters, since Metal has no global uniforms.

enum HLSLError: Error, CustomStringConvertible {
    case parse(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .parse(let s): return "sintassi: \(s)"
        case .unsupported(let s): return "non supportato: \(s)"
        }
    }
}

/// HLSL types the translator tracks.
indirect enum HType: Equatable {
    enum Kind { case float, int, bool }
    case scalar(Kind)
    case vec(Kind, Int)
    case mat(Int, Int)        // rows × columns, HLSL naming
    case sampler(Int)         // 2 or 3 dimensions
    case void
    case unknown

    static let float = HType.scalar(.float)
    static func f(_ n: Int) -> HType { n == 1 ? .float : .vec(.float, n) }

    var size: Int {
        switch self {
        case .scalar: return 1
        case .vec(_, let n): return n
        default: return 0
        }
    }
    var kind: Kind? {
        switch self {
        case .scalar(let k), .vec(let k, _): return k
        case .mat: return .float
        default: return nil
        }
    }
    var isNumeric: Bool { size > 0 }

    var msl: String {
        func k(_ k: Kind) -> String { k == .float ? "float" : (k == .int ? "int" : "bool") }
        switch self {
        case .scalar(let x): return k(x)
        case .vec(let x, let n): return "\(k(x))\(n)"
        case .mat(let r, let c): return "float\(r)x\(c)"
        case .void: return "void"
        default: return "float4"
        }
    }

    /// "float3", "half2", "int", "float4x3", "sampler2D"… → type.
    static func parse(_ s: String) -> HType? {
        if ["sampler", "sampler2D", "texture", "texture2D", "sampler_state"].contains(s) { return .sampler(2) }
        if ["sampler3D", "texture3D"].contains(s) { return .sampler(3) }
        if s == "void" { return .void }
        let bases: [(String, Kind)] = [("float", .float), ("half", .float), ("double", .float), ("int", .int), ("uint", .int), ("bool", .bool)]
        for (b, kind) in bases where s.hasPrefix(b) {
            let rest = s.dropFirst(b.count)
            if rest.isEmpty { return .scalar(kind) }
            if let n = Int(rest), (1...4).contains(n) { return n == 1 ? .scalar(kind) : .vec(kind, n) }
            let parts = rest.split(separator: "x")
            if parts.count == 2, let r = Int(parts[0]), let c = Int(parts[1]), (1...4).contains(r), (1...4).contains(c) { return .mat(r, c) }
        }
        return nil
    }
}

// MARK: AST

indirect enum HExpr {
    case num(String, isInt: Bool)
    case ident(String)
    case call(String, [HExpr])
    case member(HExpr, String)
    case index(HExpr, HExpr)
    case unary(String, HExpr)
    case postfix(String, HExpr)
    case binary(String, HExpr, HExpr)
    case assign(String, HExpr, HExpr)
    case ternary(HExpr, HExpr, HExpr)
    case cast(String, HExpr)
    case initList([HExpr])
}

indirect enum HStmt {
    case decl(type: String, vars: [(name: String, array: HExpr?, value: HExpr?)], isConst: Bool, isStatic: Bool)
    case expr(HExpr)
    case ifS(HExpr, HStmt, HStmt?)
    case forS(HStmt?, HExpr?, HExpr?, HStmt)
    case whileS(HExpr, HStmt)
    case doS(HStmt, HExpr)
    case ret(HExpr?)
    case block([HStmt])
    case brk, cont, empty
}

struct HFunc {
    var ret: String
    var name: String
    var params: [(qual: String, type: String, name: String)]
    var body: [HStmt]
}

struct HShader {
    var defines: [String] = []
    var functions: [HFunc] = []
    var globals: [HStmt] = []
    var body: [HStmt] = []
}

// MARK: Lexer + parser

struct HLSLParser {
    enum Tok: Equatable { case ident(String), num(String), op(String), eof }
    private var toks: [Tok] = []
    private var pos = 0
    private(set) var defines: [String] = []

    init(_ source: String) throws {
        var src = ""
        // #define macros are expanded here, so their bodies go through the translator like any other code.
        var macros: [String: (params: [String]?, body: [Tok])] = [:]
        for line in source.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") {
                if t.hasPrefix("#define") {
                    let rest = t.dropFirst(7).drop { $0 == " " || $0 == "\t" }
                    let name = String(rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" })
                    var after = rest.dropFirst(name.count)
                    var params: [String]?
                    if after.first == "(", let close = after.firstIndex(of: ")") {
                        params = after[after.index(after: after.startIndex)..<close].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        after = after[after.index(after: close)...]
                    }
                    if !name.isEmpty { macros[name] = (params, Array(HLSLParser.lex(String(after)).dropLast())) }
                }
                src += "\n"
                continue
            }
            src += line + "\n"
        }
        toks = HLSLParser.lex(src)
        if !macros.isEmpty { toks = HLSLParser.expand(toks, macros, depth: 0) }
    }

    static func expand(_ input: [Tok], _ macros: [String: (params: [String]?, body: [Tok])], depth: Int) -> [Tok] {
        guard depth < 8 else { return input }
        var out: [Tok] = []
        var i = 0
        var changed = false
        while i < input.count {
            guard case .ident(let n) = input[i], let m = macros[n] else { out.append(input[i]); i += 1; continue }
            if let params = m.params {
                guard i + 1 < input.count, input[i + 1] == .op("(") else { out.append(input[i]); i += 1; continue }
                var args: [[Tok]] = [[]], level = 0, j = i + 2
                while j < input.count {
                    let t = input[j]
                    if t == .op("(") { level += 1 }
                    if t == .op(")") { if level == 0 { break }; level -= 1 }
                    if t == .op(","), level == 0 { args.append([]) } else { args[args.count - 1].append(t) }
                    j += 1
                }
                for t in m.body {
                    if case .ident(let p) = t, let k = params.firstIndex(of: p), k < args.count { out += [.op("(")] + args[k] + [.op(")")] } else { out.append(t) }
                }
                i = j + 1
            } else {
                out += m.body
                i += 1
            }
            changed = true
        }
        return changed ? expand(out, macros, depth: depth + 1) : out
    }

    static func lex(_ s: String) -> [Tok] {
        var out: [Tok] = []
        let c = Array(s.unicodeScalars)
        var i = 0
        let ops3 = ["<<=", ">>="]
        let ops2 = ["++", "--", "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "&=", "|=", "^="]
        func isDigit(_ u: Unicode.Scalar) -> Bool { u.value >= 48 && u.value <= 57 }
        func isIdent(_ u: Unicode.Scalar) -> Bool { CharacterSet.letters.contains(u) || u == "_" || isDigit(u) }
        while i < c.count {
            let ch = c[i]
            if CharacterSet.whitespacesAndNewlines.contains(ch) { i += 1; continue }
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if isDigit(ch) || (ch == "." && i + 1 < c.count && isDigit(c[i + 1])) {
                var j = i
                while j < c.count, isDigit(c[j]) || c[j] == "." { j += 1 }
                if j < c.count, c[j] == "e" || c[j] == "E" {
                    var k = j + 1
                    if k < c.count, c[k] == "+" || c[k] == "-" { k += 1 }
                    if k < c.count, isDigit(c[k]) { j = k; while j < c.count, isDigit(c[j]) { j += 1 } }
                }
                var text = String(String.UnicodeScalarView(c[i..<j]))
                while j < c.count, c[j] == "f" || c[j] == "F" || c[j] == "h" || c[j] == "H" || c[j] == "l" || c[j] == "L" { j += 1 }
                if text.hasPrefix(".") { text = "0" + text }
                if text.hasSuffix(".") { text += "0" }
                out.append(.num(text))
                i = j
                continue
            }
            if CharacterSet.letters.contains(ch) || ch == "_" {
                var j = i
                while j < c.count, isIdent(c[j]) { j += 1 }
                out.append(.ident(String(String.UnicodeScalarView(c[i..<j]))))
                i = j
                continue
            }
            let rest = String(String.UnicodeScalarView(c[i..<min(c.count, i + 3)]))
            if let o = ops3.first(where: { rest.hasPrefix($0) }) { out.append(.op(o)); i += 3; continue }
            if let o = ops2.first(where: { rest.hasPrefix($0) }) { out.append(.op(o)); i += 2; continue }
            out.append(.op(String(ch)))
            i += 1
        }
        out.append(.eof)
        return out
    }

    private var peek: Tok { toks[pos] }
    private func peek(_ k: Int) -> Tok { toks[min(toks.count - 1, pos + k)] }
    private mutating func next() -> Tok { let t = toks[pos]; if pos < toks.count - 1 { pos += 1 }; return t }
    private mutating func accept(_ o: String) -> Bool {
        if peek == .op(o) || peek == .ident(o) { pos += 1; return true }
        return false
    }
    private mutating func expect(_ o: String) throws {
        guard accept(o) else { throw HLSLError.parse("atteso '\(o)' invece di \(peek)") }
    }
    private mutating func ident() throws -> String {
        guard case .ident(let s) = next() else { throw HLSLError.parse("atteso un nome") }
        return s
    }

    private func isType(_ t: Tok) -> Bool {
        if case .ident(let s) = t { return HType.parse(s) != nil }
        return false
    }
    private static let qualifiers: Set<String> = ["static", "const", "uniform", "inline", "extern", "volatile", "precise"]

    // MARK: Top level

    mutating func parseShader() throws -> HShader {
        var sh = HShader()
        sh.defines = defines
        while peek != .eof {
            if accept("shader_body") {
                guard case .block(let b) = try statement() else { throw HLSLError.parse("shader_body senza blocco") }
                sh.body = b
                break
            }
            if accept(";") { continue }
            // Function definition: type name ( … ) {
            var save = pos
            while case .ident(let q) = peek, HLSLParser.qualifiers.contains(q) { pos += 1 }
            if isType(peek), case .ident = peek(1), peek(2) == .op("(") {
                let ret = try ident()
                let name = try ident()
                try expect("(")
                var params: [(String, String, String)] = []
                if !accept(")") {
                    repeat {
                        var qual = "in"
                        while case .ident(let q) = peek, ["in", "out", "inout", "uniform", "const"].contains(q) { qual = q == "uniform" || q == "const" ? qual : q; pos += 1 }
                        let t = try ident()
                        let n = try ident()
                        if accept(":") { _ = try ident() }   // semantics
                        params.append((qual, t, n))
                    } while accept(",")
                    try expect(")")
                }
                if accept(":") { _ = try ident() }
                guard case .block(let body) = try statement() else { throw HLSLError.parse("funzione \(name) senza corpo") }
                sh.functions.append(HFunc(ret: ret, name: name, params: params, body: body))
                continue
            }
            pos = save
            save = pos
            if let d = try? declaration() {
                sh.globals.append(d)
                continue
            }
            pos = save
            throw HLSLError.parse("elemento globale non riconosciuto: \(peek)")
        }
        return sh
    }

    // MARK: Statements

    private mutating func declaration() throws -> HStmt {
        var isConst = false, isStatic = false
        while case .ident(let q) = peek, HLSLParser.qualifiers.contains(q) {
            if q == "const" { isConst = true }
            if q == "static" { isStatic = true }
            pos += 1
        }
        guard isType(peek) else { throw HLSLError.parse("attesa una dichiarazione") }
        let type = try ident()
        var vars: [(String, HExpr?, HExpr?)] = []
        repeat {
            let n = try ident()
            var arr: HExpr?
            if accept("[") { arr = peek == .op("]") ? .num("0", isInt: true) : try expression(); try expect("]") }
            if accept(":") { _ = try ident() }
            var v: HExpr?
            if accept("=") {
                if accept("sampler_state") {
                    // sampler sampler_x = sampler_state { Texture = <…>; … };  — filtering comes from the name.
                    if accept("{") { var level = 1; while level > 0, peek != .eof { if peek == .op("{") { level += 1 }; if peek == .op("}") { level -= 1 }; pos += 1 } }
                } else if accept("{") {
                    var items: [HExpr] = []
                    if !accept("}") { repeat { if peek == .op("}") { break }; items.append(try assignment()) } while accept(","); try expect("}") }
                    v = .initList(items)
                } else {
                    v = try assignment()
                }
            }
            vars.append((n, arr, v))
        } while accept(",")
        try expect(";")
        return .decl(type: type, vars: vars, isConst: isConst, isStatic: isStatic)
    }

    mutating func statement() throws -> HStmt {
        if accept(";") { return .empty }
        if accept("{") {
            var list: [HStmt] = []
            while !accept("}") {
                if peek == .eof { throw HLSLError.parse("blocco non chiuso") }
                list.append(try statement())
            }
            return .block(list)
        }
        if accept("if") {
            try expect("(")
            let c = try expression()
            try expect(")")
            let a = try statement()
            let b = accept("else") ? try statement() : nil
            return .ifS(c, a, b)
        }
        if accept("for") {
            try expect("(")
            var initS: HStmt?
            if !accept(";") {
                if isDeclStart() { initS = try declaration() } else { initS = .expr(try expression()); try expect(";") }
            }
            let cond = peek == .op(";") ? nil : try expression()
            try expect(";")
            let step = peek == .op(")") ? nil : try expression()
            try expect(")")
            return .forS(initS, cond, step, try statement())
        }
        if accept("while") {
            try expect("(")
            let c = try expression()
            try expect(")")
            return .whileS(c, try statement())
        }
        if accept("do") {
            let b = try statement()
            try expect("while")
            try expect("(")
            let c = try expression()
            try expect(")")
            try expect(";")
            return .doS(b, c)
        }
        if accept("return") {
            if accept(";") { return .ret(nil) }
            let e = try expression()
            try expect(";")
            return .ret(e)
        }
        if accept("break") { try expect(";"); return .brk }
        if accept("continue") { try expect(";"); return .cont }
        if isDeclStart() { return try declaration() }
        let e = try expression()
        try expect(";")
        return .expr(e)
    }

    private func isDeclStart() -> Bool {
        var k = 0
        while case .ident(let q) = peek(k), HLSLParser.qualifiers.contains(q) { k += 1 }
        if case .ident(let s) = peek(k), HType.parse(s) != nil, case .ident = peek(k + 1) { return true }
        return false
    }

    // MARK: Expressions

    mutating func expression() throws -> HExpr {
        var e = try assignment()
        while accept(",") { e = .binary(",", e, try assignment()) }
        return e
    }

    private mutating func assignment() throws -> HExpr {
        let lhs = try ternary()
        if case .op(let o) = peek, ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="].contains(o) {
            pos += 1
            return .assign(o, lhs, try assignment())
        }
        return lhs
    }

    private mutating func ternary() throws -> HExpr {
        let c = try binary(0)
        if accept("?") {
            let a = try assignment()
            try expect(":")
            return .ternary(c, a, try assignment())
        }
        return c
    }

    private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

    private mutating func binary(_ level: Int) throws -> HExpr {
        if level == HLSLParser.levels.count { return try unary() }
        var l = try binary(level + 1)
        while case .op(let o) = peek, HLSLParser.levels[level].contains(o) {
            pos += 1
            l = .binary(o, l, try binary(level + 1))
        }
        return l
    }

    private mutating func unary() throws -> HExpr {
        if case .op(let o) = peek, ["-", "+", "!", "~", "++", "--"].contains(o) {
            pos += 1
            return .unary(o, try unary())
        }
        // Cast: (float3) x
        if peek == .op("("), case .ident(let t) = peek(1), HType.parse(t) != nil, peek(2) == .op(")") {
            pos += 3
            return .cast(t, try unary())
        }
        return try postfix()
    }

    private mutating func postfix() throws -> HExpr {
        var e = try primary()
        while true {
            if accept(".") { e = .member(e, try ident()); continue }
            if accept("[") { let i = try expression(); try expect("]"); e = .index(e, i); continue }
            if case .op(let o) = peek, o == "++" || o == "--" { pos += 1; e = .postfix(o, e); continue }
            return e
        }
    }

    private mutating func primary() throws -> HExpr {
        switch next() {
        case .num(let n): return .num(n, isInt: !n.contains(".") && !n.lowercased().contains("e"))
        case .ident(let name):
            if accept("(") {
                var args: [HExpr] = []
                if !accept(")") {
                    repeat { args.append(try assignment()) } while accept(",")
                    try expect(")")
                }
                return .call(name, args)
            }
            if name == "true" { return .num("true", isInt: false) }
            if name == "false" { return .num("false", isInt: false) }
            return .ident(name)
        case .op("("):
            let e = try expression()
            try expect(")")
            return e
        case let t:
            throw HLSLError.parse("espressione inattesa: \(t)")
        }
    }
}

// MARK: Code generation

/// Where each Milkdrop global lives in the uniform block (`U.v[i]`, 160 float4).
enum MDUniforms {
    static let count = 160
    static let fields: [String: String] = {
        var m: [String: String] = [:]
        let rows: [[String]] = [["time", "fps", "frame", "progress"], ["bass", "mid", "treb", "vol"],
                                ["bass_att", "mid_att", "treb_att", "vol_att"]]
        for (r, names) in rows.enumerated() { for (c, n) in names.enumerated() { m[n] = "U.v[\(r)].\(["x", "y", "z", "w"][c])" } }
        m["aspect"] = "U.v[3]"; m["texsize"] = "U.v[4]"; m["rand_frame"] = "U.v[5]"; m["rand_preset"] = "U.v[6]"
        m["roam_cos"] = "U.v[7]"; m["roam_sin"] = "U.v[8]"; m["slow_roam_cos"] = "U.v[9]"; m["slow_roam_sin"] = "U.v[10]"
        m["blur1_min"] = "U.v[11].x"; m["blur1_max"] = "U.v[11].y"; m["blur2_min"] = "U.v[11].z"; m["blur2_max"] = "U.v[11].w"
        m["blur3_min"] = "U.v[12].x"; m["blur3_max"] = "U.v[12].y"
        for q in 0..<32 { m["q\(q + 1)"] = "U.v[\(17 + q / 4)].\(["x", "y", "z", "w"][q % 4])" }
        for (i, n) in ["_qa", "_qb", "_qc", "_qd", "_qe", "_qf", "_qg", "_qh"].enumerated() { m[n] = "U.v[\(17 + i)]" }
        for (i, n) in rotNames.enumerated() { let b = 25 + i * 4; m[n] = "float4x4(U.v[\(b)], U.v[\(b + 1)], U.v[\(b + 2)], U.v[\(b + 3)])" }
        return m
    }()
    static let rotNames = (["s", "d", "f", "vf", "uf", "rand"]).flatMap { k in (1...4).map { "rot_\(k)\($0)" } }
    static func type(_ name: String) -> HType {
        if ["aspect", "texsize", "rand_frame", "rand_preset", "roam_cos", "roam_sin", "slow_roam_cos", "slow_roam_sin"].contains(name) || name.hasPrefix("_q") { return .vec(.float, 4) }
        if name.hasPrefix("rot_") { return .mat(4, 4) }
        return .float
    }
    // 13–16: hue_shader corner colours, 121–128: user texture sizes.
    static let hueBase = 13, userTexSizeBase = 121
}

/// Resolved Milkdrop sampler: which texture and which sampler state.
struct MDSampler {
    let texture: String   // tMain, tBlur1…, tNoiseLQ…, tVolLQ…, tUser0…
    let sampler: String   // sLW, sLC, sPW, sPC
    let dims: Int
}

final class HLSLTranslator {
    enum Stage { case warp, comp }
    let stage: Stage
    private(set) var userTextures: [String] = []   // names after "sampler_", in slot order (max 8)
    private var functions: [String: HFunc] = [:]
    private var globals: [String: Var] = [:]
    private var globalMembers: [(type: HType, name: String, array: HExpr?, value: HExpr?)] = []

    /// Array initializer items; HLSL also accepts a flat list of scalars for an array of vectors.
    private func arrayItems(_ items: [HExpr], _ t: HType) throws -> [String] {
        let xs = try items.map { try expr($0) }
        if t.size > 1, xs.allSatisfy({ $0.type.size == 1 }), xs.count % t.size == 0 {
            return stride(from: 0, to: xs.count, by: t.size).map { k in "\(t.msl)(" + xs[k..<(k + t.size)].map { convert($0, to: .float) }.joined(separator: ", ") + ")" }
        }
        return xs.map { convert($0, to: t) }
    }
    /// Local variables per block: HLSL name → type and the name used in Metal (renamed when redeclared).
    struct Var { var type: HType; var msl: String }
    private var scopes: [[String: Var]] = []
    private var renameCount = 0
    /// Names a local cannot take in Metal (keywords, our hidden parameters, functions it would shadow).
    private static let reserved: Set<String> = ["U", "in", "tMain", "tBlur1", "tBlur2", "tBlur3", "tNoiseLQ", "tNoiseMQ", "tNoiseHQ", "tVolLQ", "tVolHQ",
        "sLW", "sLC", "sPW", "sPC", "texture", "sampler", "kernel", "vertex", "fragment", "constant", "device", "thread", "threadgroup",
        "half", "select", "mix", "fract", "dot", "length", "distance", "normalize", "sample", "level", "bias", "min", "max", "abs", "sign",
        "clamp", "step", "smoothstep", "pow", "exp", "exp2", "log", "log2", "log10", "sin", "cos", "tan", "asin", "acos", "atan", "atan2",
        "sqrt", "rsqrt", "floor", "ceil", "round", "trunc", "fmod", "saturate", "cross", "reflect", "any", "all", "dfdx", "dfdy", "main",
        "metal", "using", "namespace", "struct", "class", "template", "typename", "operator", "new", "delete", "this", "friend", "public",
        "private", "protected", "virtual", "explicit", "auto", "char", "short", "long", "signed", "unsigned", "enum", "union", "typedef",
        "sizeof", "default", "case", "switch", "goto", "extern", "register", "ushort", "uchar", "size_t", "ptrdiff_t", "array", "vec",
        "matrix", "uint", "bool2", "access", "fwidth", "transpose", "determinant",
        "and", "or", "not", "xor", "bitand", "bitor", "compl", "and_eq", "or_eq", "xor_eq", "not_eq", "G", "MDGlobals", "MDU", "uv_orig_"]

    /// Declares a local in the current block, renaming it when it would clash.
    private func declare(_ name: String, _ type: HType) -> String {
        var msl = name
        if HLSLTranslator.reserved.contains(name) || scopes.last?[name] != nil || scopes.dropLast().contains(where: { $0[name] != nil }) && inMain && scopes.count == 1 {
            renameCount += 1
            msl = "\(name)_\(renameCount)"
        }
        scopes[scopes.count - 1][name] = Var(type: type, msl: msl)
        return msl
    }

    /// Identifiers a list of statements assigns to (to give writable copies of Milkdrop's uniforms).
    private func assigned(_ list: [HStmt]) -> Set<String> {
        var out = Set<String>()
        func base(_ e: HExpr) -> String? {
            switch e {
            case .ident(let n): return n
            case .member(let b, _), .index(let b, _): return base(b)
            default: return nil
            }
        }
        func walkE(_ e: HExpr) {
            switch e {
            case .assign(_, let l, let r): if let b = base(l) { out.insert(b) }; walkE(l); walkE(r)
            case .unary(let o, let a): if o == "++" || o == "--", let b = base(a) { out.insert(b) }; walkE(a)
            case .postfix(_, let a): if let b = base(a) { out.insert(b) }; walkE(a)
            case .binary(_, let a, let b): walkE(a); walkE(b)
            case .ternary(let a, let b, let c): walkE(a); walkE(b); walkE(c)
            case .call(_, let xs), .initList(let xs): xs.forEach(walkE)
            case .member(let a, _), .cast(_, let a): walkE(a)
            case .index(let a, let b): walkE(a); walkE(b)
            default: break
            }
        }
        func walkS(_ s: HStmt) {
            switch s {
            case .expr(let e): walkE(e)
            case .decl(_, let vars, _, _): vars.forEach { if let v = $0.value { walkE(v) } }
            case .ifS(let c, let a, let b): walkE(c); walkS(a); if let b { walkS(b) }
            case .forS(let i, let c, let st, let b): if let i { walkS(i) }; if let c { walkE(c) }; if let st { walkE(st) }; walkS(b)
            case .whileS(let c, let b): walkE(c); walkS(b)
            case .doS(let b, let c): walkS(b); walkE(c)
            case .ret(let e): if let e { walkE(e) }
            case .block(let l): l.forEach(walkS)
            default: break
            }
        }
        list.forEach(walkS)
        return out
    }

    /// `float q1 = U.v[17].x;` for every uniform the code writes to (HLSL lets shaders modify their copy).
    private func uniformShadows(_ body: [HStmt], indent: String) -> String {
        var out = ""
        for n in assigned(body).sorted() where lookup(n) == nil {
            guard let f = MDUniforms.fields[n] else { continue }
            let t = MDUniforms.type(n)
            let msl = declare(n, t)
            out += indent + "\(t.msl) \(msl) = \(f);\n"
        }
        return out
    }
    private var inMain = false
    private var currentReturn: HType = .void
    var usesBlur = false

    init(stage: Stage) { self.stage = stage }

    static let envParams = "constant MDU& U, texture2d<float> tMain, texture2d<float> tBlur1, texture2d<float> tBlur2, texture2d<float> tBlur3, " +
        "texture2d<float> tNoiseLQ, texture2d<float> tNoiseMQ, texture2d<float> tNoiseHQ, texture3d<float> tVolLQ, texture3d<float> tVolHQ, " +
        (0..<8).map { "texture2d<float> tUser\($0)" }.joined(separator: ", ") + ", sampler sLW, sampler sLC, sampler sPW, sampler sPC, thread MDGlobals& G"
    static let envArgs = "U, tMain, tBlur1, tBlur2, tBlur3, tNoiseLQ, tNoiseMQ, tNoiseHQ, tVolLQ, tVolHQ, " +
        (0..<8).map { "tUser\($0)" }.joined(separator: ", ") + ", sLW, sLC, sPW, sPC, G"

    /// Full MSL fragment function `entry` for one shader.
    func translate(_ source: String, entry: String) throws -> String {
        var p = try HLSLParser(source)
        let sh = try p.parseShader()
        var out = ""
        // Globals: constants become Metal constants; anything else is set up at the top of the main body.
        for g in sh.globals {
            guard case .decl(let t, let vars, let isConst, _) = g else { continue }
            guard let ty = HType.parse(t) else { continue }
            if case .sampler = ty {
                for v in vars { _ = sampler(v.name) }   // registers user textures
                continue
            }
            for v in vars where !v.name.hasPrefix("texsize_") && MDUniforms.fields[v.name] == nil && v.name != "g_fTexSize" {
                if isConst, let val = v.value, v.array == nil {
                    scopes = [[:]]
                    let e = try expr(val)
                    let code = convert(e, to: ty)
                    if !code.contains("U.") && !code.contains(".sample(") && !code.contains("G.") {
                        out += "constant \(ty.msl) \(v.name) = \(code);\n"
                        globals[v.name] = Var(type: ty, msl: v.name)
                        continue
                    }
                }
                // Everything else lives in a struct G set up by the main body and passed to helper functions
                // (Metal has no mutable or uniform-dependent globals).
                globalMembers.append((ty, v.name, v.array, v.value))
                globals[v.name] = Var(type: ty, msl: "G.\(v.name)")
                if v.array != nil { arrays.insert("G.\(v.name)") }
            }
        }
        scopes = [[:]]
        out += "struct MDGlobals { int _unused;" + (try globalMembers.map { m -> String in
            if let a = m.array { return " \(m.type.msl) \(m.name)[\(try expr(a).code)];" }
            return " \(m.type.msl) \(m.name);"
        }).joined() + " };\n"
        for f in sh.functions {
            functions[f.name] = f
            out += try function(f)
        }
        inMain = true
        scopes = [mainLocals()]
        currentReturn = .void
        var mainPrelude = "    MDGlobals G; G._unused = 0;\n"
        for m in globalMembers {
            if let a = m.array {
                let n = try expr(a).code
                if case .initList(let items)? = m.value {
                    for (k, item) in try arrayItems(items, m.type).enumerated() { mainPrelude += "    G.\(m.name)[\(k)] = \(item);\n" }
                } else {
                    mainPrelude += "    for (int _i = 0; _i < \(n); _i++) G.\(m.name)[_i] = \(m.type.msl)(0);\n"
                }
            } else if let val = m.value {
                mainPrelude += "    G.\(m.name) = \(convert(try expr(val), to: m.type));\n"
            } else if m.type.isNumeric || { if case .mat = m.type { return true }; return false }() {
                mainPrelude += "    G.\(m.name) = \(m.type.msl)(0);\n"
            }
        }
        mainPrelude += uniformShadows(sh.body, indent: "    ")
        var body = ""
        for s in sh.body { body += try stmt(s, indent: "    ") }
        let isWarp = stage == .warp
        out += """
        fragment float4 \(entry)(MDOut in [[stage_in]], \(HLSLTranslator.fragParams)) {
            float2 uv = in.uv;
            float2 uv_orig = in.uvOrig;
            float2 _c = (uv_orig - 0.5) * U.v[3].xy;
            float rad = length(_c);
            float ang = atan2(_c.y, _c.x);
            float3 ret = float3(0);
            float3 hue_shader = mix(mix(U.v[13].xyz, U.v[14].xyz, uv_orig.x), mix(U.v[15].xyz, U.v[16].xyz, uv_orig.x), uv_orig.y);
            (void)rad; (void)ang; (void)hue_shader;\(isWarp ? "" : "")
        \(mainPrelude)\(body)    return float4(ret, 1);
        }

        """
        return out
    }

    static let fragParams = "constant MDU& U [[buffer(0)]], texture2d<float> tMain [[texture(0)]], texture2d<float> tBlur1 [[texture(1)]], " +
        "texture2d<float> tBlur2 [[texture(2)]], texture2d<float> tBlur3 [[texture(3)]], texture2d<float> tNoiseLQ [[texture(4)]], " +
        "texture2d<float> tNoiseMQ [[texture(5)]], texture2d<float> tNoiseHQ [[texture(6)]], texture3d<float> tVolLQ [[texture(7)]], " +
        "texture3d<float> tVolHQ [[texture(8)]], " + (0..<8).map { "texture2d<float> tUser\($0) [[texture(\(9 + $0))]]" }.joined(separator: ", ") +
        ", sampler sLW [[sampler(0)]], sampler sLC [[sampler(1)]], sampler sPW [[sampler(2)]], sampler sPC [[sampler(3)]]"

    private func mainLocals() -> [String: Var] {
        let l: [String: HType] = ["uv": .f(2), "uv_orig": .f(2), "rad": .float, "ang": .float, "ret": .f(3), "hue_shader": .f(3)]
        return l.mapValues { Var(type: $0, msl: "") }.reduce(into: [:]) { $0[$1.key] = Var(type: $1.value.type, msl: $1.key) }
    }

    private func function(_ f: HFunc) throws -> String {
        guard let rt = HType.parse(f.ret) else { throw HLSLError.unsupported("tipo \(f.ret)") }
        var params: [String] = []
        var scope: [String: Var] = [:]
        for p in f.params {
            guard let t = HType.parse(p.type) else { throw HLSLError.unsupported("tipo \(p.type)") }
            if case .sampler = t { throw HLSLError.unsupported("sampler come parametro di \(f.name)") }
            let msl = HLSLTranslator.reserved.contains(p.name) ? p.name + "_p" : p.name
            params.append(p.qual == "out" || p.qual == "inout" ? "thread \(t.msl)& \(msl)" : "\(t.msl) \(msl)")
            scope[p.name] = Var(type: t, msl: msl)
        }
        params.append(HLSLTranslator.envParams)
        scopes = [scope]
        currentReturn = rt
        inMain = false
        var body = uniformShadows(f.body, indent: "    ")
        for s in f.body { body += try stmt(s, indent: "    ") }
        return "static \(rt.msl) \(f.name)(\(params.joined(separator: ", "))) {\n\(body)}\n"
    }

    // MARK: Statements

    private func stmt(_ s: HStmt, indent: String) throws -> String {
        switch s {
        case .empty: return ""
        case .brk: return indent + "break;\n"
        case .cont: return indent + "continue;\n"
        case .expr(let e): return indent + (try expr(e)).code + ";\n"
        case .ret(let e):
            if inMain { return indent + "return float4(ret, 1);\n" }
            guard let e else { return indent + "return;\n" }
            return indent + "return \(convert(try expr(e), to: currentReturn));\n"
        case .block(let list):
            scopes.append([:])
            defer { scopes.removeLast() }
            var out = indent + "{\n"
            for x in list { out += try stmt(x, indent: indent + "    ") }
            return out + indent + "}\n"
        case .ifS(let c, let a, let b):
            var out = indent + "if (\(convert(try expr(c), to: .scalar(.bool))))\n" + (try stmt(wrap(a), indent: indent))
            if let b { out += indent + "else\n" + (try stmt(wrap(b), indent: indent)) }
            return out
        case .whileS(let c, let b):
            return indent + "while (\(convert(try expr(c), to: .scalar(.bool))))\n" + (try stmt(wrap(b), indent: indent))
        case .doS(let b, let c):
            return indent + "do\n" + (try stmt(wrap(b), indent: indent)) + indent + "while (\(convert(try expr(c), to: .scalar(.bool))));\n"
        case .forS(let i, let c, let st, let b):
            scopes.append([:])
            defer { scopes.removeLast() }
            var initCode = ""
            if let i { initCode = try stmt(i, indent: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            if !initCode.hasSuffix(";") { initCode += ";" }
            let cond = try c.map { convert(try expr($0), to: .scalar(.bool)) } ?? ""
            let step = try st.map { try expr($0).code } ?? ""
            return indent + "for (\(initCode) \(cond); \(step))\n" + (try stmt(wrap(b), indent: indent))
        case .decl(let t, let vars, let isConst, _):
            guard let ty = HType.parse(t) else { throw HLSLError.unsupported("tipo \(t)") }
            var out = ""
            for v in vars {
                if let a = v.array {
                    let n = try expr(a).code
                    let msl = declare(v.name, ty)
                    var line = indent + "\(ty.msl) \(msl)[\(n)]"
                    if case .initList(let items)? = v.value { line += " = {" + (try arrayItems(items, ty)).joined(separator: ", ") + "}" }
                    out += line + ";\n"
                    arrays.insert(msl)
                    continue
                }
                // The initializer is read before the name is declared (float3 x = x; refers to the outer x).
                var initCode = ""
                if let val = v.value {
                    if case .initList(let items) = val {
                        initCode = " = \(ty.msl)(" + (try items.map { try expr($0).code }).joined(separator: ", ") + ")"
                    } else {
                        initCode = " = " + convert(try expr(val), to: ty)
                    }
                } else if ty.isNumeric {
                    initCode = " = \(ty.msl)(0)"
                }
                let msl = declare(v.name, ty)
                out += indent + (isConst ? "const " : "") + "\(ty.msl) \(msl)" + initCode + ";\n"
            }
            return out
        }
    }

    private var arrays = Set<String>()

    private func wrap(_ s: HStmt) -> HStmt {
        if case .block = s { return s }
        return .block([s])
    }

    // MARK: Expressions

    struct Out { var code: String; var type: HType }

    private func lookup(_ name: String) -> Var? {
        for s in scopes.reversed() { if let v = s[name] { return v } }
        return globals[name]
    }

    /// Converts a typed expression to `to`, HLSL style: truncate, splat, cast between int/float/bool.
    func convert(_ e: Out, to: HType) -> String {
        let from = e.type
        if from == to || to == .unknown || from == .unknown || to == .void { return e.code }
        switch (from, to) {
        case (.vec(_, let n), .vec(let k, let m)):
            let sw = String("xyzw".prefix(min(n, m)))
            if m < n { return k == from.kind ? "(\(e.code)).\(sw)" : "\(to.msl)((\(e.code)).\(sw))" }
            if m > n { return "\(to.msl)(\(e.code)\(String(repeating: ", 0", count: m - n)))" }
            return "\(to.msl)(\(e.code))"
        case (.scalar, .vec): return "\(to.msl)(\(e.code))"
        case (.vec, .scalar): return to == .float ? "(\(e.code)).x" : "\(to.msl)((\(e.code)).x)"
        case (.scalar, .scalar): return "\(to.msl)(\(e.code))"
        case (.mat(let r1, let c1), .mat(let r2, let c2)) where r2 <= r1 && c2 <= c1:
            // HLSL (float3x3)m4x4 keeps the upper-left block; Metal stores rows as columns here.
            let sw = String("xyzw".prefix(c2))
            return "\(to.msl)(" + (0..<r2).map { "(\(e.code))[\($0)].\(sw)" }.joined(separator: ", ") + ")"
        default: return e.code
        }
    }

    private func numericWidest(_ a: HType, _ b: HType) -> HType {
        // HLSL: two vectors of different size → the smaller one; scalar with vector → the vector.
        let k: HType.Kind = (a.kind == .float || b.kind == .float) ? .float : (a.kind ?? .float)
        let n: Int
        switch (a.size, b.size) {
        case (1, let y): n = y
        case (let x, 1): n = x
        case (let x, let y): n = min(x, y)
        }
        if case .mat = a { return a }
        if case .mat = b { return b }
        guard n > 0 else { return .unknown }
        return n == 1 ? .scalar(k) : .vec(k, n)
    }

    func expr(_ e: HExpr) throws -> Out {
        switch e {
        case .num(let n, let isInt):
            if n == "true" || n == "false" { return Out(code: n, type: .scalar(.bool)) }
            return Out(code: n, type: isInt ? .scalar(.int) : .float)
        case .initList(let items):
            return Out(code: "{" + (try items.map { try expr($0).code }).joined(separator: ", ") + "}", type: .unknown)
        case .ident(let name):
            if let v = lookup(name) { return Out(code: v.msl, type: v.type) }
            if let f = MDUniforms.fields[name] { return Out(code: f, type: MDUniforms.type(name)) }
            if name == "g_fTexSize" { return Out(code: "U.v[4]", type: .f(4)) }
            if name.hasPrefix("texsize_") {
                let tex = String(name.dropFirst(8))
                if let i = userIndex(tex) { return Out(code: "U.v[\(MDUniforms.userTexSizeBase + i)]", type: .f(4)) }
                return Out(code: "float4(256, 256, 1.0/256, 1.0/256)", type: .f(4))
            }
            switch name {
            case "M_PI": return Out(code: "M_PI_F", type: .float)
            case "M_PI_2": return Out(code: "M_PI_2_F", type: .float)
            case "M_INV_PI_2": return Out(code: "(0.5 / M_PI_F)", type: .float)
            case "M_PI_4": return Out(code: "M_PI_4_F", type: .float)
            default: return Out(code: name, type: .unknown)   // maybe a #define
            }
        case .member(let b, let m):
            let base = try expr(b)
            let valid = m.allSatisfy { "xyzwrgba".contains($0) } && m.count <= 4
            guard valid else { return Out(code: "\(base.code).\(m)", type: .unknown) }
            let sw = String(m.map { c -> Character in ["r": "x", "g": "y", "b": "z", "a": "w"][c] ?? c })
            if case .scalar(let k) = base.type {
                // HLSL allows x.xxx on scalars.
                return m.count == 1 ? base : Out(code: "\(HType.vec(k, m.count).msl)(\(base.code))", type: .vec(k, m.count))
            }
            let k = base.type.kind ?? .float
            return Out(code: "(\(base.code)).\(sw)", type: m.count == 1 ? .scalar(k) : .vec(k, m.count))
        case .index(let b, let i):
            let base = try expr(b), idx = try expr(i)
            var t = HType.unknown
            if arrays.contains(base.code) {
                return Out(code: "\(base.code)[\(convert(idx, to: .scalar(.int)))]", type: base.type)   // element of an array
            }
            switch base.type {
            case .vec(let k, _): t = .scalar(k)
            case .mat(_, let c): t = .f(c)
            default:
                if arrays.contains(base.code) { t = base.type }
            }
            return Out(code: "\(base.code)[\(convert(idx, to: .scalar(.int)))]", type: t)
        case .unary(let o, let a):
            let x = try expr(a)
            if case .mat = x.type, o == "-" { return Out(code: "(\(x.code) * -1.0)", type: x.type) }
            if o == "!" { return Out(code: "(!\(convert(x, to: x.type.size > 1 ? x.type : .scalar(.bool))))", type: x.type.size > 1 ? .vec(.bool, x.type.size) : .scalar(.bool)) }
            return Out(code: "(\(o)\(x.code))", type: x.type)
        case .postfix(let o, let a):
            let x = try expr(a)
            return Out(code: "(\(x.code)\(o))", type: x.type)
        case .cast(let t, let a):
            guard let ty = HType.parse(t) else { throw HLSLError.unsupported("cast a \(t)") }
            return Out(code: convert(try expr(a), to: ty), type: ty)
        case .ternary(let c, let a, let b):
            let cc = try expr(c), x = try expr(a), y = try expr(b)
            let t = numericWidest(x.type, y.type)
            if cc.type.size > 1 {
                // Component-wise: select(false-value, true-value, condition).
                return Out(code: "select(\(convert(y, to: t)), \(convert(x, to: t)), \(convert(cc, to: .vec(.bool, t.size))))", type: t)
            }
            return Out(code: "(\(convert(cc, to: .scalar(.bool))) ? \(convert(x, to: t)) : \(convert(y, to: t)))", type: t)
        case .assign(let o, let l, let r):
            let lhs = try expr(l), rhs = try expr(r)
            let target = lhs.type
            if o == "*=", case .mat = target { return Out(code: "(\(lhs.code) = \(lhs.code) * \(rhs.code))", type: target) }
            let value: String
            if ["+=", "-=", "*=", "/=", "%="].contains(o), rhs.type.size == 1, target.size > 1 {
                value = "\(target.msl)(\(rhs.code))"
            } else {
                value = convert(rhs, to: target)
            }
            if o == "%=" { return Out(code: "(\(lhs.code) = fmod(\(lhs.code), \(value)))", type: target) }
            return Out(code: "(\(lhs.code) \(o) \(value))", type: target)
        case .binary(let o, let a, let b):
            let x = try expr(a), y = try expr(b)
            if o == "," { return Out(code: "(\(x.code), \(y.code))", type: y.type) }
            if o == "&&" || o == "||" {
                return Out(code: "(\(convert(x, to: .scalar(.bool))) \(o) \(convert(y, to: .scalar(.bool))))", type: .scalar(.bool))
            }
            if case .mat = y.type, x.type.size == 1, o == "*" { return Out(code: "(\(y.code) * \(convert(x, to: .float)))", type: y.type) }
            if case .mat = x.type, y.type.size == 1, ["*", "/"].contains(o) { return Out(code: "(\(x.code) \(o) \(convert(y, to: .float)))", type: x.type) }
            if case .mat = x.type, o == "*" {
                // HLSL * is component-wise even for matrices; rare in presets, keep Metal's meaning.
                return Out(code: "(\(x.code) * \(y.code))", type: x.type)
            }
            let t = numericWidest(x.type, y.type)
            let isCompare = ["<", ">", "<=", ">=", "==", "!="].contains(o)
            if t == .unknown { return Out(code: "(\(x.code) \(o) \(y.code))", type: isCompare ? .scalar(.bool) : .unknown) }
            // Operands to a common type (scalars stay scalars, Metal promotes them).
            func side(_ s: Out) -> String {
                if s.type.size == 1, t.size > 1 { return s.type.kind == t.kind ? s.code : "\(t.kind == .float ? "float" : "int")(\(s.code))" }
                return convert(s, to: t)
            }
            if o == "%" { return Out(code: "fmod(\(convert(x, to: t.kind == .int ? HType.f(t.size) : t)), \(convert(y, to: t.kind == .int ? HType.f(t.size) : t)))", type: t.kind == .int ? .f(t.size) : t) }
            if isCompare { return Out(code: "(\(side(x)) \(o) \(side(y)))", type: t.size > 1 ? .vec(.bool, t.size) : .scalar(.bool)) }
            return Out(code: "(\(side(x)) \(o) \(side(y)))", type: t)
        case .call(let name, let args):
            return try call(name, args)
        }
    }

    private func userIndex(_ tex: String) -> Int? {
        if let i = userTextures.firstIndex(of: tex) { return i }
        guard userTextures.count < 8 else { return nil }
        userTextures.append(tex)
        return userTextures.count - 1
    }

    /// `sampler_fw_main`, `sampler_blur2`, `sampler_pw_noise_lq`, `sampler_clouds`… → texture + sampler state.
    func sampler(_ raw: String) -> MDSampler {
        var n = raw.lowercased()
        if n.hasPrefix("sampler_") { n.removeFirst(8) }
        var filter: Character?, wrap: Character?
        for p in ["fw_", "fc_", "pw_", "pc_"] where n.hasPrefix(p) {
            filter = p.first
            wrap = Array(p)[1]
            n.removeFirst(3)
        }
        func state(_ defF: Character, _ defW: Character) -> String {
            let f = filter ?? defF, w = wrap ?? defW
            return "s" + (f == "p" ? "P" : "L") + (w == "c" ? "C" : "W")
        }
        switch n {
        case "main": return MDSampler(texture: "tMain", sampler: state("f", "w"), dims: 2)
        case "blur1", "blur2", "blur3":
            usesBlur = true
            return MDSampler(texture: "tBlur" + String(n.last!), sampler: state("f", "c"), dims: 2)
        case "noise_lq", "noise_lq_lite": return MDSampler(texture: "tNoiseLQ", sampler: state("f", "w"), dims: 2)
        case "noise_mq": return MDSampler(texture: "tNoiseMQ", sampler: state("f", "w"), dims: 2)
        case "noise_hq": return MDSampler(texture: "tNoiseHQ", sampler: state("f", "w"), dims: 2)
        case "noisevol_lq": return MDSampler(texture: "tVolLQ", sampler: state("f", "w"), dims: 3)
        case "noisevol_hq": return MDSampler(texture: "tVolHQ", sampler: state("f", "w"), dims: 3)
        default:
            guard let i = userIndex(n) else { return MDSampler(texture: "tNoiseHQ", sampler: state("f", "w"), dims: 2) }
            return MDSampler(texture: "tUser\(i)", sampler: state("f", "w"), dims: 2)
        }
    }

    private func samplerArg(_ e: HExpr) throws -> MDSampler {
        guard case .ident(let n) = e else { throw HLSLError.unsupported("sampler non diretto") }
        return sampler(n)
    }

    /// HLSL intrinsics are matched without case (presets write tex2d, Tex2D…); user functions keep theirs.
    private static let canonical: [String: String] = {
        let names = ["tex2D", "tex2Dlod", "tex2Dbias", "tex2Dgrad", "tex3D", "tex3Dlod", "GetMain", "GetPixel", "GetBlur1", "GetBlur2", "GetBlur3",
                     "lum", "mul", "sincos", "lerp", "frac", "saturate", "rsqrt", "ddx", "ddy", "log", "exp", "exp2", "log2", "log10", "sqrt",
                     "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "floor", "ceil", "round", "trunc", "abs", "sign",
                     "normalize", "fwidth", "degrees", "radians", "pow", "min", "max", "fmod", "atan2", "step", "reflect", "clamp",
                     "smoothstep", "fma", "ldexp", "dot", "length", "distance", "cross", "any", "all", "transpose", "determinant", "noise"]
        return Dictionary(uniqueKeysWithValues: names.map { ($0.lowercased(), $0) })
    }()

    private func call(_ rawName: String, _ args: [HExpr]) throws -> Out {
        let name = functions[rawName] != nil ? rawName : (HLSLTranslator.canonical[rawName.lowercased()] ?? rawName)
        // Constructors.
        if let t = HType.parse(name), t.isNumeric || { if case .mat = t { return true }; return false }() {
            let xs = try args.map { try expr($0) }
            if xs.count == 1, t.size > 0 || { if case .mat = t { return true }; return false }() {
                if case .mat(let r, let c) = t {
                    let x = xs[0]
                    if x.type.size == r * c, x.type.size > 1 {
                        // float2x2(v4): rows from consecutive components.
                        let comps = Array("xyzw")
                        let rows = (0..<r).map { i in "(\(x.code)).\(String(comps[(i * c)..<(i * c + c)]))" }
                        return Out(code: "\(t.msl)(\(rows.joined(separator: ", ")))", type: t)
                    }
                    if x.type.size == 1 { return Out(code: "\(t.msl)(\(Array(repeating: convert(x, to: .float), count: r * c).joined(separator: ", ")))", type: t) }
                    return Out(code: convert(x, to: t), type: t)
                }
                if xs[0].type.size >= t.size || xs[0].type.size == 1 { return Out(code: convert(xs[0], to: t), type: t) }
            }
            let k = t.kind ?? .float
            let parts = xs.map { x -> String in
                guard let xk = x.type.kind, xk != k else { return x.code }
                return x.type.size > 1 ? "\(HType.vec(k, x.type.size).msl)(\(x.code))" : "\(HType.scalar(k).msl)(\(x.code))"
            }
            return Out(code: "\(t.msl)(\(parts.joined(separator: ", ")))", type: t)
        }
        let xs = { () throws -> [Out] in try args.map { try self.expr($0) } }
        switch name {
        case "tex2D", "tex2Dlod", "tex2Dbias", "tex2Dgrad", "tex3D", "tex3Dlod":
            guard args.count >= 2 else { throw HLSLError.parse("\(name) senza coordinate") }
            let s = try samplerArg(args[0])
            let uv = try expr(args[1])
            let is3 = name.hasPrefix("tex3D")
            if is3 != (s.dims == 3) {
                // 2D sampler read with 3D coords (or vice versa): use what fits.
                let c = convert(uv, to: .f(s.dims))
                return Out(code: "\(s.texture).sample(\(s.sampler), \(c))", type: .f(4))
            }
            if name.hasSuffix("lod") {
                let c = convert(uv, to: .f(4))
                return Out(code: "\(s.texture).sample(\(s.sampler), (\(c)).\(is3 ? "xyz" : "xy"), level((\(c)).w))", type: .f(4))
            }
            if name == "tex2Dbias" {
                let c = convert(uv, to: .f(4))
                return Out(code: "\(s.texture).sample(\(s.sampler), (\(c)).xy, bias((\(c)).w))", type: .f(4))
            }
            return Out(code: "\(s.texture).sample(\(s.sampler), \(convert(uv, to: .f(is3 ? 3 : 2))))", type: .f(4))
        case "GetMain", "GetPixel":
            let uv = try expr(args.first ?? .num("0", isInt: false))
            return Out(code: "tMain.sample(\(name == "GetPixel" ? "sPC" : "sLW"), \(convert(uv, to: .f(2)))).xyz", type: .f(3))
        case "GetBlur1", "GetBlur2", "GetBlur3":
            usesBlur = true
            let uv = try expr(args.first ?? .num("0", isInt: false))
            return Out(code: "tBlur\(name.last!).sample(sLC, \(convert(uv, to: .f(2)))).xyz", type: .f(3))
        case "lum":
            let x = try expr(args[0])
            return Out(code: "dot(\(convert(x, to: .f(3))), float3(0.32, 0.49, 0.29))", type: .float)
        case "mul":
            guard args.count == 2 else { throw HLSLError.parse("mul") }
            let a = try expr(args[0]), b = try expr(args[1])
            var t = HType.unknown
            switch (a.type, b.type) {
            case (.vec(_, let n), .mat(let r, let c)):   // row vector × matrix
                let v = n == r ? a.code : convert(a, to: .f(r))
                return Out(code: "(\(b.code) * \(v))", type: .f(c))
            case (.mat(let r, let c), .vec(_, let n)):
                let v = n == c ? b.code : convert(b, to: .f(c))
                return Out(code: "(\(v) * \(a.code))", type: .f(r))
            case (.mat(let r, _), .mat(_, let c)): t = .mat(r, c)
            case (.vec(_, let n), .vec(_, let m)):   // vector · vector = dot product
                let tf = HType.f(min(n, m))
                return Out(code: "dot(\(convert(a, to: tf)), \(convert(b, to: tf)))", type: .float)
            case (.scalar, _): t = b.type
            case (_, .scalar): t = a.type
            default: break
            }
            return Out(code: "(\(b.code) * \(a.code))", type: t)
        case "sincos":
            guard args.count == 3 else { throw HLSLError.parse("sincos") }
            let x = try expr(args[0]), s = try expr(args[1]), c = try expr(args[2])
            return Out(code: "(\(s.code) = sin(\(x.code)), \(c.code) = cos(\(x.code)))", type: .void)
        default: break
        }
        // User functions get the hidden Milkdrop environment.
        if let f = functions[name] {
            let a = try xs()
            var parts: [String] = []
            for (i, p) in f.params.enumerated() where i < a.count {
                let pt = HType.parse(p.type) ?? .unknown
                parts.append(p.qual == "out" || p.qual == "inout" ? a[i].code : convert(a[i], to: pt))
            }
            parts.append(HLSLTranslator.envArgs)
            return Out(code: "\(name)(\(parts.joined(separator: ", ")))", type: HType.parse(f.ret) ?? .unknown)
        }
        // Intrinsics.
        let a = try xs()
        func same(_ msl: String) -> Out {
            // All arguments to one common type (HLSL picks the smaller vector).
            var t = a.first?.type ?? .float
            for x in a.dropFirst() { t = numericWidest(t, x.type) }
            if t == .unknown || !t.isNumeric { return Out(code: "\(msl)(\(a.map(\.code).joined(separator: ", ")))", type: t) }
            if t.kind == .int { t = .f(t.size) }   // Metal's math functions are float
            return Out(code: "\(msl)(\(a.map { convert($0, to: t) }.joined(separator: ", ")))", type: t)
        }
        func unaryF(_ msl: String) -> Out {
            guard let x = a.first else { return Out(code: "\(msl)()", type: .unknown) }
            let t = x.type.kind == .int || x.type.kind == .bool ? HType.f(max(1, x.type.size)) : x.type
            return Out(code: "\(msl)(\(convert(x, to: t)))", type: t)
        }
        switch name {
        case "lerp":
            guard a.count == 3 else { throw HLSLError.parse("lerp") }
            var t = numericWidest(a[0].type, a[1].type)
            if t.size == 1, a[2].type.size > 1 { t = .f(a[2].type.size) }
            if t.kind == .int { t = .f(t.size) }
            let w = a[2].type.size == 1 ? convert(a[2], to: .float) : convert(a[2], to: t)
            return Out(code: "mix(\(convert(a[0], to: t)), \(convert(a[1], to: t)), \(w))", type: t)
        case "frac": return unaryF("fract")
        case "saturate": return unaryF("saturate")
        case "rsqrt": return unaryF("rsqrt")
        case "ddx": return unaryF("dfdx")
        case "ddy": return unaryF("dfdy")
        case "log": return unaryF("log")
        case "normalize" where a.first?.type.size == 1:
            return Out(code: "sign(\(convert(a[0], to: .float)))", type: .float)
        case "exp", "exp2", "log2", "log10", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
             "floor", "ceil", "round", "trunc", "abs", "sign", "normalize", "fwidth":
            if name == "abs" || name == "sign", let x = a.first, x.type.kind == .int {
                return Out(code: "\(name)(\(x.code))", type: x.type)
            }
            return unaryF(name == "fwidth" ? "fwidth" : name)
        case "degrees", "radians": return unaryF(name)
        case "pow", "min", "max", "fmod", "atan2", "step", "reflect", "clamp", "smoothstep", "fma", "ldexp":
            if name == "pow" && a.count == 2 {
                // HLSL pow of a negative base gives NaN too; keep it, but avoid Metal's undefined overloads.
                var t = numericWidest(a[0].type, a[1].type)
                if t.kind == .int { t = .f(t.size) }
                let base = convert(a[0], to: t)
                let e = a[1].type.size == 1 && t.size > 1 ? "\(t.msl)(\(convert(a[1], to: .float)))" : convert(a[1], to: t)
                return Out(code: "pow(\(base), \(e))", type: t)
            }
            if name == "step" || name == "smoothstep" || name == "clamp" {
                // Scalars next to vectors are splatted by `same`.
                return same(name)
            }
            return same(name)
        case "dot":
            guard a.count == 2 else { throw HLSLError.parse("dot") }
            let t = numericWidest(a[0].type, a[1].type)
            let tf = HType.f(max(2, t.size))
            return Out(code: "dot(\(convert(a[0], to: tf)), \(convert(a[1], to: tf)))", type: .float)
        case "length":
            guard let x = a.first else { throw HLSLError.parse("length") }
            if x.type.size == 1 { return Out(code: "abs(\(convert(x, to: .float)))", type: .float) }
            return Out(code: "length(\(x.code))", type: .float)
        case "distance":
            guard a.count == 2 else { throw HLSLError.parse("distance") }
            let t = numericWidest(a[0].type, a[1].type)
            if t.size == 1 { return Out(code: "abs(\(convert(a[0], to: .float)) - \(convert(a[1], to: .float)))", type: .float) }
            return Out(code: "distance(\(convert(a[0], to: t)), \(convert(a[1], to: t)))", type: .float)
        case "cross":
            return Out(code: "cross(\(convert(a[0], to: .f(3))), \(convert(a[1], to: .f(3))))", type: .f(3))
        case "any", "all":
            guard let x = a.first else { throw HLSLError.parse(name) }
            if x.type.size == 1 { return Out(code: "bool(\(x.code))", type: .scalar(.bool)) }
            return Out(code: "\(name)(\(convert(x, to: .vec(.bool, x.type.size))))", type: .scalar(.bool))
        case "transpose":
            return Out(code: "transpose(\(a[0].code))", type: a[0].type)
        case "determinant":
            return Out(code: "determinant(\(a[0].code))", type: .float)
        case "noise":
            return Out(code: "tNoiseHQ.sample(sLW, \(convert(a[0], to: .f(2)))).x", type: .float)
        default:
            // Unknown function: maybe a #define macro; pass through untyped.
            return Out(code: "\(name)(\(a.map(\.code).joined(separator: ", ")))", type: .unknown)
        }
    }
}

/// Shared MSL preamble for preset shaders: the uniform block and the vertex stages.
enum MDShaderPrelude {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct MDU { float4 v[\(MDUniforms.count)]; };
    struct MDOut { float4 pos [[position]]; float2 uv; float2 uvOrig; };
    struct MDWarpIn { packed_float2 pos; packed_float2 uv; };
    vertex MDOut md_warp_v(const device MDWarpIn* v [[buffer(0)]], uint id [[vertex_id]]) {
        MDOut o;
        float2 p = float2(v[id].pos);
        o.pos = float4(p, 0, 1);
        o.uv = float2(v[id].uv);
        o.uvOrig = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
        return o;
    }
    vertex MDOut md_comp_v(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        MDOut o;
        o.pos = float4(p * 2 - 1, 0, 1);
        o.uv = float2(p.x, 1 - p.y);
        o.uvOrig = o.uv;
        return o;
    }

    """
}
