import AppKit
import UniformTypeIdentifiers

/// The storyboard as a PDF (A4 landscape): a cover with every picture; "from the lyrics to the pictures", the
/// steps that made them (song structure, the reader's notes, the director's choices); then one page per picture
/// with what that part of the lyrics says, the shot, the exact prompt and what Vision saw.
@MainActor
enum LiveVideoExport {
    static let page = CGSize(width: 842, height: 595)
    static let margin: CGFloat = 36

    /// Asks where to save, then writes the PDF.
    static func save() {
        let live = LiveVideo.shared
        guard let b = live.board else { NSSound.beep(); return }
        let c = Ctl.shared
        let title = c.playlist.currentTrack?.songTitle ?? c.playlist.currentTrack?.title ?? "Song"
        let artist = c.playlist.currentTrack?.artist ?? ""
        let p = NSSavePanel()
        p.allowedContentTypes = [.pdf]
        p.nameFieldStringValue = "\(artist.isEmpty ? "" : artist + " - ")\(title) - storyboard.pdf"
        p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard p.runModal() == .OK, let url = p.url else { return }
        let lyrics = LyricsService.shared.lyrics
        let pictures = (0..<b.imageCount).map { i in live.images[i] ?? LiveVideo.load(LiveVideo.cacheFolder.appendingPathComponent(b.key).appendingPathComponent("image\(i).jpg")) }
        write(b, pictures: pictures, title: title, artist: artist, lyrics: lyrics, model: live.model?.label ?? "", to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Drawing helpers

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    /// Draws `text` in a column from `y` downwards (PDF coordinates grow upwards); returns the new y.
    @discardableResult
    private static func text(_ s: String, at y: CGFloat, x: CGFloat, width: CGFloat, size: CGFloat = 10, weight: NSFont.Weight = .regular,
                             color: NSColor = .black) -> CGFloat {
        guard !s.isEmpty else { return y }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        let a = NSAttributedString(string: s, attributes: [.font: font(size, weight), .foregroundColor: color, .paragraphStyle: para])
        let h = ceil(a.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        a.draw(with: CGRect(x: x, y: y - h, width: width, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return y - h - 4
    }

    private static func heading(_ s: String, at y: CGFloat, x: CGFloat, width: CGFloat) -> CGFloat {
        text(s.uppercased(), at: y - 4, x: x, width: width, size: 8.5, weight: .bold, color: NSColor(white: 0.45, alpha: 1))
    }

    private static func time(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }

    /// Start and end of a section from the synced lyrics.
    private static func span(_ scene: LiveVideoScene, lyrics: Lyrics?) -> String {
        guard scene.firstLine >= 0, let s = lyrics?.synced, s.indices.contains(scene.firstLine) else { return "" }
        let end = scene.lastLine + 1 < s.count ? s[scene.lastLine + 1].time : (s.last?.time ?? 0) + 4
        return "\(time(s[scene.firstLine].time))–\(time(end))"
    }

    private static func lines(_ scene: LiveVideoScene, lyrics: Lyrics?) -> String {
        guard scene.firstLine >= 0 else { return "" }
        let all = lyrics?.synced?.map(\.text) ?? (lyrics?.plain ?? "").components(separatedBy: .newlines)
        guard all.indices.contains(scene.firstLine) else { return "" }
        return all[scene.firstLine...min(scene.lastLine, all.count - 1)].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
    }

    // MARK: Pages

    static func write(_ b: LiveVideoBoard, pictures: [CGImage?], title: String, artist: String, lyrics: Lyrics?, model: String, to url: URL) {
        var box = CGRect(origin: .zero, size: page)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "\(title) — storyboard", kCGPDFContextCreator: "MusicAmp"] as CFDictionary) else { return }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = nil; ctx.closePDF() }
        let r = b.reasoning
        let W = page.width - 2 * margin

        // 1. Cover: the song and every picture.
        ctx.beginPDFPage(nil)
        var y = page.height - margin
        y = text(title, at: y, x: margin, width: W, size: 22, weight: .bold)
        y = text([artist, L("Live Video storyboard"), model, LiveVideoStyle(rawValue: b.style)?.label ?? b.style].filter { !$0.isEmpty }.joined(separator: " · "),
                 at: y, x: margin, width: W, size: 11, color: .darkGray)
        y = text(b.theme, at: y - 6, x: margin, width: W, size: 12, weight: .medium)
        let cell: CGFloat = min(170, (W - 3 * 12) / 4)
        for (i, img) in pictures.enumerated() {
            let col = CGFloat(i % 4), row = CGFloat(i / 4)
            let rect = CGRect(x: margin + col * (cell + 12), y: y - 16 - (row + 1) * (cell + 22), width: cell, height: cell)
            if let img { ctx.draw(img, in: rect) }
            text("\(i + 1) · \(r?.sections.indices.contains(i) == true ? L(r!.sections[i]) : "")", at: rect.minY - 2, x: rect.minX, width: cell, size: 8.5, color: .darkGray)
        }
        ctx.endPDFPage()

        // 2. From the lyrics to the pictures.
        ctx.beginPDFPage(nil)
        y = page.height - margin
        y = text(L("From the lyrics to the pictures"), at: y, x: margin, width: W, size: 18, weight: .bold)
        let colW = (W - 24) / 2
        var left = y - 8, right = y - 8
        left = heading("1 · " + L("Song structure (code)"), at: left, x: margin, width: colW)
        left = text(L("Repeated lines are the chorus and refrains; the parts between are verses. A part that comes back shows its picture again, framed differently."),
                    at: left, x: margin, width: colW, size: 8.5, color: .darkGray)
        for sc in b.scenes {
            left = text("\(L(sc.kind)) \(span(sc, lyrics: lyrics)) → \(L("picture")) \(sc.image + 1)\(sc.variation > 0 ? " ↺" : "")", at: left, x: margin, width: colW, size: 9.5)
        }
        if let r {
            let who = r.reader.isEmpty ? "Apple Intelligence" : r.reader
            left = heading("2 · " + String(format: L("The reader's notes (%@)"), who), at: left - 6, x: margin, width: colW)
            for (k, v) in [(L("Who speaks"), r.voice), (L("People"), r.people), (L("World"), r.world), (L("Mood"), r.mood), (L("Meaning"), r.theme)] where !v.isEmpty {
                left = text("\(k): \(v)", at: left, x: margin, width: colW, size: 9.5)
            }
            right = heading("3 · " + String(format: L("The director's choices (%@)"), who), at: right, x: margin + colW + 24, width: colW)
            right = text(L("The director never sees the lyrics, only the reader's notes."), at: right, x: margin + colW + 24, width: colW, size: 8.5, color: .darkGray)
            for c in r.cast { right = text(c, at: right, x: margin + colW + 24, width: colW, size: 9.5) }
            right = text(L("Places") + ": " + r.places.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; "), at: right, x: margin + colW + 24, width: colW, size: 9.5)
            right = text(L("Look") + ": " + (LiveVideoStyle(rawValue: r.look)?.label ?? r.look), at: right, x: margin + colW + 24, width: colW, size: 9.5)
            if !r.posesFixed.isEmpty {
                right = text(L("Shots first written as poses, sent back to become actions") + ": " + r.posesFixed.joined(separator: "; "),
                             at: right, x: margin + colW + 24, width: colW, size: 9, color: .darkGray)
            }
            right = heading("4 · " + L("Prompts (code)"), at: right - 6, x: margin + colW + 24, width: colW)
            right = text(L("The event first (people by their clothes, action, place), then the look, the framing, the light and the mood, within about 60 words. Nudity is always excluded."),
                         at: right, x: margin + colW + 24, width: colW, size: 9)
            right = heading("5 · " + L("Vision check"), at: right - 6, x: margin + colW + 24, width: colW)
            _ = text(L("Each picture is checked for people, framing and place; a clear miss is painted once more and the better one kept."),
                     at: right, x: margin + colW + 24, width: colW, size: 9)
        }
        ctx.endPDFPage()

        // 3. One page per picture.
        for i in 0..<b.imageCount {
            ctx.beginPDFPage(nil)
            let side: CGFloat = 330
            if let img = pictures[i] { ctx.draw(img, in: CGRect(x: margin, y: page.height - margin - side, width: side, height: side)) }
            let x = margin + side + 24, w = page.width - x - margin
            y = page.height - margin
            let uses = b.scenes.filter { $0.image == i }
            y = text("\(L("Picture")) \(i + 1) · " + uses.map { "\(L($0.kind)) \(span($0, lyrics: lyrics))" }.joined(separator: ", "), at: y, x: x, width: w, size: 14, weight: .bold)
            if let first = uses.first {
                y = heading(L("The lyrics"), at: y - 2, x: x, width: w)
                y = text(lines(first, lyrics: lyrics), at: y, x: x, width: w, size: 9.5, color: .darkGray)
            }
            if let r, r.meanings.indices.contains(i), !r.meanings[i].isEmpty {
                y = heading(L("What they say (reader)"), at: y - 2, x: x, width: w)
                y = text(r.meanings[i], at: y, x: x, width: w, size: 10.5)
            }
            if b.shotInfo.indices.contains(i) {
                let s = b.shotInfo[i]
                y = heading(L("The shot (director)"), at: y - 2, x: x, width: w)
                y = text("\(s.framing) · \(L("who")): \(s.who) · \(s.action) · \(s.place) · \(s.light)", at: y, x: x, width: w, size: 10.5)
            }
            if b.shots.indices.contains(i) {
                y = heading(L("Prompt (code)"), at: y - 2, x: x, width: w)
                y = text(b.shots[i], at: y, x: x, width: w, size: 8.5, color: .darkGray)
                if b.negatives.indices.contains(i) { y = text(L("Negative") + ": " + b.negatives[i], at: y, x: x, width: w, size: 7.5, color: .gray) }
            }
            if let c = b.checks[i] {
                y = heading(L("Vision check"), at: y - 2, x: x, width: w)
                _ = text(c, at: y, x: x, width: w, size: 9)
            }
            ctx.endPDFPage()
        }
    }
}
