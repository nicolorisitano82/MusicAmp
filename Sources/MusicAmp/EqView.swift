import AppKit

final class EqView: SkinView {
    override var logicalSize: CGSize { CGSize(width: 275, height: ctl.eqShade ? 14 : 116) }
    override var regionKey: String? { ctl.eqShade ? "equalizerws" : "equalizer" }

    private var pressed: String?
    private var pressInside = false
    private var dragSlider: Int?   // -1 = preamp, 0...9 = bands
    private var shadeDrag: String?  // "vol" / "bal" in shade mode

    private static let shadeVol = R(61, 4, 97, 7)
    private static let shadeBal = R(164, 4, 43, 7)

    private let labels = ["60HZ", "170HZ", "310HZ", "600HZ", "1KHZ", "3KHZ", "6KHZ", "12KHZ", "14KHZ", "16KHZ"]

    private func buttons() -> [(String, CGRect)] {
        if ctl.eqShade { return [("shade", R(254, 3, 9, 9)), ("close", R(264, 3, 9, 9))] }
        return [("on", R(14, 18, 26, 12)), ("auto", R(40, 18, 32, 12)), ("presets", R(217, 18, 44, 12)),
                ("shade", R(254, 3, 9, 9)), ("close", R(264, 3, 9, 9))]
    }
    private func sliderRect(_ i: Int) -> CGRect { i < 0 ? R(21, 38, 14, 63) : R(78 + CGFloat(i) * 18, 38, 14, 63) }
    private func down(_ id: String) -> Bool { pressed == id && pressInside }

    override var renderSignature: Int {
        var h = Hasher()
        h.combine(isActive); h.combine(ObjectIdentifier(skin)); h.combine(ctl.eqShade)
        h.combine(ctl.bands); h.combine(ctl.preamp); h.combine(ctl.eqOn); h.combine(ctl.eqAuto)
        h.combine(pressed); h.combine(pressInside); h.combine(dragSlider)
        if ctl.eqShade { h.combine(ctl.volume); h.combine(ctl.balance) }
        return h.finalize()
    }

    override func render(_ r: Renderer) {
        if ctl.eqShade {
            r.blit("eq_ex", isActive ? R(0, 0, 275, 14) : R(0, 15, 275, 14), 0, 0)
            if down("close") { r.blit("eq_ex", R(11, 47, 9, 9), 264, 3) }
            if down("shade") { r.blit("eq_ex", R(1, 47, 9, 9), 254, 3) }
            // Volume and balance thumbs (eq_ex.bmp y 30: left/center/right variants by position)
            let v = ctl.volume / 100
            let vx = Self.shadeVol.minX + (v * (Self.shadeVol.width - 3)).rounded()
            r.blit("eq_ex", R(v < 1.0 / 3 ? 1 : (v < 2.0 / 3 ? 4 : 7), 30, 3, 7), vx, 4)
            let b = (ctl.balance + 100) / 200
            let bx = Self.shadeBal.minX + (b * (Self.shadeBal.width - 3)).rounded()
            r.blit("eq_ex", R(b < 1.0 / 3 ? 11 : (b < 2.0 / 3 ? 14 : 17), 30, 3, 7), bx, 4)
            return
        }
        r.blit("eqmain", R(0, 0, 275, 116), 0, 0)
        r.blit("eqmain", isActive ? R(0, 134, 275, 14) : R(0, 149, 275, 14), 0, 0)
        if down("close") { r.blit("eqmain", R(0, 125, 9, 9), 264, 3) }
        if down("shade") { r.blit("eq_ex", R(1, 38, 9, 9), 254, 3) }

        let onX: CGFloat = ctl.eqOn ? (down("on") ? 187 : 69) : (down("on") ? 128 : 10)
        r.blit("eqmain", R(onX, 119, 26, 12), 14, 18)
        let autoX: CGFloat = ctl.eqAuto ? (down("auto") ? 213 : 95) : (down("auto") ? 154 : 36)
        r.blit("eqmain", R(autoX, 119, 32, 12), 40, 18)
        r.blit("eqmain", down("presets") ? R(224, 176, 44, 12) : R(224, 164, 44, 12), 217, 18)

        drawGraph(r)
        drawSlider(r, -1, ctl.preamp)
        for i in 0..<10 { drawSlider(r, i, ctl.bands[i]) }
    }

