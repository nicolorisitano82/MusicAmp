import AppKit

final class MainView: SkinView {
    override var logicalSize: CGSize { CGSize(width: 275, height: shade ? 14 : 116) }
    override var regionKey: String? { shade ? "windowshade" : "normal" }
    /// Previews always render the full window.
    private var shade: Bool { ctl.mainShade && previewSkin == nil }

    private var pressed: String?
    private var pressInside = false
    private var dragKind: String?
    private var seekPreview: Double?
    private var marqueeGrab: (x: CGFloat, offset: CGFloat) = (0, 0)

    private let buttons: [(String, CGRect)] = [
        ("prev", R(16, 88, 23, 18)), ("play", R(39, 88, 23, 18)), ("pause", R(62, 88, 23, 18)),
        ("stop", R(85, 88, 23, 18)), ("next", R(108, 88, 22, 18)), ("eject", R(136, 89, 22, 16)),
        ("shuffle", R(164, 89, 47, 15)), ("repeat", R(210, 89, 28, 15)),
        ("eq", R(219, 58, 23, 12)), ("pl", R(242, 58, 23, 12)),
        ("options", R(6, 3, 9, 9)), ("minimize", R(244, 3, 9, 9)), ("shade", R(254, 3, 9, 9)), ("close", R(264, 3, 9, 9)),
        ("clutterO", R(10, 25, 8, 8)), ("clutterA", R(10, 33, 8, 7)), ("clutterI", R(10, 40, 8, 7)),
        ("clutterD", R(10, 47, 8, 8)), ("clutterV", R(10, 55, 8, 7)),
        ("time", R(36, 26, 63, 13)), ("vis", R(24, 43, 76, 16)),
    ]
    private let shadeButtons: [(String, CGRect)] = [
        ("options", R(6, 3, 9, 9)), ("minimize", R(244, 3, 9, 9)), ("shade", R(254, 3, 9, 9)), ("close", R(264, 3, 9, 9)),
        ("prev", R(169, 2, 8, 11)), ("play", R(177, 2, 10, 11)), ("pause", R(187, 2, 10, 11)),
        ("stop", R(197, 2, 9, 11)), ("next", R(206, 2, 8, 11)), ("eject", R(215, 2, 9, 11)),
        ("time", R(127, 3, 30, 8)),
    ]

    private func down(_ id: String) -> Bool { pressed == id && pressInside }

    override var renderSignature: Int {
        let a = ctl.transport
        var h = Hasher()
        h.combine(isActive); h.combine(ObjectIdentifier(skin)); h.combine(shade)
        h.combine("\(a.state)"); h.combine(Int(a.currentTime)); h.combine(a.state == .paused && ctl.blinkOn)
        h.combine(a.hasSource); h.combine(a.stream.buffering); h.combine(a.bitrate); h.combine(a.channels); h.combine(a.sampleRate)
        h.combine(ctl.marqueeOffset); h.combine(ctl.marqueeOverride); h.combine(ctl.marqueeText)
        h.combine(ctl.volume); h.combine(ctl.balance); h.combine(ctl.shuffle); h.combine(ctl.repeatOn)
        h.combine(ctl.eqVisible); h.combine(ctl.plVisible); h.combine(ctl.alwaysOnTop); h.combine(ctl.doubleSize)
        h.combine(ctl.timeRemaining); h.combine(ctl.visMode); h.combine(ctl.easterEgg)
        h.combine(pressed); h.combine(pressInside); h.combine(dragKind); h.combine(seekPreview)
        if let w = waveform, a.duration > 0 {
            // The played part moves one device pixel at a time.
            h.combine(w.peaks.count); h.combine(Int((seekPreview ?? a.currentTime / a.duration) * 219 * Double(pixelScale)))
        }
        return h.finalize()
    }

    /// The current track's waveform when the option is on and it's ready (local files only).
    private var waveform: Waveform? {
        guard ctl.waveSeekBar, let t = ctl.playlist.currentTrack, !t.isStream else { return nil }
        return WaveformStore.shared.waveform(for: t.url)
    }
    private var loaded: Bool { ctl.transport.hasSource && ctl.transport.state != .stopped }

    // MARK: Render

