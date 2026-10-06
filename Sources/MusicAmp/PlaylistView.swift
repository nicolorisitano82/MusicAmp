import AppKit

final class PlaylistView: SkinView {
    override var logicalSize: CGSize {
        CGSize(width: 275 + 25 * CGFloat(ctl.plW), height: ctl.plShade ? 14 : 116 + 29 * CGFloat(ctl.plH))
    }

    private struct SpriteMenu {
        let bar: CGRect
        let items: [(CGRect, String)]
    }

    /// Winamp's playlist popup menus, drawn from PLEDIT.BMP (selected sprite = x + 23).
    private let menus: [String: SpriteMenu] = [
        "add": SpriteMenu(bar: R(48, 111, 3, 54), items: [(R(0, 111, 22, 18), "url"), (R(0, 130, 22, 18), "dir"), (R(0, 149, 22, 18), "file")]),
        "rem": SpriteMenu(bar: R(100, 111, 3, 72), items: [(R(54, 111, 22, 18), "remall"), (R(54, 130, 22, 18), "crop"),
                                                           (R(54, 149, 22, 18), "remsel"), (R(54, 168, 22, 18), "remmisc")]),
        "sel": SpriteMenu(bar: R(150, 111, 3, 54), items: [(R(104, 111, 22, 18), "invsel"), (R(104, 130, 22, 18), "selzero"), (R(104, 149, 22, 18), "selall")]),
        "misc": SpriteMenu(bar: R(200, 111, 3, 54), items: [(R(154, 111, 22, 18), "sort"), (R(154, 130, 22, 18), "fileinfo"), (R(154, 149, 22, 18), "miscopts")]),
        "list": SpriteMenu(bar: R(250, 111, 3, 54), items: [(R(204, 111, 22, 18), "newlist"), (R(204, 130, 22, 18), "savelist"), (R(204, 149, 22, 18), "loadlist")]),
    ]

    var scrollRow = 0
    private var rowH: CGFloat { CGFloat(max(10, ctl.plFontSize + 4)) }
    private var pressed: String?
    private var pressInside = false
    private var resizeStart: (mouse: NSPoint, w: Int, h: Int)?
    private var scrolling = false
    private var anchor: Int?
    private var dragRow: Int?
    private var openMenu: (id: String, button: CGRect)?
    private var menuHover: Int?
    private var menuSticky = false
    private var scrollAccum: CGFloat = 0

    private var W: CGFloat { logicalSize.width }
    private var H: CGFloat { logicalSize.height }
    var visibleRows: Int { max(1, Int((H - 58) / rowH)) }
    private var maxScroll: Int { max(0, ctl.playlist.tracks.count - visibleRows) }
    private var listRect: CGRect { R(12, 20, W - 32, H - 58) }

    private func buttonRects() -> [(String, CGRect)] {
        if ctl.plShade { return [("shade", R(W - 20, 3, 9, 9)), ("close", R(W - 10, 3, 9, 9))] }
        return [("close", R(W - 11, 3, 9, 9)), ("shade", R(W - 20, 3, 9, 9)),
         ("add", R(14, H - 30, 22, 18)), ("rem", R(43, H - 30, 22, 18)), ("sel", R(72, H - 30, 22, 18)),
         ("misc", R(101, H - 30, 22, 18)), ("list", R(W - 46, H - 30, 22, 18)),
         ("prev", R(W - 147, H - 16, 7, 8)), ("play", R(W - 139, H - 16, 9, 8)), ("pause", R(W - 130, H - 16, 8, 8)),
         ("stop", R(W - 121, H - 16, 9, 8)), ("next", R(W - 112, H - 16, 7, 8)), ("eject", R(W - 104, H - 16, 9, 8))]
    }

    private func menuItemRects() -> [CGRect] {
        guard let (id, b) = openMenu, let m = menus[id] else { return [] }
        let n = m.items.count
        return (0..<n).map { R(b.minX, b.maxY - CGFloat(n - $0) * 18, 22, 18) }
    }

    func clampScroll() { scrollRow = max(0, min(scrollRow, maxScroll)) }

    func ensureVisible(_ i: Int) {
        if i < scrollRow { scrollRow = i } else if i >= scrollRow + visibleRows { scrollRow = i - visibleRows + 1 }
        clampScroll()
    }

    // MARK: Render

