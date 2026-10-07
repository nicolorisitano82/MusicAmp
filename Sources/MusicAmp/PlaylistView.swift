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

    /// Scroll position in rows; fractional, so trackpads and the wheel animation move the list pixel by pixel.
    var scrollPos: CGFloat = 0
    var scrollRow: Int {
        get { Int(floor(scrollPos)) }
        set { scrollPos = CGFloat(newValue) }
    }
    private var scrollTarget: CGFloat?
    private var scrollTimer: Timer?
    /// Display row under a y coordinate of the list.
    private func rowAt(_ y: CGFloat) -> Int { Int(floor(scrollPos + (y - 20) / rowH)) }

    // MARK: Artist → album → track view

    /// Closed headers (PlaylistTree.Node.key).
    private var collapsed: Set<String> = []
    private var treeCache: (key: Int, tree: PlaylistTree)?

    /// The tree when the grouped view is on, rebuilt only when the playlist or the closed headers change.
    var tree: PlaylistTree? {
        guard ctl.plTree else { return nil }
        var h = Hasher()
        h.combine(ctl.playlist.version)
        h.combine(collapsed)
        let key = h.finalize()
        if let c = treeCache, c.key == key { return c.tree }
        let t = PlaylistTree(ctl.playlist.tracks, collapsed: collapsed)
        treeCache = (key, t)
        return t
    }

    private var rowCount: Int { tree?.rows.count ?? ctl.playlist.tracks.count }

    /// Playlist index shown on a display row (nil for headers and past the end).
    private func trackAt(_ row: Int) -> Int? {
        if let tree {
            guard row >= 0, row < tree.rows.count, case .track(let i, _) = tree.rows[row] else { return nil }
            return i
        }
        return row >= 0 && row < ctl.playlist.tracks.count ? row : nil
    }

    private func displayRow(ofTrack i: Int) -> Int {
        guard let tree else { return i }
        return i < tree.rowOfTrack.count ? tree.rowOfTrack[i] : tree.rows.count
    }

    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        clampScroll()
        needsDisplay = true
    }
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
    /// Row boundary where dragged files would be inserted.
    private var dropIndex: Int?

    // MARK: Drop at the exact position

    private func dropRow(_ sender: NSDraggingInfo) -> Int? {
        let p0 = convert(sender.draggingLocation, from: nil)
        let p = CGPoint(x: p0.x / scale, y: p0.y / scale)
        guard !ctl.plShade else { return ctl.playlist.tracks.count }
        guard listRect.insetBy(dx: 0, dy: -4).contains(p) else { return ctl.playlist.tracks.count }
        let b = max(0, Int((scrollPos + (p.y - 20) / rowH).rounded()))
        guard let tree else { return min(ctl.playlist.tracks.count, b) }
        guard b < tree.rows.count else { return ctl.playlist.tracks.count }
        switch tree.rows[b] {
        case .track(let i, _): return i
        case .header(let n): return tree.nodes[n].tracks.min() ?? ctl.playlist.tracks.count
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let d = dropRow(sender)
        if d != dropIndex { dropIndex = d; needsDisplay = true }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropIndex = nil; needsDisplay = true }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        if urls.contains(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            ctl.handleDrop(urls, toPlaylist: true)
            return true
        }
        let at = dropRow(sender) ?? ctl.playlist.tracks.count
        ctl.playlist.insert(urls, at: at)
        if let first = ctl.playlist.selection.min() { ensureVisible(first) }
        return true
    }

    private var W: CGFloat { logicalSize.width }
    private var H: CGFloat { logicalSize.height }
    var visibleRows: Int { max(1, Int((H - 58) / rowH)) }
    private var maxScroll: Int { max(0, rowCount - visibleRows) }
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

    func clampScroll() { scrollPos = max(0, min(scrollPos, CGFloat(maxScroll))) }

    func ensureVisible(_ i: Int) {
        if let tree { collapsed.subtract(tree.hiding(i)) }
        let f = CGFloat(displayRow(ofTrack: i))
        if f < scrollPos { scrollPos = f } else if f + 1 > scrollPos + CGFloat(visibleRows) { scrollPos = f + 1 - CGFloat(visibleRows) }
        scrollTarget = nil
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
            let frac = scrollPos - floor(scrollPos)
            let tree = self.tree
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            for row in 0...visibleRows {
                let ri = scrollRow + row
                guard ri < rowCount else { break }
                let y = ((20 + (CGFloat(row) - frac) * rowH) * 2).rounded() / 2   // half-pixel steps: 1 device pixel on Retina
                if let tree, case .header(let n) = tree.rows[ri] {
                    // Artist / album header: disclosure triangle, name, track count and total length.
                    let node = tree.nodes[n]
                    if !node.tracks.isEmpty, node.tracks.allSatisfy(pl.selection.contains) { r.fill(st.selectedBG, R(12, y, W - 32, rowH)) }
                    let indent: CGFloat = node.kind == .artist ? 0 : 10
                    let col = node.tracks.contains(cur ?? -1) ? st.current : st.normal
                    let total = node.tracks.compactMap { pl.tracks[$0].duration }.reduce(0, +)
                    let rw = r.ttf("\(node.tracks.count) · \(Ctl.hmmss(total))", font: font, color: col, x: W - 22, baseline: y + baseline, maxWidth: 90, alignRight: true)
                    let open = !collapsed.contains(node.key)
                    r.ttf((open ? "▾ " : "▸ ") + node.title, font: bold, color: col, x: 14 + indent, baseline: y + baseline, maxWidth: W - 40 - indent - rw - 6)
                    continue
                }
                guard let i = trackAt(ri) else { continue }
                var depth = 0
                if let tree, case .track(_, let d) = tree.rows[ri] { depth = d }
                let t = pl.tracks[i]
                if pl.selection.contains(i) { r.fill(st.selectedBG, R(12, y, W - 32, rowH)) }
                let col = i == cur ? st.current : st.normal
                var durW: CGFloat = 0
                if let d = t.duration {
                    durW = r.ttf(Ctl.mmss(d), font: font, color: col, x: W - 22, baseline: y + baseline, maxWidth: 60, alignRight: true)
                }
                // Queue position, like Winamp's "[1]" before the length
                if let q = pl.queuePosition(t) {
                    durW += 4 + r.ttf("[\(q)]", font: font, color: col, x: W - 22 - durW - 4, baseline: y + baseline, maxWidth: 40, alignRight: true)
                }
                // Under an artist the title alone is enough (the full "Artist - Title" for compilations).
                var name = t.title
                if depth > 0, let tree, let pn = tree.parent(of: i), !tree.nodes[pn].variousArtists, let s = t.songTitle, !s.isEmpty { name = s }
                let label = ctl.plShowNumbers ? "\(i + 1). \(name)" : name
                let indent = CGFloat(depth) * 10 + (depth > 0 ? 8 : 0)
                r.ttf(label, font: font, color: col, x: 14 + indent, baseline: y + baseline, maxWidth: W - 40 - indent - durW - 6)
            }
        }

        // Insertion line while files are dragged over the list
        if let d0 = dropIndex, case let d = d0 >= pl.tracks.count ? rowCount : displayRow(ofTrack: d0),
           CGFloat(d) >= scrollPos, CGFloat(d) <= scrollPos + CGFloat(visibleRows) {
            let y = min(H - 39, (20 + (CGFloat(d) - scrollPos) * rowH).rounded())
            r.fill(st.current, R(12, y - 1, W - 32, 2))
        }

        // Scrollbar thumb
        let track = H - 58 - 18
        let f = maxScroll > 0 ? min(1, scrollPos / CGFloat(maxScroll)) : 0
        r.blit("pledit", scrolling ? R(61, 53, 8, 18) : R(52, 53, 8, 18), W - 15, 20 + (f * track).rounded())

        // Running time "selected/total" and mini time
        let sel = pl.selection.isEmpty ? "" : Ctl.hmmss(pl.selectedDuration)
        r.clip(R(W - 143, H - 28, 60, 6)) { r.text("\(sel.isEmpty ? "0:00" : sel)/\(Ctl.hmmss(pl.totalDuration))", W - 143, H - 28) }
        let a = ctl.audio
        if a.hasSource, a.state != .stopped {
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
        h.combine(scrollPos); h.combine(ctl.plShade); h.combine(ctl.plW); h.combine(ctl.plH)
        h.combine(ctl.plFontSize); h.combine(ctl.plShowNumbers); h.combine(ctl.plUseSkinFont)
        h.combine(pressed); h.combine(pressInside); h.combine(openMenu?.id); h.combine(menuHover); h.combine(scrolling)
        h.combine(dropIndex); h.combine(ctl.plTree); h.combine(collapsed)
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
            let ri = rowAt(p.y)
            if let tree, ri >= 0, ri < tree.rows.count, case .header(let n) = tree.rows[ri] {
                let node = tree.nodes[n]
                let indent: CGFloat = node.kind == .artist ? 0 : 10
                if p.x < 14 + indent + 9 {
                    toggle(node.key)   // the triangle opens/closes
                } else if e.clickCount == 2 {
                    if let f = node.tracks.first { ctl.playIndex(f) }
                } else if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.shift) {
                    pl.selection.formUnion(node.tracks)
                } else {
                    pl.selection = Set(node.tracks)
                    anchor = node.tracks.first
                }
                return true
            }
            guard let i = trackAt(ri) else {
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
                if tree == nil { dragRow = i }   // reordering by drag only in the flat list
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
            let i = max(0, min(ctl.playlist.tracks.count - 1, trackAt(rowAt(p.y)) ?? d))
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
               trackAt(rowAt(p.y)) == d, listRect.contains(p) {
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
        scrollTarget = nil
        scrollPos = f * CGFloat(maxScroll)
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

    /// ⌘A from the Edit menu selects every row.
    override func selectAll(_ sender: Any?) {
        ctl.playlist.selection = Set(ctl.playlist.tracks.indices)
    }

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
        case 123, 124 where tree != nil:   // ←/→ close/open the album (then the artist) of the selection
            guard let tree, let i = pl.selection.min() else { return }
            let owners = tree.nodes.filter { $0.tracks.contains(i) }   // artist first, then album
            if e.keyCode == 123 {
                if let open = owners.last(where: { !collapsed.contains($0.key) }) { collapsed.insert(open.key) }
            } else {
                collapsed.subtract(owners.map(\.key))
            }
            clampScroll()
            needsDisplay = true
            return
        case 12 where e.modifierFlags.intersection([.command, .control, .option]).isEmpty:   // Q
            ctl.queueSelected()
            return
        case 126, 125:
            guard !pl.tracks.isEmpty else { return }
            let d = e.keyCode == 126 ? -1 : 1
            if e.modifierFlags.contains(.option) {
                pl.moveSelection(by: d)
            } else if let tree {
                // Next/previous visible track in tree order.
                let base = d < 0 ? (pl.selection.min() ?? 0) : (pl.selection.max() ?? 0)
                var r = pl.selection.isEmpty ? (d > 0 ? -1 : tree.rows.count) : displayRow(ofTrack: base)
                repeat { r += d } while r >= 0 && r < tree.rows.count && trackAt(r) == nil
                if let i = trackAt(r) { pl.selection = [i]; anchor = i }
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

        super.keyDown(with: e)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas {
            // Trackpad / Magic Mouse: follow the fingers (and the momentum) pixel by pixel.
            scrollTarget = nil
            scrollPos -= e.scrollingDeltaY / (rowH * scale)
            clampScroll()
            needsDisplay = true
            return
        }
        // Mouse wheel: 3 rows per notch, eased over a few frames instead of jumping.
        let target = max(0, min(CGFloat(maxScroll), (scrollTarget ?? scrollPos.rounded()) - e.scrollingDeltaY * 3))
        scrollTarget = target
        guard scrollTimer == nil else { return }
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, let target = self.scrollTarget else { t.invalidate(); self?.scrollTimer = nil; return }
            let d = target - self.scrollPos
            if abs(d) < 0.02 {
                self.scrollPos = target
                self.scrollTarget = nil
            } else {
                self.scrollPos += d * 0.3
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(scrollTimer!, forMode: .common)
    }

    // MARK: VoiceOver

    override var accessibilityName: String { "Playlist" }

    private static let menuLabels: [String: String] = [
        "url": "Aggiungi URL", "dir": "Aggiungi cartella", "file": "Aggiungi file",
        "remall": "Rimuovi tutto", "crop": "Tieni solo la selezione", "remsel": "Rimuovi selezionati", "remmisc": "Altre rimozioni",
        "invsel": "Inverti selezione", "selzero": "Deseleziona tutto", "selall": "Seleziona tutto",
        "sort": "Ordina", "fileinfo": "Info file", "miscopts": "Altre opzioni",
        "newlist": "Nuova playlist", "savelist": "Salva playlist", "loadlist": "Carica playlist",
    ]

    /// Native, VoiceOver-readable version of a sprite popup menu (ADD/REM/SEL/MISC/LIST).
    private func nativeMenu(_ id: String) -> NSMenu {
        let m = NSMenu()
        for (_, action) in menus[id]?.items ?? [] {
            let it = NSMenuItem(title: Self.menuLabels[action] ?? action, action: #selector(nativeMenuAction(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = action
            m.addItem(it)
        }
        return m
    }

    @objc private func nativeMenuAction(_ sender: NSMenuItem) {
        if let a = sender.representedObject as? String { menuAction(a) }
    }

    override func accessibilityItems() -> [AXItem] {
        let pl = ctl.playlist
        func button(_ id: String, _ label: String, _ action: @escaping () -> Void) -> AXItem? {
            guard let r = buttonRects().first(where: { $0.0 == id })?.1 else { return nil }
            return AXItem(id: id, kind: .button, label: label, rect: r, press: action)
        }
        var items: [AXItem] = []
        if ctl.plShade {
            if let i = pl.current ?? pl.selection.min() ?? (pl.tracks.isEmpty ? nil : 0) {
                items.append(AXItem(id: "shadeTitle", kind: .text, label: "Brano", rect: R(5, 3, W - 40, 8),
                                    value: "\(i + 1). \(pl.tracks[i].title)"))
            }
        } else {
            let cur = pl.current
            let tree = self.tree
            for row in 0..<visibleRows {
                let ri = scrollRow + row
                guard ri < rowCount else { break }
                if let tree, case .header(let n) = tree.rows[ri] {
                    let node = tree.nodes[n], open = !collapsed.contains(node.key)
                    items.append(AXItem(id: "hdr-\(node.key)", kind: .row,
                                        label: "\(node.kind == .artist ? "Artista" : "Album") \(node.title), \(node.tracks.count) brani",
                                        rect: R(12, 20 + CGFloat(row) * rowH, W - 32, rowH), value: open ? "aperto" : "chiuso",
                                        press: { [weak self] in self?.toggle(node.key) }))
                    continue
                }
                guard let i = trackAt(ri) else { continue }
                let t = pl.tracks[i]
                var state: [String] = []
                if i == cur { state.append("in riproduzione") }
                if pl.selection.contains(i) { state.append("selezionato") }
                if let q = pl.queuePosition(t) { state.append("in coda, posizione \(q)") }
                if let d = t.duration { state.append(AXText.time(d)) }
                items.append(AXItem(id: "row-\(ObjectIdentifier(t).hashValue)", kind: .row, label: "\(i + 1). \(t.title)",
                                    rect: R(12, 20 + CGFloat(row) * rowH, W - 32, rowH), value: state.joined(separator: ", "),
                                    selected: pl.selection.contains(i),
                                    press: { [weak self] in self?.ctl.playIndex(i) }))
            }
            if maxScroll > 0 {
                items.append(AXItem(id: "scroll", kind: .slider, label: "Scorrimento playlist", rect: R(W - 15, 20, 8, H - 58),
                                    value: "righe \(scrollRow + 1)–\(min(pl.tracks.count, scrollRow + visibleRows)) di \(pl.tracks.count)",
                                    increment: { [weak self] in self.map { $0.scrollRow += $0.visibleRows; $0.clampScroll() } },
                                    decrement: { [weak self] in self.map { $0.scrollRow -= $0.visibleRows; $0.clampScroll() } }))
            }
            for (id, label) in [("add", "Aggiungi"), ("rem", "Rimuovi"), ("sel", "Selezione"), ("misc", "Varie"), ("list", "Playlist")] {
                if let b = button(id, label, { [weak self] in
                    guard let self, let r = self.buttonRects().first(where: { $0.0 == id })?.1 else { return }
                    self.popUp(self.nativeMenu(id), at: CGPoint(x: r.minX, y: r.minY))
                }) { items.append(b) }
            }
            items += [
                button("prev", "Brano precedente") { [weak self] in self?.ctl.previous() },
                button("play", "Riproduci") { [weak self] in self?.ctl.play() },
                button("pause", "Pausa") { [weak self] in self?.ctl.pause() },
                button("stop", "Stop") { [weak self] in self?.ctl.stop() },
                button("next", "Brano successivo") { [weak self] in self?.ctl.next() },
                button("eject", "Apri file") { [weak self] in self?.ctl.openFiles() },
            ].compactMap { $0 }
        }
        items += [
            button("shade", ctl.plShade ? "Espandi playlist" : "Riduci playlist") { [weak self] in self?.ctl.togglePLShade() },
            button("close", "Chiudi playlist") { [weak self] in self?.ctl.togglePL() },
        ].compactMap { $0 }
        return items
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
