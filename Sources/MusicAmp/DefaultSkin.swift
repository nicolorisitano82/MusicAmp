import AppKit

/// Procedurally drawn fallback skin. Every sheet follows the classic Winamp sprite layout,
/// so it can stand in for any bitmap a loaded skin is missing.
enum DefaultSkin {
    static func C(_ h: UInt32) -> CGColor { rgb(Int((h >> 16) & 255), Int((h >> 8) & 255), Int(h & 255)) }
    static func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
        func ch(_ v: UInt32, _ s: UInt32) -> CGFloat { CGFloat((v >> s) & 255) }
        let t = max(0, min(1, t))
        return CGColor(srgbRed: (ch(a, 16) + (ch(b, 16) - ch(a, 16)) * t) / 255,
                       green: (ch(a, 8) + (ch(b, 8) - ch(a, 8)) * t) / 255,
                       blue: (ch(a, 0) + (ch(b, 0) - ch(a, 0)) * t) / 255, alpha: 1)
    }
    static func heat(_ t: CGFloat) -> CGColor { t < 0.5 ? mix(0x30C840, 0xE0D030, t * 2) : mix(0xE0D030, 0xE04020, (t - 0.5) * 2) }

    static let face = C(0x3B3F4C), light = C(0x646A7E), dark = C(0x1B1D24)
    static let lcd = C(0x070A08), lcdText = C(0x3CE060), lcdDim = C(0x1A4626)
    static let titleA = C(0x2C4F8F), titleAHi = C(0x4A73C0), titleI = C(0x34363F)
    static let titleText = C(0xE8ECF4), titleTextI = C(0x8A8F9C)
    static let btnFace = C(0x4B5060), btnDown = C(0x2A2D36), icon = C(0xD8DCE6), led = C(0x3CE060)

    static let font: [Character: [String]] = {
        let src = #"""
        A .#. #.# ### #.# #.#
        B ##. #.# ##. #.# ##.
        C .## #.. #.. #.. .##
        D ##. #.# #.# #.# ##.
        E ### #.. ##. #.. ###
        F ### #.. ##. #.. #..
        G .## #.. #.# #.# .##
        H #.# #.# ### #.# #.#
        I ### .#. .#. .#. ###
        J ..# ..# ..# #.# .#.
        K #.# #.# ##. #.# #.#
        L #.. #.. #.. #.. ###
        M #.# ### ### #.# #.#
        N ##. #.# #.# #.# #.#
        O .#. #.# #.# #.# .#.
        P ##. #.# ##. #.. #..
        Q .#. #.# #.# ##. .##
        R ##. #.# ##. #.# #.#
        S .## #.. .#. ..# ##.
        T ### .#. .#. .#. .#.
        U #.# #.# #.# #.# ###
        V #.# #.# #.# #.# .#.
        W #.# #.# ### ### #.#
        X #.# #.# .#. #.# #.#
        Y #.# #.# .#. .#. .#.
        Z ### ..# .#. #.. ###
        0 ### #.# #.# #.# ###
        1 .#. ##. .#. .#. ###
        2 ##. ..# .#. #.. ###
        3 ##. ..# .#. ..# ##.
        4 #.# #.# ### ..# ..#
        5 ### #.. ##. ..# ##.
        6 .## #.. ### #.# ###
        7 ### ..# .#. .#. .#.
        8 ### #.# ### #.# ###
        9 ### #.# ### ..# ##.
        . ... ... ... ... .#.
        : ... .#. ... .#. ...
        - ... ... ### ... ...
        ( .#. #.. #.. #.. .#.
        ) .#. ..# ..# ..# .#.
        ' .#. .#. ... ... ...
        " #.# #.# ... ... ...
        ! .#. .#. .#. ... .#.
        _ ... ... ... ... ###
        + ... .#. ### .#. ...
        / ..# ..# .#. #.. #..
        \ #.. #.. .#. ..# ..#
        [ ##. #.. #.. #.. ##.
        ] .## ..# ..# ..# .##
        ^ .#. #.# ... ... ...
        & .#. #.# .#. #.# .##
        % #.# ..# .#. #.. #.#
        , ... ... ... .#. #..
        = ... ### ... ### ...
        $ .## ##. .#. .## ##.
        # #.# ### #.# ### #.#
        @ ### #.# ### #.. ###
        ? ##. ..# .#. ... .#.
        * #.# .#. #.# ... ...
        … ... ... ... ... #.#
        Å .#. .#. #.# ### #.#
        Ö #.# .#. #.# #.# .#.
        Ä #.# .#. #.# ### #.#
        """#
        var m: [Character: [String]] = [:]
        for line in src.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 6, let k = parts[0].first else { continue }
            m[k] = parts[1...].map(String.init)
        }
        return m
    }()

    final class Canvas {
        let ctx: CGContext
        init(_ w: Int, _ h: Int) {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(false)
        }
        var image: CGImage { ctx.makeImage()! }

        func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }
        func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) { fill(R(x, y, w, h), c) }

        func bevel(_ r: CGRect, _ f: CGColor, _ hi: CGColor, _ lo: CGColor) {
            fill(r, f)
            fill(R(r.minX, r.minY, r.width, 1), hi)
            fill(R(r.minX, r.minY, 1, r.height), hi)
            fill(R(r.minX, r.maxY - 1, r.width, 1), lo)
            fill(R(r.maxX - 1, r.minY, 1, r.height), lo)
        }
        func button(_ r: CGRect, down: Bool) {
            if down { bevel(r, btnDown, dark, light) } else { bevel(r, btnFace, light, dark) }
        }
        func inset(_ r: CGRect, _ c: CGColor) { bevel(r, c, dark, light) }

        func poly(_ pts: [(CGFloat, CGFloat)], _ c: CGColor) {
            ctx.setFillColor(c)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
            for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ctx.closePath()
            ctx.fillPath()
        }

        func glyph(_ ch: Character, _ x: CGFloat, _ y: CGFloat, _ c: CGColor, _ s: CGFloat = 1) {
            let key = ch.uppercased().first ?? ch
            guard let rows = DefaultSkin.font[key] ?? DefaultSkin.font[ch] else { return }
            for (ry, row) in rows.enumerated() {
                for (rx, b) in row.enumerated() where b == "#" {
                    fill(x + CGFloat(rx) * s, y + CGFloat(ry) * s, s, s, c)
                }
            }
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ c: CGColor) {
            var cx = x
            for ch in s { glyph(ch, cx, y, c); cx += 4 }
        }
        func textWidth(_ s: String) -> CGFloat { CGFloat(max(0, s.count * 4 - 1)) }
        func centered(_ s: String, _ r: CGRect, _ c: CGColor) {
            text(s, (r.midX - textWidth(s) / 2).rounded(.down), (r.midY - 2.5).rounded(.down), c)
        }
    }

    static func make() -> Skin {
        let s = Skin(name: "Predefinita")
        s.images = [
            "main": main(), "titlebar": titlebar(), "cbuttons": cbuttons(), "numbers": numbers(),
            "text": text(), "posbar": posbar(), "volume": volume(balance: false), "balance": volume(balance: true),
            "shufrep": shufrep(), "playpaus": playpaus(), "monoster": monoster(), "eqmain": eqmain(),
            "eq_ex": eqex(), "pledit": pledit(), "gen": gen(), "genex": genex(),
        ]
        s.playlist = PlaylistStyle(normal: C(0x3CE060), current: C(0xFFFFFF), normalBG: C(0x070A08),
                                   selectedBG: C(0x23406E), font: "Arial")
        return s
    }

    // MARK: Icons

    static func icon(_ c: Canvas, _ kind: String, _ cx: CGFloat, _ cy: CGFloat, _ col: CGColor = icon) {
        switch kind {
        case "prev":
            c.fill(cx - 5, cy - 4, 2, 8, col)
            c.poly([(cx + 4, cy - 4), (cx + 4, cy + 4), (cx - 3, cy)], col)
        case "play":
            c.poly([(cx - 3, cy - 5), (cx - 3, cy + 5), (cx + 4, cy)], col)
        case "pause":
            c.fill(cx - 4, cy - 4, 3, 8, col); c.fill(cx + 1, cy - 4, 3, 8, col)
        case "stop":
            c.fill(cx - 4, cy - 4, 8, 8, col)
        case "next":
            c.poly([(cx - 4, cy - 4), (cx - 4, cy + 4), (cx + 3, cy)], col)
            c.fill(cx + 3, cy - 4, 2, 8, col)
        case "eject":
            c.poly([(cx - 5, cy + 1), (cx + 5, cy + 1), (cx, cy - 4)], col)
            c.fill(cx - 5, cy + 3, 10, 2, col)
        default: break
        }
    }

    static func miniIcon(_ c: Canvas, _ kind: String, _ x: CGFloat, _ y: CGFloat, _ col: CGColor = icon) {
        switch kind {
        case "prev": c.fill(x, y, 1, 5, col); c.poly([(x + 5, y), (x + 5, y + 5), (x + 1, y + 2.5)], col)
        case "play": c.poly([(x, y), (x, y + 6), (x + 5, y + 3)], col)
        case "pause": c.fill(x, y, 2, 5, col); c.fill(x + 3, y, 2, 5, col)
        case "stop": c.fill(x, y, 5, 5, col)
        case "next": c.poly([(x, y), (x, y + 5), (x + 4, y + 2.5)], col); c.fill(x + 4, y, 1, 5, col)
        case "eject": c.poly([(x, y + 3), (x + 6, y + 3), (x + 3, y)], col); c.fill(x, y + 4, 6, 1, col)
        default: break
        }
    }

    // MARK: Sheets

    static func main() -> CGImage {
        let c = Canvas(275, 116)
        c.bevel(R(0, 0, 275, 116), face, light, dark)
        c.inset(R(20, 22, 86, 40), lcd)
        c.inset(R(108, 24, 159, 12), lcd)
        c.inset(R(109, 41, 20, 10), lcd); c.text("KBPS", 131, 43, icon)
        c.inset(R(154, 41, 15, 10), lcd); c.text("KHZ", 171, 43, icon)
        c.text("MUSICAMP", 240, 108, light)
        return c.image
    }

    static func titlebar() -> CGImage {
        let c = Canvas(344, 87)
        c.fill(R(0, 0, 344, 87), face)
        func bar(_ y: CGFloat, _ active: Bool, label: String, shade: Bool) {
            c.bevel(R(27, y, 275, 14), active ? titleA : titleI, active ? titleAHi : light, dark)
            let tc = active ? titleText : titleTextI
            if shade {
                c.text(label, 27 + 20, y + 5, tc)
                c.inset(R(27 + 123, y + 2, 34, 10), lcd)
                for (i, k) in ["prev", "play", "pause", "stop", "next", "eject"].enumerated() {
                    miniIcon(c, k, 27 + 143 + CGFloat(i) * 9, y + 4, tc)
                }
            } else {
                let tw = c.textWidth(label)
                let tx = (27 + 137 - tw / 2).rounded(.down)
                for ly in [y + 4, y + 8] {
                    c.fill(R(27 + 20, ly, tx - 4 - 47, 1), tc)
                    c.fill(R(tx + tw + 4, ly, 27 + 214 - (tx + tw + 4), 1), tc)
                }
                c.text(label, tx, y + 5, tc)
            }
        }
        bar(0, true, label: "MUSICAMP", shade: false)
        bar(15, false, label: "MUSICAMP", shade: false)
        bar(29, true, label: "MUSICAMP", shade: true)
        bar(42, false, label: "MUSICAMP", shade: true)
        bar(57, true, label: "IT REALLY WHIPS", shade: false)
        bar(72, false, label: "IT REALLY WHIPS", shade: false)

        func b9(_ x: CGFloat, _ y: CGFloat, _ down: Bool, _ draw: (CGFloat, CGFloat) -> Void) {
            c.button(R(x, y, 9, 9), down: down)
            let o: CGFloat = down ? 1 : 0
            draw(x + o, y + o)
        }
        for d in [false, true] {
            let y: CGFloat = d ? 9 : 0
            b9(0, y, d) { x, y in c.fill(x + 2, y + 2, 5, 1, icon); c.fill(x + 2, y + 4, 5, 1, icon); c.fill(x + 2, y + 6, 5, 1, icon) }
            b9(9, y, d) { x, y in c.fill(x + 2, y + 6, 5, 1, icon) }
            b9(18, y, d) { x, y in for i in 0..<5 { c.fill(x + 2 + CGFloat(i), y + 2 + CGFloat(i), 1, 1, icon); c.fill(x + 6 - CGFloat(i), y + 2 + CGFloat(i), 1, 1, icon) } }
            b9(d ? 9 : 0, 18, d) { x, y in c.fill(x + 2, y + 2, 5, 2, icon) }
            b9(d ? 9 : 0, 27, d) { x, y in c.fill(x + 2, y + 2, 5, 5, icon); c.fill(x + 3, y + 3, 3, 3, btnFace) }
        }
        c.inset(R(0, 36, 17, 7), lcd)
        for x in [17, 20, 23] as [CGFloat] { c.fill(R(x, 36, 3, 7), icon) }

        let letters: [Character] = ["O", "A", "I", "D", "V"]
        let offs: [CGFloat] = [3, 11, 18, 25, 33], hs: [CGFloat] = [8, 7, 7, 8, 7]
        for (base, col) in [(CGFloat(304), icon), (CGFloat(312), light)] {
            c.bevel(R(base, 0, 8, 43), face, light, dark)
            for k in 0..<5 { c.glyph(letters[k], base + 2, offs[k] + (hs[k] - 5) / 2, col) }
        }
        for k in 0..<5 {
            let x = 304 + CGFloat(k) * 8, y = 44 + offs[k]
            c.fill(R(x, y, 8, hs[k]), btnDown)
            c.glyph(letters[k], x + 2, y + ((hs[k] - 5) / 2).rounded(.down), led)
        }
        return c.image
    }

    static func cbuttons() -> CGImage {
        let c = Canvas(136, 36)
        let defs: [(CGFloat, CGFloat, CGFloat, String)] = [(0, 23, 18, "prev"), (23, 23, 18, "play"), (46, 23, 18, "pause"),
                                                           (69, 23, 18, "stop"), (92, 22, 18, "next"), (114, 22, 16, "eject")]
        for (x, w, h, kind) in defs {
            for down in [false, true] {
                let y: CGFloat = down ? h : 0
                c.button(R(x, y, w, h), down: down)
                let o: CGFloat = down ? 1 : 0
                icon(c, kind, (x + w / 2).rounded(.down) + o, (y + h / 2).rounded(.down) + o)
            }
        }
        return c.image
    }

    static func numbers() -> CGImage {
        let c = Canvas(99, 13)
        c.fill(R(0, 0, 99, 13), lcd)
        // 7-segment digits. Segment g of "2" covers (20,6) so the classic minus-sign sprite trick works.
        let segs: [Character: CGRect] = ["a": R(2, 0, 5, 2), "b": R(7, 1, 2, 5), "c": R(7, 7, 2, 5), "d": R(2, 11, 5, 2),
                                         "e": R(0, 7, 2, 5), "f": R(0, 1, 2, 5), "g": R(2, 5, 5, 2)]
        let digits = ["abcdef", "bc", "abged", "abgcd", "fgbc", "afgcd", "afgedc", "abc", "abcdefg", "abcdfg"]
        for (d, s) in digits.enumerated() {
            for ch in s { if let r = segs[ch] { c.fill(r.offsetBy(dx: CGFloat(d * 9), dy: 0), lcdText) } }
        }
        return c.image
    }

    static func text() -> CGImage {
        let c = Canvas(155, 18)
        c.fill(R(0, 0, 155, 18), lcd)
        for (ch, pos) in Skin.fontMap where Skin.charPos(ch) == pos {
            c.glyph(ch, CGFloat(pos.0 * 5 + 1), CGFloat(pos.1 * 6), lcdText)
        }
        return c.image
    }

    static func posbar() -> CGImage {
        let c = Canvas(307, 10)
        c.fill(R(0, 0, 307, 10), face)
        c.inset(R(0, 3, 248, 4), lcd)
        for (x, d) in [(CGFloat(248), false), (CGFloat(278), true)] {
            c.button(R(x, 0, 29, 10), down: d)
            for gx in [x + 11, x + 14, x + 17] { c.fill(R(gx, 3, 1, 4), d ? light : dark) }
        }
        return c.image
    }

    static func volume(balance: Bool) -> CGImage {
        let c = Canvas(68, 433)
        c.fill(R(0, 0, 68, 433), face)
        for i in 0..<28 {
            let y = CGFloat(i * 15), t = CGFloat(i) / 27
            if balance {
                c.inset(R(9, y + 4, 38, 5), lcd)
                c.fill(R(10, y + 5, 36, 3), mix(0x30C840, 0xE04020, t))
            } else {
                c.inset(R(0, y + 4, 68, 5), lcd)
                c.fill(R(1, y + 5, (66 * t).rounded(), 3), heat(t))
            }
        }
        for (x, d) in [(CGFloat(15), false), (CGFloat(0), true)] {
            c.button(R(x, 422, 14, 11), down: d)
            c.fill(R(x + 6, 425, 2, 5), d ? light : dark)
        }
        return c.image
    }

    static func shufrep() -> CGImage {
        let c = Canvas(92, 85)
        c.fill(R(0, 0, 92, 85), face)
        for (x, w, label) in [(CGFloat(0), CGFloat(28), "REP"), (CGFloat(28), CGFloat(47), "SHUFFLE")] {
            for s in 0..<4 {
                let y = CGFloat(15 * s), down = s % 2 == 1, on = s >= 2
                c.button(R(x, y, w, 15), down: down)
                c.centered(label, R(x, y, w, 15).offsetBy(dx: down ? 1 : 0, dy: down ? 1 : 0), on ? led : icon)
            }
        }
        for (i, label) in ["EQ", "PL"].enumerated() {
            for on in [false, true] {
                for down in [false, true] {
                    let r = R((down ? 46 : 0) + 23 * CGFloat(i), on ? 73 : 61, 23, 12)
                    c.button(r, down: down)
                    c.centered(label, r.offsetBy(dx: down ? 1 : 0, dy: 0), on ? led : icon)
                }
            }
        }
        return c.image
    }

    static func playpaus() -> CGImage {
        let c = Canvas(42, 9)
        c.fill(R(0, 0, 42, 9), lcd)
        c.poly([(2, 1), (2, 8), (7, 4.5)], led)
        c.fill(R(11, 1, 2, 7), led); c.fill(R(14, 1, 2, 7), led)
        c.fill(R(20, 2, 5, 5), led)
        c.fill(R(36, 1, 3, 7), lcdDim)
        c.fill(R(39, 1, 3, 7), led)
        return c.image
    }

    static func monoster() -> CGImage {
        let c = Canvas(56, 24)
        c.fill(R(0, 0, 56, 24), lcd)
        c.centered("STEREO", R(0, 0, 29, 12), led); c.centered("STEREO", R(0, 12, 29, 12), lcdDim)
        c.centered("MONO", R(29, 0, 27, 12), led); c.centered("MONO", R(29, 12, 27, 12), lcdDim)
        return c.image
    }

    static func eqmain() -> CGImage {
        let c = Canvas(275, 315)
        c.fill(R(0, 0, 275, 315), face)
        c.bevel(R(0, 0, 275, 116), face, light, dark)
        c.text("PREAMP", 17, 105, icon)
        let labels = ["60", "170", "310", "600", "1K", "3K", "6K", "12K", "14K", "16K"]
        for (i, l) in labels.enumerated() {
            c.text(l, (78 + CGFloat(i) * 18 + 7 - c.textWidth(l) / 2).rounded(.down), 105, icon)
        }
        c.text("+12DB", 46, 40, icon); c.text("+0DB", 48, 67, icon); c.text("-12DB", 46, 94, icon)

        for d in [false, true] {
            c.button(R(0, d ? 125 : 116, 9, 9), down: d)
            for i in 0..<5 { c.fill(2 + CGFloat(i), (d ? 125 : 116) + 2 + CGFloat(i), 1, 1, icon); c.fill(6 - CGFloat(i), (d ? 125 : 116) + 2 + CGFloat(i), 1, 1, icon) }
        }
        // ON/AUTO: off, selected, depressed, selected+depressed
        for (x, on, down) in [(CGFloat(10), false, false), (CGFloat(69), true, false), (CGFloat(128), false, true), (CGFloat(187), true, true)] {
            c.button(R(x, 119, 26, 12), down: down)
            c.fill(R(x + 4, 123, 3, 4), on ? led : lcdDim)
            c.text("ON", x + 10, 122, icon)
        }
        for (x, on, down) in [(CGFloat(36), false, false), (CGFloat(95), true, false), (CGFloat(154), false, true), (CGFloat(213), true, true)] {
            c.button(R(x, 119, 32, 12), down: down)
            c.fill(R(x + 4, 123, 3, 4), on ? led : lcdDim)
            c.text("AUTO", x + 10, 122, icon)
        }
        for (y, active) in [(CGFloat(134), true), (CGFloat(149), false)] {
            c.bevel(R(0, y, 275, 14), active ? titleA : titleI, active ? titleAHi : light, dark)
            let tc = active ? titleText : titleTextI
            c.centered("EQUALIZER", R(0, y, 275, 14), tc)
            for ly in [y + 4, y + 8] { c.fill(R(20, ly, 95, 1), tc); c.fill(R(160, ly, 80, 1), tc) }
            for i in 0..<5 { c.fill(266 + CGFloat(i), y + 3 + CGFloat(i), 1, 1, tc); c.fill(270 - CGFloat(i), y + 3 + CGFloat(i), 1, 1, tc) }
        }
        for i in 0..<28 {
            let x = 13 + CGFloat(i % 14) * 15, y = 164 + CGFloat(i / 14) * 65, t = CGFloat(i) / 27
            c.fill(R(x, y, 14, 63), face)
            c.inset(R(x + 5, y, 4, 63), lcd)
            let h = (61 * t).rounded()
            c.fill(R(x + 6, y + 62 - h, 2, h), heat(t))
        }
        for (y, d) in [(CGFloat(164), false), (CGFloat(176), true)] {
            c.button(R(0, y, 11, 11), down: d)
            c.fill(R(2, y + 5, 7, 1), d ? light : dark)
        }
        for (y, d) in [(CGFloat(164), false), (CGFloat(176), true)] {
            c.button(R(224, y, 44, 12), down: d)
            c.centered("PRESETS", R(224, y, 44, 12).offsetBy(dx: d ? 1 : 0, dy: 0), icon)
        }
        c.fill(R(0, 294, 113, 19), lcd)
        for x in stride(from: 0, to: 113, by: 2) { c.fill(R(CGFloat(x), 303, 1, 1), lcdDim) }
        for y in 0..<19 { c.fill(R(115, 294 + CGFloat(y), 1, 1), heat(abs(CGFloat(y) - 9) / 9)) }
        c.fill(R(0, 314, 113, 1), C(0x707480))
        return c.image
    }

    static func eqex() -> CGImage {
        let c = Canvas(275, 82)
        c.fill(R(0, 0, 275, 82), face)
        for (y, active) in [(CGFloat(0), true), (CGFloat(15), false)] {
            c.bevel(R(0, y, 275, 14), active ? titleA : titleI, active ? titleAHi : light, dark)
            c.text("EQUALIZER", 12, y + 5, active ? titleText : titleTextI)
            c.inset(R(61, y + 4, 97, 7), lcd)
            c.inset(R(164, y + 4, 43, 7), lcd)
        }
        // Shade volume/balance thumbs: left, centre, right variants (3x7)
        for (i, x) in [1, 4, 7, 11, 14, 17].enumerated() {
            c.fill(R(CGFloat(x), 30, 3, 7), i % 3 == 1 ? icon : light)
        }
        for (x, y) in [(CGFloat(1), CGFloat(38)), (1, 47), (11, 38), (11, 47)] { c.button(R(x, y, 9, 9), down: true) }
        return c.image
    }

    /// Generic window frame (gen.bmp): title pieces at y 0/21, sides, bottom corners, title font at y 88/96.
    static func gen() -> CGImage {
        let c = Canvas(194, 109)
        let sep = C(0x00C6FF)
        c.fill(R(0, 0, 194, 109), face)
        for (y, active) in [(CGFloat(0), true), (CGFloat(21), false)] {
            let strip = active ? titleA : titleI, tc = active ? titleText : titleTextI
            for x in [CGFloat(0), 26, 52, 78, 104, 130] {
                c.fill(R(x, y, 25, 20), face)
                c.fill(R(x, y, 25, 1), light)
                c.fill(R(x, y + 2, 25, 11), strip)
            }
            for (x, w) in [(CGFloat(8), CGFloat(17)), (26, 22), (81, 22), (104, 25), (130, 10)] {
                c.fill(R(x, y + 5, w, 1), tc); c.fill(R(x, y + 9, w, 1), tc)
            }
            c.fill(R(0, y, 1, 20), light); c.fill(R(154, y, 1, 20), dark)
            for i in 0..<5 { c.fill(130 + 16 + CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc); c.fill(130 + 20 - CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc) }
        }
        c.bevel(R(0, 42, 125, 14), face, light, dark)
        c.bevel(R(0, 57, 125, 14), face, light, dark)
        for i in 0..<4 { c.fill(R(121 - CGFloat(i) * 3, 67 - CGFloat(i) * 3, 1, 1 + CGFloat(i) * 3), light) }
        for (x, w, h) in [(CGFloat(127), CGFloat(11), CGFloat(29)), (139, 8, 29), (158, 11, 24), (170, 8, 24)] {
            c.fill(R(x, 42, w, h), face)
            c.fill(R(x, 42, 1, h), x == 127 || x == 158 ? light : dark)
        }
        c.button(R(148, 42, 9, 9), down: true)
        c.fill(R(127, 72, 25, 14), face); c.fill(R(127, 85, 25, 1), dark)
        for (y, col, cell) in [(CGFloat(88), titleText, titleA), (CGFloat(96), titleTextI, titleI)] {
            c.fill(R(0, y, 194, 7), sep)
            var x: CGFloat = 1
            for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
                c.fill(R(x, y, 5, 6), cell)
                c.glyph(ch, x + 1, y + 1, col)
                x += 6
            }
        }
        return c.image
    }

    /// genex.bmp: button (normal y 0, pressed y 16) and the 18 system colours at y 0, x 48...82.
    static func genex() -> CGImage {
        let c = Canvas(130, 75)
        c.fill(R(0, 0, 130, 75), face)
        c.button(R(0, 0, 47, 15), down: false)
        c.button(R(0, 16, 47, 15), down: true)
        let colors: [CGColor] = [lcd, lcdText, face, icon, icon, light, C(0x23406E), btnFace, icon,
                                 light, dark, btnDown, face, btnFace, dark, btnDown, dark, face]
        for (i, col) in colors.enumerated() { c.fill(R(48 + CGFloat(i * 2), 0, 1, 1), col) }
        return c.image
    }

    static func pledit() -> CGImage {
        let c = Canvas(280, 186)
        c.fill(R(0, 0, 280, 186), face)
        for (y, active) in [(CGFloat(0), true), (CGFloat(21), false)] {
            let strip = active ? titleA : titleI, tc = active ? titleText : titleTextI
            for (x, w) in [(CGFloat(0), CGFloat(25)), (CGFloat(26), CGFloat(100)), (CGFloat(127), CGFloat(25)), (CGFloat(153), CGFloat(25))] {
                c.fill(R(x, y, w, 20), face)
                c.fill(R(x, y, w, 1), light)
                c.fill(R(x, y + 2, w, 11), strip)
            }
            c.fill(R(0, y, 1, 20), light)
            c.fill(R(177, y, 1, 20), dark)
            c.centered("PLAYLIST", R(26, y + 2, 100, 11), tc)
            for i in 0..<5 { c.fill(153 + 16 + CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc); c.fill(153 + 20 - CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc) }
            c.fill(R(153 + 6, y + 5, 5, 2), tc)
            // inner frame of the list area
            for x in [CGFloat(0), 26, 127, 153] { c.fill(R(x, y + 19, x == 153 ? 25 : (x == 26 ? 100 : 25), 1), dark) }
        }
        c.fill(R(0, 42, 12, 29), face); c.fill(R(0, 42, 1, 29), light); c.fill(R(11, 42, 1, 29), dark)
        c.fill(R(31, 42, 20, 29), face); c.fill(R(31, 42, 1, 29), light); c.fill(R(50, 42, 1, 29), dark)
        c.fill(R(36, 42, 8, 29), lcd); c.fill(R(36, 42, 1, 29), dark); c.fill(R(43, 42, 1, 29), light)
        for (x, d) in [(CGFloat(52), false), (CGFloat(61), true)] { c.button(R(x, 53, 8, 18), down: d) }
        c.button(R(52, 42, 9, 9), down: true)
        for i in 0..<5 { c.fill(54 + CGFloat(i), 44 + CGFloat(i), 1, 1, icon); c.fill(58 - CGFloat(i), 44 + CGFloat(i), 1, 1, icon) }
        c.button(R(62, 42, 9, 9), down: true); c.fill(R(64, 44, 5, 2), icon)

        // Shaded playlist: left (72,42), tile (72,57), right active (99,42) / inactive (99,57), unshade pressed (150,42)
        for (y, active) in [(CGFloat(42), true), (CGFloat(57), false)] {
            let strip = active ? titleA : titleI, tc = active ? titleText : titleTextI
            c.bevel(R(72, y, 25, 14), strip, active ? titleAHi : light, dark)
            c.bevel(R(99, y, 50, 14), strip, active ? titleAHi : light, dark)
            c.inset(R(72, y + 2, 25, 10), lcd); c.fill(R(72, y + 3, 25, 8), lcd)
            c.inset(R(99, y + 2, 21, 10), lcd); c.fill(R(99, y + 3, 21, 8), lcd)
            for gx in [122, 125, 128] as [CGFloat] { c.fill(R(gx, y + 3, 1, 8), tc) }
            c.fill(R(99 + 32, y + 5, 5, 5), tc); c.fill(R(99 + 33, y + 6, 3, 3), strip)
            for i in 0..<5 { c.fill(99 + 42 + CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc); c.fill(99 + 46 - CGFloat(i), y + 5 + CGFloat(i), 1, 1, tc) }
        }
        c.button(R(150, 42, 9, 9), down: true); c.fill(R(152, 44, 5, 5), icon); c.fill(R(153, 45, 3, 3), btnDown)

        // bottom-left with ADD/REM/SEL/MISC
        c.bevel(R(0, 72, 125, 38), face, light, dark)
        for (i, l) in ["ADD", "REM", "SEL", "MISC"].enumerated() {
            let r = R(14 + CGFloat(i) * 29, 80, 22, 18)
            c.button(r, down: false); c.centered(l, r, icon)
        }
        // bottom-right: running time, mini transport, mini time, LIST, resize grip
        c.bevel(R(126, 72, 150, 38), face, light, dark)
        c.inset(R(126 + 5, 72 + 8, 62, 10), lcd)
        c.inset(R(126 + 1, 72 + 20, 58, 12), lcd)
        for (i, k) in ["prev", "play", "pause", "stop", "next", "eject"].enumerated() {
            miniIcon(c, k, 126 + 4 + CGFloat(i) * 9, 72 + 23, icon)
        }
        c.inset(R(126 + 63, 72 + 21, 30, 10), lcd)
        let lr = R(126 + 104, 72 + 8, 22, 18)
        c.button(lr, down: false); c.text("LIST", lr.minX + 3, lr.minY + 3, icon); c.text("OPTS", lr.minX + 3, lr.minY + 10, icon)
        for i in 0..<4 { c.fill(R(126 + 146 - CGFloat(i) * 3, 72 + 34 - CGFloat(i) * 3, 1, 1 + CGFloat(i) * 3), light) }
        // bottom tile
        c.fill(R(179, 0, 25, 38), face); c.fill(R(179, 0, 25, 1), light); c.fill(R(179, 37, 25, 1), dark)
        c.fill(R(205, 0, 75, 38), lcd)

        // Popup menus: label pairs (normal at x, selected at x+23), bar at x+48.
        let menus: [(CGFloat, [String])] = [
            (0, ["URL", "DIR", "FILE"]), (54, ["ALL", "CROP", "SEL", "MISC"]),
            (104, ["INV", "ZERO", "ALL"]), (154, ["SORT", "INF", "OPTS"]), (204, ["NEW", "SAVE", "LOAD"]),
        ]
        for (x, items) in menus {
            for (k, l) in items.enumerated() {
                let y = 111 + CGFloat(k) * 19
                for sel in [false, true] {
                    let r = R(x + (sel ? 23 : 0), y, 22, 18)
                    c.button(r, down: sel)
                    c.centered(l, r, sel ? led : icon)
                }
            }
            c.fill(R(x + 48, 111, 3, CGFloat(items.count) * 18), light)
        }
        return c.image
    }
}