    /// Shaded playlist: 14 px bar with the current entry and its length (PLEDIT.BMP x72..158, y42..70).
    private func renderShade(_ r: Renderer) {
        r.blit("pledit", R(72, 42, 25, 14), 0, 0)
        r.tileX("pledit", R(72, 57, 25, 14), 25, 0, width: W - 75)
        r.blit("pledit", isActive ? R(99, 42, 50, 14) : R(99, 57, 50, 14), W - 50, 0)
        if down("shade") { r.blit("pledit", R(150, 42, 9, 9), W - 20, 3) }
        if down("close") { r.blit("pledit", R(52, 42, 9, 9), W - 10, 3) }

        let pl = ctl.playlist
        guard let i = pl.current ?? pl.selection.min() ?? (pl.tracks.isEmpty ? nil : 0) else { return }
        let t = pl.tracks[i]
        let time = t.duration.map { Ctl.mmss($0) } ?? ""
        let timeX = W - 30 - CGFloat(time.count * 5)
        r.text(time, timeX, 4)
        let label = ctl.plShowNumbers ? "\(i + 1). \(t.title)" : t.title
        r.clip(R(5, 4, timeX - 5 - 5, 6)) { r.text(label, 5, 4) }
    }

    override func render(_ r: Renderer) {
        if ctl.plShade { renderShade(r); return }
        let pl = ctl.playlist
        let st = skin.playlist
        let y0: CGFloat = isActive ? 0 : 21

        // Frame
        r.tileX("pledit", R(127, y0, 25, 20), 25, 0, width: W - 50)
        r.blit("pledit", R(0, y0, 25, 20), 0, 0)
        r.blit("pledit", R(26, y0, 100, 20), ((W - 100) / 2).rounded(.down), 0)
        r.blit("pledit", R(153, y0, 25, 20), W - 25, 0)
        r.tileY("pledit", R(0, 42, 12, 29), 0, 20, height: H - 58)
        r.tileY("pledit", R(31, 42, 20, 29), W - 20, 20, height: H - 58)
        r.tileX("pledit", R(179, 0, 25, 38), 125, H - 38, width: W - 275)
        r.blit("pledit", R(0, 72, 125, 38), 0, H - 38)
        r.blit("pledit", R(126, 72, 150, 38), W - 150, H - 38)
        if down("close") { r.blit("pledit", R(52, 42, 9, 9), W - 11, 3) }
        if down("shade") { r.blit("pledit", R(62, 42, 9, 9), W - 20, 3) }
        // With the main window shaded, Winamp moves the visualizer here (needs 75 px of bottom tile).
        if ctl.plVisDisplayed {
            r.blit("pledit", R(205, 0, 75, 38), W - 225, H - 38)
            if ctl.audio.state == .playing || ctl.snapshotMode { r.visualizer(ctl, R(W - 223, H - 27, 72, 16)) }
        }

        // List
        let list = listRect
        r.fill(st.normalBG, list)
        let fs = CGFloat(ctl.plFontSize)
        let font = ctl.plUseSkinFont ? FontResolver.shared.font(st.font, size: fs) : (NSFont(name: "Arial", size: fs) ?? .systemFont(ofSize: fs))
        let baseline = ((rowH + fs * 0.7) / 2).rounded()
        let cur = pl.current
        r.clip(list) {
            for row in 0..<visibleRows {
                let i = scrollRow + row
                guard i < pl.tracks.count else { break }
                let t = pl.tracks[i]
                let y = 20 + CGFloat(row) * rowH
                if pl.selection.contains(i) { r.fill(st.selectedBG, R(12, y, W - 32, rowH)) }
                let col = i == cur ? st.current : st.normal
                var durW: CGFloat = 0
                if let d = t.duration {
                    durW = r.ttf(Ctl.mmss(d), font: font, color: col, x: W - 22, baseline: y + baseline, maxWidth: 60, alignRight: true)
                }
                let label = ctl.plShowNumbers ? "\(i + 1). \(t.title)" : t.title
                r.ttf(label, font: font, color: col, x: 14, baseline: y + baseline, maxWidth: W - 40 - durW - 6)
            }
        }

        // Scrollbar thumb
        let track = H - 58 - 18
        let f = maxScroll > 0 ? CGFloat(scrollRow) / CGFloat(maxScroll) : 0
        r.blit("pledit", scrolling ? R(61, 53, 8, 18) : R(52, 53, 8, 18), W - 15, 20 + (f * track).rounded())

        // Running time "selected/total" and mini time
        let sel = pl.selection.isEmpty ? "" : Ctl.hmmss(pl.selectedDuration)
        r.clip(R(W - 143, H - 28, 60, 6)) { r.text("\(sel.isEmpty ? "0:00" : sel)/\(Ctl.hmmss(pl.totalDuration))", W - 143, H - 28) }
        let a = ctl.audio
        if a.file != nil, a.state != .stopped {
            let t = ctl.timeRemaining ? max(0, a.duration - a.currentTime) : a.currentTime
            let s = (ctl.timeRemaining ? "-" : "") + Ctl.mmss(t)
            r.text(String(repeating: " ", count: max(0, 5 - s.count)) + s, W - 84, H - 15)
        }

        // Open sprite menu
        if let (id, b) = openMenu, let m = menus[id] {
            let rects = menuItemRects()
            let n = CGFloat(m.items.count)
            r.blit("pledit", R(m.bar.minX, m.bar.minY, 3, n * 18), b.minX - 3, b.maxY - n * 18)
            for (k, item) in m.items.enumerated() {
                let src = menuHover == k ? item.0.offsetBy(dx: 23, dy: 0) : item.0
                r.blit("pledit", src, rects[k].minX, rects[k].minY)
            }
        }
    }