    private func drawSlider(_ r: Renderer, _ i: Int, _ db: Double) {
        let rect = sliderRect(i)
        let norm = (max(-12, min(12, db)) + 12) / 24
        let idx = Int((norm * 27).rounded())
        r.blit("eqmain", R(13 + CGFloat(idx % 14) * 15, 164 + CGFloat(idx / 14) * 65, 14, 63), rect.minX, rect.minY)
        let thumb = dragSlider == i ? R(0, 176, 11, 11) : R(0, 164, 11, 11)
        r.blit("eqmain", thumb, rect.minX + 1, rect.minY + ((1 - norm) * 51).rounded())
    }

    private func drawGraph(_ r: Renderer) {
        r.blit("eqmain", R(0, 294, 113, 19), 86, 17)
        let py = 17 + ((12 - ctl.preamp) / 24 * 18).rounded()
        r.blit("eqmain", R(0, 314, 113, 1), 86, max(17, min(35, py)))
        let colors = skin.eqLineColors
        let v = ctl.bands
        // Catmull-Rom through the 10 band values spread over 113 px.
        func value(_ x: Double) -> Double {
            let t = x / 112 * 9
            let i = min(8, Int(t))
            let f = t - Double(i)
            let p0 = v[max(0, i - 1)], p1 = v[i], p2 = v[i + 1], p3 = v[min(9, i + 2)]
            return 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
        }
        var prev: Int?
        for x in 0..<113 {
            let y = max(0, min(18, Int(((12 - value(Double(x))) / 24 * 18).rounded())))
            let (lo, hi) = prev.map { (min($0, y), max($0, y)) } ?? (y, y)
            for yy in lo...hi { r.fill(colors[yy], R(86 + CGFloat(x), 17 + CGFloat(yy), 1, 1)) }
            prev = y
        }
    }

    // MARK: Mouse

    override func hitDown(_ p: CGPoint, _ e: NSEvent) -> Bool {
        for (id, r) in buttons() where r.contains(p) { pressed = id; pressInside = true; return true }
        if ctl.eqShade {
            for (k, r) in [("vol", Self.shadeVol), ("bal", Self.shadeBal)] where r.insetBy(dx: -2, dy: -2).contains(p) {
                shadeDrag = k
                updateShadeDrag(p)
                return true
            }
        } else {
            for i in -1..<10 where sliderRect(i).contains(p) {
                dragSlider = i
                updateSlider(p)
                return true
            }
        }
        if p.y < 14, e.clickCount == 2 { ctl.toggleEQShade(); return true }
        return false
    }

    override func hitDrag(_ p: CGPoint, _ e: NSEvent) {
        if dragSlider != nil { updateSlider(p); return }
        if shadeDrag != nil { updateShadeDrag(p); return }
        if let id = pressed { pressInside = buttons().first { $0.0 == id }?.1.contains(p) ?? false }
    }

    override func hitUp(_ p: CGPoint, _ e: NSEvent) {
        if shadeDrag != nil {
            shadeDrag = nil
            ctl.marqueeOverride = nil
            return
        }
        if dragSlider != nil {
            dragSlider = nil
            ctl.marqueeOverride = nil
            return
        }
        defer { pressed = nil }
        guard let id = pressed, pressInside else { return }
        switch id {
        case "on": ctl.eqOn.toggle()
        case "auto": ctl.eqAuto.toggle()
        case "presets": popUp(ctl.presetsMenu(), at: CGPoint(x: 217, y: 30))
        case "shade": ctl.toggleEQShade()
        case "close": ctl.toggleEQ()
        default: break
        }
    }

    private func updateShadeDrag(_ p: CGPoint) {
        if shadeDrag == "vol" {
            ctl.volume = max(0, min(100, (p.x - Self.shadeVol.minX - 1.5) / (Self.shadeVol.width - 3) * 100))
            ctl.marqueeOverride = "VOLUME: \(Int(ctl.volume.rounded()))%"
        } else {
            var b = max(-100, min(100, (p.x - Self.shadeBal.minX - 1.5) / (Self.shadeBal.width - 3) * 200 - 100))
            if abs(b) < 15 { b = 0 }
            ctl.balance = b
            let pct = Int(abs(b).rounded())
            ctl.marqueeOverride = b == 0 ? "BALANCE: CENTER" : "BALANCE: \(pct)% \(b < 0 ? "LEFT" : "RIGHT")"
        }
    }