    override func render(_ r: Renderer) {
        if shade { renderShade(r); return }
        let a = ctl.transport
        r.blit("main", R(0, 0, 275, 116), 0, 0)
        // Easter egg (⌃⇧ + "nullsoft"): the "It really whips the llama's ass" title bar rows of TITLEBAR.BMP.
        let titleY: CGFloat = ctl.easterEgg ? (isActive ? 57 : 72) : (isActive ? 0 : 15)
        r.blit("titlebar", R(27, titleY, 275, 14), 0, 0)
        titleButtons(r, shade: false)

        // Clutter bar
        r.blit("titlebar", R(304, 0, 8, 43), 10, 22)
        if down("clutterO") { r.blit("titlebar", R(304, 47, 8, 8), 10, 25) }
        if ctl.alwaysOnTop || down("clutterA") { r.blit("titlebar", R(312, 55, 8, 7), 10, 33) }
        if down("clutterI") { r.blit("titlebar", R(320, 62, 8, 7), 10, 40) }
        if ctl.doubleSize || down("clutterD") { r.blit("titlebar", R(328, 69, 8, 8), 10, 47) }
        if down("clutterV") { r.blit("titlebar", R(336, 77, 8, 7), 10, 55) }

        // Play status
        switch a.state {
        case .playing:
            r.blit("playpaus", R(0, 0, 9, 9), 26, 28)
            r.blit("playpaus", R(39, 0, 3, 9), 24, 28)
        case .paused:
            r.blit("playpaus", R(9, 0, 9, 9), 26, 28)
        case .stopped:
            r.blit("playpaus", R(18, 0, 9, 9), 26, 28)
        }

        // Time (blinks while paused)
        if a.hasSource, a.state != .stopped, !(a.state == .paused && !ctl.blinkOn) {
            drawTime(r)
        }

        drawVis(r)

        // Marquee
        r.clip(R(111, 27, 154, 6)) {
            if let o = ctl.marqueeOverride {
                r.text(o.uppercased(), 111, 27)
            } else {
                let t = ctl.marqueeText
                if t.count * 5 <= 154 || !ctl.marqueeScroll {
                    r.text(t, 111, 27)
                } else {
                    let full = t + "  ***  "
                    let w = CGFloat(full.count * 5)
                    var off = ctl.marqueeOffset.truncatingRemainder(dividingBy: w)
                    if off < 0 { off += w }   // dragged right past the start
                    r.text(full + full, 111 - off, 27)
                }
            }
        }

        if a.hasSource, a.bitrate > 0 || a.sampleRate > 0 {
            let kbps = String(min(999, a.bitrate))
            r.text(String(repeating: " ", count: max(0, 3 - kbps.count)) + kbps, 111, 43)
            let khz = String(Int((a.sampleRate / 1000).rounded()))
            r.text(String(repeating: " ", count: max(0, 2 - khz.count)) + String(khz.suffix(2)), 156, 43)
        }
        let ch = a.hasSource ? a.channels : 0
        r.blit("monoster", ch >= 2 ? R(0, 0, 29, 12) : R(0, 12, 29, 12), 239, 41)
        r.blit("monoster", ch == 1 ? R(29, 0, 27, 12) : R(29, 12, 27, 12), 212, 41)

        // Volume
        let vi = CGFloat(Int((ctl.volume / 100 * 27).rounded()))
        r.blit("volume", R(0, vi * 15, 68, 13), 107, 57)
        if (skin.image("volume")?.height ?? 0) >= 433 {
            r.blit("volume", dragKind == "vol" ? R(0, 422, 14, 11) : R(15, 422, 14, 11), 107 + (ctl.volume / 100 * 54).rounded(), 58)
        }
        // Balance
        let bi = CGFloat(Int((abs(ctl.balance) / 100 * 27).rounded()))
        r.blit("balance", R(9, bi * 15, 38, 13), 177, 57)
        if (skin.image("balance")?.height ?? 0) >= 433 {
            r.blit("balance", dragKind == "bal" ? R(0, 422, 14, 11) : R(15, 422, 14, 11), 177 + ((ctl.balance + 100) / 200 * 24).rounded(), 58)
        }

        // Position bar
        r.blit("posbar", R(0, 0, 248, 10), 16, 72)
        if loaded, a.duration > 0 {
            let pos = seekPreview ?? (a.currentTime / a.duration)
            // Optional waveform (Settings → Visualization), drawn in the groove between the thumb's end stops,
            // in the skin's own colours; the skin's background and thumb stay as they are.
            if let w = waveform {
                let c = skin.waveformColors
                r.drawWaveform(w, in: skin.waveformRect, playX: 30.5 + CGFloat(pos) * 219, played: c.played, ahead: c.ahead)
            }
            r.blit("posbar", dragKind == "pos" ? R(278, 0, 29, 10) : R(248, 0, 29, 10), 16 + (pos * 219).rounded(), 72)
        }

        // Transport
        let cb: [(String, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            ("prev", 0, 23, 18, 16, 88), ("play", 23, 23, 18, 39, 88), ("pause", 46, 23, 18, 62, 88),
            ("stop", 69, 23, 18, 85, 88), ("next", 92, 22, 18, 108, 88), ("eject", 114, 22, 16, 136, 89),
        ]
        for (id, sx, w, h, x, y) in cb {
            r.blit("cbuttons", R(sx, down(id) ? h : 0, w, h), x, y)
        }

        // Shuffle / repeat / EQ / PL
        r.blit("shufrep", R(28, (ctl.shuffle ? 30 : 0) + (down("shuffle") ? 15 : 0), 47, 15), 164, 89)
        r.blit("shufrep", R(0, (ctl.repeatOn ? 30 : 0) + (down("repeat") ? 15 : 0), 28, 15), 210, 89)
        r.blit("shufrep", R(down("eq") ? 46 : 0, ctl.eqVisible ? 73 : 61, 23, 12), 219, 58)
        r.blit("shufrep", R(down("pl") ? 69 : 23, ctl.plVisible ? 73 : 61, 23, 12), 242, 58)
    }

    private func titleButtons(_ r: Renderer, shade: Bool) {
        r.blit("titlebar", down("options") ? R(0, 9, 9, 9) : R(0, 0, 9, 9), 6, 3)
        r.blit("titlebar", down("minimize") ? R(9, 9, 9, 9) : R(9, 0, 9, 9), 244, 3)
        if shade {
            r.blit("titlebar", down("shade") ? R(9, 27, 9, 9) : R(0, 27, 9, 9), 254, 3)
        } else {
            r.blit("titlebar", down("shade") ? R(9, 18, 9, 9) : R(0, 18, 9, 9), 254, 3)
        }
        r.blit("titlebar", down("close") ? R(18, 9, 9, 9) : R(18, 0, 9, 9), 264, 3)
    }

    private func drawTime(_ r: Renderer) {
        let a = ctl.transport
        let cur = seekPreview.map { $0 * a.duration } ?? a.currentTime
        let t = ctl.timeRemaining ? max(0, a.duration - cur) : cur
        let m = (Int(t) / 60) % 100, s = Int(t) % 60
        let digits = [m / 10, m % 10, s / 10, s % 10]
        let xs: [CGFloat] = [48, 60, 78, 90]
        let sheet = skin.hasNumsEx ? "nums_ex" : "numbers"
        for (d, x) in zip(digits, xs) { r.blit(sheet, R(CGFloat(d * 9), 0, 9, 13), x, 26) }
        if skin.hasNumsEx {
            r.blit(sheet, ctl.timeRemaining ? R(99, 0, 9, 13) : R(90, 0, 9, 13), 36, 26)
        } else {
            r.blit(sheet, ctl.timeRemaining ? R(20, 6, 5, 1) : R(9, 6, 5, 1), 38, 32)
        }
    }

    private func drawVis(_ r: Renderer) {
        r.visualizer(ctl, R(24, 43, 76, 16))
    }

    private func renderShade(_ r: Renderer) {
        let a = ctl.transport
        r.blit("titlebar", isActive ? R(27, 29, 275, 14) : R(27, 42, 275, 14), 0, 0)
        titleButtons(r, shade: true)
        if a.state == .playing || ctl.snapshotMode { r.visualizer(ctl, R(79, 5, 38, 5), dots: false) }
        if loaded {
            let cur = a.currentTime
            let t = ctl.timeRemaining ? max(0, a.duration - cur) : cur
            let s = (ctl.timeRemaining ? "-" : " ") + String(format: "%02d:%02d", (Int(t) / 60) % 100, Int(t) % 60)
            r.text(s, 127, 4)
            r.blit("titlebar", R(0, 36, 17, 7), 226, 4)
            if a.duration > 0 {
                let pos = seekPreview ?? (cur / a.duration)
                let src = pos < 1.0 / 3 ? R(17, 36, 3, 7) : (pos > 2.0 / 3 ? R(23, 36, 3, 7) : R(20, 36, 3, 7))
                r.blit("titlebar", src, 226 + (pos * 14).rounded(), 4)
            }
        }
    }

    // MARK: Mouse

    override func hitDown(_ p: CGPoint, _ e: NSEvent) -> Bool {
        if ctl.mainShade {
            if R(226, 4, 17, 7).contains(p), loaded { dragKind = "shadepos"; updateDrag(p); return true }
            for (id, r) in shadeButtons where r.contains(p) { pressed = id; pressInside = true; return true }
            if e.clickCount == 2 { ctl.toggleMainShade(); return true }
            return false
        }
        if R(16, 72, 248, 10).contains(p), loaded { dragKind = "pos"; updateDrag(p); return true }
        // Winamp lets you drag the song title to scroll it by hand.
        if R(111, 24, 155, 12).contains(p), ctl.marqueeOverride == nil, ctl.marqueeText.count * 5 > 154 {
            dragKind = "marquee"
            marqueeGrab = (p.x, ctl.marqueeOffset)
            ctl.marqueeDragging = true
            return true
        }
        if R(107, 57, 68, 13).contains(p) { dragKind = "vol"; updateDrag(p); return true }
        if R(177, 57, 38, 13).contains(p) { dragKind = "bal"; updateDrag(p); return true }
        for (id, r) in buttons where r.contains(p) { pressed = id; pressInside = true; return true }
        if p.y < 14, e.clickCount == 2 { ctl.toggleMainShade(); return true }
        return false
    }

    override func hitDrag(_ p: CGPoint, _ e: NSEvent) {
        if dragKind != nil { updateDrag(p); return }
        if let id = pressed {
            let list = ctl.mainShade ? shadeButtons : buttons
            pressInside = list.first { $0.0 == id }?.1.contains(p) ?? false
        }
    }

    override func hitUp(_ p: CGPoint, _ e: NSEvent) {
        if let k = dragKind {
            if (k == "pos" || k == "shadepos"), let sp = seekPreview { ctl.transport.seek(to: sp * ctl.transport.duration) }
            dragKind = nil
            seekPreview = nil
            ctl.marqueeDragging = false
            ctl.marqueeOverride = nil
            return
        }
        if let id = pressed, pressInside { perform(id, e) }
        pressed = nil
    }

    private func updateDrag(_ p: CGPoint) {
        switch dragKind {
        case "marquee":
            ctl.marqueeOffset = marqueeGrab.offset - (p.x - marqueeGrab.x)
        case "vol":
            ctl.volume = max(0, min(100, (p.x - 107 - 7) / 54 * 100))
            ctl.marqueeOverride = "VOLUME: \(Int(ctl.volume.rounded()))%"
        case "bal":
            var b = max(-100, min(100, (p.x - 177 - 7) / 24 * 200 - 100))
            if abs(b) < 15 { b = 0 }
            ctl.balance = b
            let pct = Int(abs(b).rounded())
            ctl.marqueeOverride = b == 0 ? "BALANCE: CENTER" : "BALANCE: \(pct)% \(b < 0 ? "LEFT" : "RIGHT")"
        case "pos", "shadepos":
            let f = dragKind == "pos" ? (p.x - 16 - 14) / 219 : (p.x - 226 - 1) / 14
            let v = max(0, min(1, Double(f)))
            seekPreview = v
            let d = ctl.transport.duration
            ctl.marqueeOverride = "SEEK TO: \(Ctl.mmss(v * d))/\(Ctl.mmss(d)) (\(Int(v * 100))%)"
        default: break
        }
    }

    private func perform(_ id: String, _ e: NSEvent?) {
        switch id {
        case "prev": ctl.previous()
        case "play": ctl.play()
        case "pause": ctl.pause()
        case "stop": ctl.stop()
        case "next": ctl.next()
        case "eject": ctl.openFiles()
        case "shuffle": ctl.shuffle.toggle()
        case "repeat": ctl.repeatOn.toggle()
        case "eq": ctl.toggleEQ()
        case "pl": ctl.togglePL()
        case "options", "clutterO": popUp(ctl.optionsMenu(), at: CGPoint(x: id == "options" ? 6 : 18, y: id == "options" ? 12 : 25))
        case "minimize": NSApp.hide(nil)
        case "shade": ctl.toggleMainShade()
        case "close": if ctl.closeToDock { DockMode.shared.enter() } else { NSApp.terminate(nil) }
        case "clutterA": ctl.toggleAlwaysOnTop()
        case "clutterI": ctl.fileInfo()
        case "clutterD": ctl.toggleDoubleSize()
        case "clutterV": popUp(ctl.visMenu(), at: CGPoint(x: 18, y: 55))
        case "time": ctl.timeRemaining.toggle()
        case "vis": ctl.visMode = (ctl.visMode + 1) % 3
        default: break
        }
    }

    // MARK: VoiceOver

    override var accessibilityName: String { "MusicAmp, main window" }

    override func accessibilityItems() -> [AXItem] {
        let a = ctl.transport
        func button(_ id: String, _ label: String, _ r: CGRect) -> AXItem {
            AXItem(id: id, kind: .button, label: label, rect: r, press: { [weak self] in self?.perform(id, nil) })
        }
        func toggle(_ id: String, _ label: String, _ r: CGRect, _ on: Bool) -> AXItem {
            AXItem(id: id, kind: .toggle, label: label, rect: r, on: on, press: { [weak self] in self?.perform(id, nil) })
        }
        let rect = Dictionary((shade ? shadeButtons : buttons).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        var items: [AXItem] = [
            AXItem(id: "title", kind: .text, label: "Track", rect: shade ? R(127, 3, 30, 8) : R(111, 24, 155, 12),
                   value: ctl.marqueeText),
        ]
        if a.hasSource, a.state != .stopped {
            items.append(AXItem(id: "timeText", kind: .text, label: "Time", rect: rect["time"] ?? .zero,
                                value: "\(AXText.time(a.currentTime)) of \(AXText.time(a.duration))"))
        }
        items += [
            button("prev", "Previous Track", rect["prev"]!),
            button("play", a.state == .playing ? "Restart Track" : "Play", rect["play"]!),
            button("pause", a.state == .paused ? "Resume" : "Pause", rect["pause"]!),
            button("stop", "Stop", rect["stop"]!),
            button("next", "Next Track", rect["next"]!),
            button("eject", "Open Files", rect["eject"]!),
        ]
        if !shade {
            let seekStep = { [weak self] (d: Double) in self?.ctl.seek(by: d) }
            items += [
                AXItem(id: "pos", kind: .slider, label: "Position", rect: R(16, 72, 248, 10),
                       value: a.duration > 0 ? "\(Int(a.currentTime / a.duration * 100))%" : "no track",
                       increment: { seekStep(5) }, decrement: { seekStep(-5) }),
                AXItem(id: "vol", kind: .slider, label: "Volume", rect: R(107, 57, 68, 13), value: "\(Int(ctl.volume.rounded()))%",
                       increment: { [weak self] in self.map { $0.ctl.volume = min(100, $0.ctl.volume + 5) } },
                       decrement: { [weak self] in self.map { $0.ctl.volume = max(0, $0.ctl.volume - 5) } }),
                AXItem(id: "bal", kind: .slider, label: "Balance", rect: R(177, 57, 38, 13), value: AXText.balance(ctl.balance),
                       increment: { [weak self] in self.map { $0.ctl.balance = min(100, $0.ctl.balance + 10) } },
                       decrement: { [weak self] in self.map { $0.ctl.balance = max(-100, $0.ctl.balance - 10) } }),
                toggle("shuffle", "Shuffle", rect["shuffle"]!, ctl.shuffle),
                toggle("repeat", "Repeat", rect["repeat"]!, ctl.repeatOn),
                toggle("eq", "Show Equalizer", rect["eq"]!, ctl.eqVisible),
                toggle("pl", "Show Playlist", rect["pl"]!, ctl.plVisible),
                toggle("clutterA", "Always on Top", rect["clutterA"]!, ctl.alwaysOnTop),
                toggle("clutterD", "Double Size", rect["clutterD"]!, ctl.doubleSize),
                button("clutterI", "File Info", rect["clutterI"]!),
                button("vis", "Change Visualization", rect["vis"]!),
                toggle("time", "Show Remaining Time", rect["time"]!, ctl.timeRemaining),
            ]
        }
        items += [
            button("options", "Options Menu", rect["options"]!),
            button("minimize", "Hide", rect["minimize"]!),
            toggle("shade", "Shade Mode", rect["shade"]!, ctl.mainShade),
            button("close", ctl.closeToDock ? "Close (keeps playing in the Dock)" : "Quit", rect["close"]!),
        ]
        return items
    }

    override func scrollWheel(with e: NSEvent) {
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / 4 : e.scrollingDeltaY * 2
        ctl.volume = max(0, min(100, ctl.volume + Double(d)))
    }

    override func cursorAreas() -> [(String, CGRect)] {
        if ctl.mainShade {
            return [("wsnormal", R(0, 0, 275, 14)), ("wsposbar", R(226, 4, 17, 7)), ("wswinbut", R(6, 3, 9, 9)),
                    ("wsmin", R(244, 3, 9, 9)), ("wswinbut", R(254, 3, 9, 9)), ("wsclose", R(264, 3, 9, 9))]
        }
        return [("normal", R(0, 0, 275, 116)), ("titlebar", R(0, 0, 275, 14)), ("mainmenu", R(6, 3, 9, 9)),
                ("min", R(244, 3, 9, 9)), ("winbut", R(254, 3, 9, 9)), ("close", R(264, 3, 9, 9)),
                ("songname", R(111, 24, 155, 12)), ("posbar", R(16, 72, 248, 10)),
                ("volbal", R(107, 57, 68, 13)), ("volbal", R(177, 57, 38, 13))]
    }
}

extension Renderer {
    /// Winamp visualizer in any rect: main window 76x16, shaded main 38x5, playlist 72x16.
    /// Rows map onto viscolor.txt's 16 spectrum colours, columns onto the 75 analyzer bins.
    func visualizer(_ ctl: Ctl, _ rect: CGRect, dots: Bool = true) {
        guard ctl.visMode != 2 else { return }
        let vc = skin.visColors
        let w = Int(rect.width), h = Int(rect.height)
        let x0 = rect.minX, y0 = rect.minY
        fill(vc[0], rect)
        if dots, h >= 16 {
            for y in stride(from: 1, to: h, by: 2) {
                for x in stride(from: 1, to: w, by: 2) { fill(vc[1], R(x0 + CGFloat(x), y0 + CGFloat(y), 1, 1)) }
            }
        }
        func rowColor(_ row: Int) -> CGColor { vc[2 + min(15, row * 16 / h)] }
        func bin(_ col: Int, _ cols: Int) -> Int { min(74, col * 75 / max(1, cols)) }

        if ctl.visMode == 0 {
            // Thick: bars of 3 px + 1 px gap. Thin: one-pixel columns.
            let thin = ctl.visThinBands
            let count = thin ? w : (w + 1) / 4
            for b in 0..<count {
                let lo = bin(b, count), hi = max(lo, bin(b + 1, count) - 1)
                var v: Float = 0, pk: Float = 0
                for i in lo...hi { v = max(v, ctl.visBars[i]); pk = max(pk, ctl.visPeaks[i]) }
                let x = x0 + CGFloat(thin ? b : b * 4), bw: CGFloat = thin ? 1 : 3
                let bh = Int((v * Float(h)).rounded())
                if bh > 0 {
                    for row in (h - bh)..<h { fill(rowColor(row), R(x, y0 + CGFloat(row), bw, 1)) }
                }
                let p = Int((pk * Float(h)).rounded())
                if ctl.visPeaksOn, p > 0, h >= 8 { fill(vc[23], R(x, y0 + CGFloat(h - p), bw, 1)) }
            }
        } else {
            let mid = h / 2
            var prev: Int?
            for x in 0..<w {
                let sample = ctl.visWave[min(75, x * 76 / w)]
                let y = max(0, min(h - 1, Int((Float(mid) - sample * Float(mid)).rounded())))
                let lo: Int, hi: Int
                switch ctl.oscStyle {
                case 0: (lo, hi) = (y, y)
                case 2: (lo, hi) = (min(mid, y), max(mid, y))
                default: (lo, hi) = prev.map { (min($0, y), max($0, y)) } ?? (y, y)
                }
                for yy in lo...hi {
                    let idx = 18 + min(4, abs(yy - mid) * 8 / max(1, h) )
                    fill(vc[idx], R(x0 + CGFloat(x), y0 + CGFloat(yy), 1, 1))
                }
                prev = y
            }
        }
    }
}