    private func down(_ id: String) -> Bool { pressed == id && pressInside }

    override var renderSignature: Int {
        let a = ctl.audio
        var h = Hasher()
        h.combine(isActive); h.combine(ObjectIdentifier(skin)); h.combine(ctl.playlist.version)
        h.combine("\(a.state)"); h.combine(a.state == .stopped ? 0 : Int(a.currentTime)); h.combine(ctl.timeRemaining)
        h.combine(scrollRow); h.combine(ctl.plShade); h.combine(ctl.plW); h.combine(ctl.plH)
        h.combine(ctl.plFontSize); h.combine(ctl.plShowNumbers); h.combine(ctl.plUseSkinFont)
        h.combine(pressed); h.combine(pressInside); h.combine(openMenu?.id); h.combine(menuHover); h.combine(scrolling)
        return h.finalize()
    }

    // MARK: Mouse

    override func hitDown(_ p: CGPoint, _ e: NSEvent) -> Bool {
        if ctl.plShade {
            if R(W - 29, 0, 8, 14).contains(p) {
                resizeStart = (NSEvent.mouseLocation, ctl.plW, ctl.plH)
                return true
            }
            for (id, r) in buttonRects() where r.contains(p) {
                pressed = id
                pressInside = true
                return true
            }
            if e.clickCount == 2 { ctl.togglePLShade(); return true }
            return false
        }
        if p.y < 20, e.clickCount == 2, !buttonRects().contains(where: { $0.1.contains(p) }) {
            ctl.togglePLShade()
            return true
        }
        let pl = ctl.playlist
        if openMenu != nil {
            if let k = menuItemRects().firstIndex(where: { $0.contains(p) }) {
                menuHover = k
                return true   // performed on mouse up
            }
            closeMenu()
        }
        if R(W - 20, H - 20, 20, 20).contains(p) {
            resizeStart = (NSEvent.mouseLocation, ctl.plW, ctl.plH)
            return true
        }
        for (id, r) in buttonRects() where r.contains(p) {
            if menus[id] != nil {
                openMenu = (id, r)
                menuHover = nil
                menuSticky = false
                return true
            }
            pressed = id
            pressInside = true
            return true
        }
        if R(W - 15, 20, 8, H - 58).contains(p) {
            scrolling = true
            scrollTo(p)
            return true
        }
        if listRect.contains(p) {
            let i = scrollRow + Int((p.y - 20) / rowH)
            guard i < pl.tracks.count else {
                pl.selection = []
                return true
            }
            if e.clickCount == 2 {
                ctl.playIndex(i)
                return true
            }
            if e.modifierFlags.contains(.shift), let a = anchor {
                pl.selection = Set(min(a, i)...max(a, i))
            } else if e.modifierFlags.contains(.command) {
                if pl.selection.contains(i) { pl.selection.remove(i) } else { pl.selection.insert(i) }
                anchor = i
            } else {
                if !pl.selection.contains(i) { pl.selection = [i] }
                anchor = i
                dragRow = i
            }
            return true
        }
        return false
    }

    override func hitDrag(_ p: CGPoint, _ e: NSEvent) {
        if let rs = resizeStart {
            let m = NSEvent.mouseLocation
            let dx = (m.x - rs.mouse.x) / scale, dy = (rs.mouse.y - m.y) / scale
            let nw = max(0, rs.w + Int((dx / 25).rounded()))
            let nh = ctl.plShade ? rs.h : max(0, rs.h + Int((dy / 29).rounded()))
            if nw != ctl.plW || nh != ctl.plH { ctl.setPlaylistSize(nw, nh) }
            return
        }
        if openMenu != nil {
            menuHover = menuItemRects().firstIndex { $0.contains(p) }
            return
        }
        if scrolling { scrollTo(p); return }
        if let d = dragRow {
            let i = max(0, min(ctl.playlist.tracks.count - 1, scrollRow + Int(floor((p.y - 20) / rowH))))
            if i != d {
                ctl.playlist.moveSelection(by: i - d)
                dragRow = i
                anchor = i
                ensureVisible(i)
            }
            return
        }
        if let id = pressed { pressInside = buttonRects().first { $0.0 == id }?.1.contains(p) ?? false }
    }