    private func updateSlider(_ p: CGPoint) {
        guard let i = dragSlider else { return }
        let norm = 1 - (Double(p.y) - 38 - 5.5) / 51
        var db = max(-12, min(12, norm * 24 - 12))
        if abs(db) < 0.6 { db = 0 }
        let label: String
        if i < 0 {
            ctl.preamp = db
            label = "PREAMP"
        } else {
            ctl.bands[i] = db
            label = labels[i]
        }
        ctl.marqueeOverride = "EQ: \(label) \(String(format: "%+.1f", db)) DB"
    }

    // MARK: VoiceOver

    override var accessibilityName: String { "Equalizzatore" }

    override func accessibilityItems() -> [AXItem] {
        func db(_ v: Double) -> String { String(format: "%+.1f dB", v) }
        var items: [AXItem] = []
        if ctl.eqShade {
            items += [
                AXItem(id: "vol", kind: .slider, label: "Volume", rect: Self.shadeVol, value: "\(Int(ctl.volume.rounded()))%",
                       increment: { [weak self] in self.map { $0.ctl.volume = min(100, $0.ctl.volume + 5) } },
                       decrement: { [weak self] in self.map { $0.ctl.volume = max(0, $0.ctl.volume - 5) } }),
                AXItem(id: "bal", kind: .slider, label: "Bilanciamento", rect: Self.shadeBal, value: AXText.balance(ctl.balance),
                       increment: { [weak self] in self.map { $0.ctl.balance = min(100, $0.ctl.balance + 10) } },
                       decrement: { [weak self] in self.map { $0.ctl.balance = max(-100, $0.ctl.balance - 10) } }),
            ]
        } else {
            items += [
                AXItem(id: "on", kind: .toggle, label: "Equalizzatore attivo", rect: R(14, 18, 26, 12), on: ctl.eqOn,
                       press: { [weak self] in self?.ctl.eqOn.toggle() }),
                AXItem(id: "auto", kind: .toggle, label: "Preset automatico per brano", rect: R(40, 18, 32, 12), on: ctl.eqAuto,
                       press: { [weak self] in self?.ctl.eqAuto.toggle() }),
                AXItem(id: "presets", kind: .button, label: "Preset", rect: R(217, 18, 44, 12),
                       press: { [weak self] in self.map { $0.popUp($0.ctl.presetsMenu(), at: CGPoint(x: 217, y: 30)) } }),
                AXItem(id: "preamp", kind: .slider, label: "Preamplificazione", rect: sliderRect(-1), value: db(ctl.preamp),
                       increment: { [weak self] in self.map { $0.ctl.preamp = min(12, $0.ctl.preamp + 1) } },
                       decrement: { [weak self] in self.map { $0.ctl.preamp = max(-12, $0.ctl.preamp - 1) } }),
            ]
            for i in 0..<10 {
                let name = labels[i].replacingOccurrences(of: "KHZ", with: " kHz").replacingOccurrences(of: "HZ", with: " Hz")
                items.append(AXItem(id: "band\(i)", kind: .slider, label: "Banda \(name)", rect: sliderRect(i), value: db(ctl.bands[i]),
                                    increment: { [weak self] in self.map { $0.ctl.bands[i] = min(12, $0.ctl.bands[i] + 1) } },
                                    decrement: { [weak self] in self.map { $0.ctl.bands[i] = max(-12, $0.ctl.bands[i] - 1) } }))
            }
        }
        items += [
            AXItem(id: "shade", kind: .toggle, label: "Modalità ridotta", rect: R(254, 3, 9, 9), on: ctl.eqShade,
                   press: { [weak self] in self?.ctl.toggleEQShade() }),
            AXItem(id: "close", kind: .button, label: "Chiudi equalizzatore", rect: R(264, 3, 9, 9),
                   press: { [weak self] in self?.ctl.toggleEQ() }),
        ]
        return items
    }

    override func cursorAreas() -> [(String, CGRect)] {
        if ctl.eqShade {
            return [("eqnormal", R(0, 0, 275, 14)), ("volbal", Self.shadeVol), ("volbal", Self.shadeBal), ("eqclose", R(264, 3, 9, 9))]
        }
        var a: [(String, CGRect)] = [("eqnormal", R(0, 0, 275, 116)), ("eqtitle", R(0, 0, 275, 14)), ("eqclose", R(264, 3, 9, 9))]
        for i in -1..<10 { a.append(("eqslid", sliderRect(i))) }
        return a
    }
}