    override func hitUp(_ p: CGPoint, _ e: NSEvent) {
        resizeStart = nil
        scrolling = false
        if let d = dragRow {
            dragRow = nil
            // A plain click on an already-selected row (no move) collapses the selection to it.
            if !e.modifierFlags.contains(.shift), !e.modifierFlags.contains(.command),
               scrollRow + Int((p.y - 20) / rowH) == d, listRect.contains(p) {
                ctl.playlist.selection = [d]
            }
        }
        if let (id, b) = openMenu {
            if let k = menuItemRects().firstIndex(where: { $0.contains(p) }), let m = menus[id] {
                closeMenu()
                menuAction(m.items[k].1)
            } else if b.contains(p), !menuSticky {
                menuSticky = true   // simple click on the button: keep the menu open
            } else {
                closeMenu()
            }
            return
        }
        defer { pressed = nil }
        guard let id = pressed, pressInside else { return }
        switch id {
        case "close": ctl.togglePL()
        case "shade": ctl.togglePLShade()
        case "prev": ctl.previous()
        case "play": ctl.play()
        case "pause": ctl.pause()
        case "stop": ctl.stop()
        case "next": ctl.next()
        case "eject": ctl.openFiles()
        default: break
        }
    }

    private func closeMenu() {
        openMenu = nil
        menuHover = nil
        menuSticky = false
    }

    private func scrollTo(_ p: CGPoint) {
        let track = H - 58 - 18
        let f = max(0, min(1, (p.y - 20 - 9) / track))
        scrollRow = Int((f * CGFloat(maxScroll)).rounded())
    }

    private func menuAction(_ a: String) {
        let pl = ctl.playlist
        switch a {
        case "url": ctl.addURL()
        case "dir": ctl.addFolder()
        case "file": ctl.addFiles()
        case "remall", "newlist": ctl.clearPlaylist()
        case "crop": pl.crop(pl.selection)
        case "remsel": pl.remove(pl.selection)
        case "remmisc": popUp(ctl.removeMiscMenu(), at: CGPoint(x: 43, y: H - 30))
        case "invsel": pl.selection = Set(pl.tracks.indices).subtracting(pl.selection)
        case "selzero": pl.selection = []
        case "selall": pl.selection = Set(pl.tracks.indices)
        case "sort": popUp(ctl.sortMenu(), at: CGPoint(x: 101, y: H - 30))
        case "fileinfo": ctl.showFileInfo(pl.selection.min())
        case "miscopts": popUp(ctl.miscOptionsMenu(), at: CGPoint(x: 101, y: H - 30))
        case "savelist": ctl.savePlaylistFile()
        case "loadlist": ctl.loadPlaylistFile()
        default: break
        }
        clampScroll()
    }

    // MARK: Keyboard / wheel

    override func keyDown(with e: NSEvent) {
        let pl = ctl.playlist
        switch e.keyCode {
        case 51, 117:
            pl.remove(pl.selection)
            clampScroll()
            return
        case 36, 76:
            if let i = pl.selection.min() { ctl.playIndex(i) }
            return
        case 126, 125:
            guard !pl.tracks.isEmpty else { return }
            let d = e.keyCode == 126 ? -1 : 1
            if e.modifierFlags.contains(.option) {
                pl.moveSelection(by: d)
            } else {
                let base = d < 0 ? (pl.selection.min() ?? 1) : (pl.selection.max() ?? -1)
                let i = max(0, min(pl.tracks.count - 1, base + d))
                pl.selection = [i]
                anchor = i
            }
            if let i = pl.selection.min() { ensureVisible(i) }
            return
        default: break
        }
        if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "a" {
            pl.selection = Set(pl.tracks.indices)
            return
        }
        super.keyDown(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        scrollAccum -= e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / (rowH * scale) : e.scrollingDeltaY * 3
        let steps = Int(scrollAccum)
        if steps != 0 {
            scrollAccum -= CGFloat(steps)
            scrollRow += steps
            clampScroll()
        }
    }

    override func cursorAreas() -> [(String, CGRect)] {
        if ctl.plShade {
            return [("pwsnorm", R(0, 0, W, 14)), ("pwssize", R(W - 29, 0, 8, 14)),
                    ("pwinbut", R(W - 20, 3, 9, 9)), ("pclose", R(W - 10, 3, 9, 9))]
        }
        return [("pnormal", R(0, 0, W, H)), ("ptbar", R(0, 0, W, 20)), ("pwinbut", R(W - 20, 3, 9, 9)), ("pclose", R(W - 11, 3, 9, 9)),
         ("pvscroll", R(W - 15, 20, 8, H - 58)), ("psize", R(W - 20, H - 20, 20, 20))]
    }
}
