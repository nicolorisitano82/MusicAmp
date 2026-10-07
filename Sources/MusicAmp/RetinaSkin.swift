import AppKit

// Retina skins: a classic .wsz plus optional "@2x" bitmaps in the same archive (main@2x.png, cbuttons@2x.bmp…).
// Each @2x sheet is exactly twice the size of its 1x sheet and uses the same layout, so every sprite
// coordinate stays in 1x units. Winamp ignores the extra files, so the skin keeps working there unchanged.
// See the "Skin Retina — specifiche" doc for the full format.

extension Skin {
    /// Hi-res sheets found in the skin (only the ones that passed validation).
    var isRetina: Bool { !images2x.isEmpty }

    func image2x(_ name: String) -> CGImage? { images2x[name] }

    /// Loads `<sheet>@2x.png|bmp` and `<cursor>@2x.cur`. Sheets with the wrong size are skipped and noted.
    func loadRetina(_ files: [String: URL]) {
        for n in Skin.sheetNames {
            guard let f = ["png", "bmp"].lazy.compactMap({ files["\(n)@2x.\($0)"] }).first,
                  let hi = Skin.loadImage(f) else { continue }
            if let lo = images[n] {
                guard hi.width == lo.width * 2, hi.height == lo.height * 2 else {
                    retinaIssues.append("\(f.lastPathComponent): \(hi.width)×\(hi.height), attesi \(lo.width * 2)×\(lo.height * 2) — ignorato")
                    continue
                }
            } else if let lo = Skin.downsample(hi) {
                // Only the @2x sheet: derive the 1x one (pixel reads and non-retina screens use it).
                images[n] = lo
                retinaIssues.append("\(n): solo @2x, 1x ricavato (Winamp non lo vedrà)")
            }
            images2x[n] = hi
        }
        if images2x["balance"] == nil, images["balance"] == nil, let v = images2x["volume"] { images2x["balance"] = v }
        for c in Skin.cursorNames {
            guard let base = cursors[c], let f = files["\(c)@2x.ani"] ?? files["\(c)@2x.cur"],
                  let hi = SkinCursor.load(f) else { continue }
            guard hi.frames.count == base.frames.count else {
                retinaIssues.append("\(f.lastPathComponent): \(hi.frames.count) fotogrammi, attesi \(base.frames.count) — ignorato")
                continue
            }
            // Each frame gets the @2x image as a second representation at the same point size; 1x timing and hotspot.
            let frames = zip(base.frames, hi.frames).map { lo, hi -> NSCursor in
                let img = lo.image
                let combined = NSImage(size: img.size)
                img.representations.forEach(combined.addRepresentation)
                for rep in hi.image.representations where rep.pixelsWide >= Int(img.size.width) * 2 {
                    rep.size = img.size
                    combined.addRepresentation(rep)
                }
                return NSCursor(image: combined, hotSpot: lo.hotSpot)
            }
            cursors[c] = SkinCursor(frames: frames, delays: base.delays)
        }
    }

    /// Half-size copy keeping exact palette colours (top-left pixel of each 2×2 block).
    static func downsample(_ img: CGImage) -> CGImage? {
        guard let src = RGBA(img) else { return nil }
        var dst = RGBA(width: img.width / 2, height: img.height / 2)
        for y in 0..<dst.height { for x in 0..<dst.width { dst[x, y] = src[x * 2, y * 2] } }
        return dst.image()
    }

    /// Scale2x (EPX): doubles pixel art keeping hard edges but rounding diagonals. Starting point for authors.
    static func scale2x(_ img: CGImage) -> CGImage? {
        guard let s = RGBA(img) else { return nil }
        var d = RGBA(width: s.width * 2, height: s.height * 2)
        for y in 0..<s.height {
            for x in 0..<s.width {
                let p = s[x, y]
                let a = s[x, max(0, y - 1)], b = s[min(s.width - 1, x + 1), y]
                let c = s[max(0, x - 1), y], dn = s[x, min(s.height - 1, y + 1)]
                var e0 = p, e1 = p, e2 = p, e3 = p
                if c == a && c != dn && a != b { e0 = a }
                if a == b && a != c && b != dn { e1 = b }
                if dn == c && dn != b && c != a { e2 = c }
                if b == dn && b != a && dn != c { e3 = dn }
                d[2 * x, 2 * y] = e0; d[2 * x + 1, 2 * y] = e1
                d[2 * x, 2 * y + 1] = e2; d[2 * x + 1, 2 * y + 1] = e3
            }
        }
        return d.image()
    }
}

/// Plain RGBA8 pixel buffer (premultiplied, sRGB), top-left origin.
struct RGBA {
    let width: Int, height: Int
    var px: [UInt32]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        px = Array(repeating: 0, count: width * height)
    }

    init?(_ img: CGImage) {
        self.init(width: img.width, height: img.height)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    subscript(x: Int, y: Int) -> UInt32 {
        get { px[y * width + x] }
        set { px[y * width + x] = newValue }
    }

    func image() -> CGImage? {
        var copy = px
        return copy.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}

// MARK: Command-line tools

enum RetinaTools {
    /// `--retina-check skin.wsz`: which sheets have @2x art, and any problems.
    static func check(_ path: String) -> Int32 {
        guard let s = try? Skin.load(from: URL(fileURLWithPath: path)) else { print("skin non valida"); return 1 }
        print("\(s.name): \(s.isRetina ? "Retina" : "solo 1x") — \(s.images2x.count)/\(Skin.sheetNames.count) bitmap @2x")
        for n in Skin.sheetNames {
            let lo = s.images[n].map { "\($0.width)×\($0.height)" } ?? "—"
            let hi = s.images2x[n].map { "\($0.width)×\($0.height)" } ?? "—"
            print("  \(n.padding(toLength: 9, withPad: " ", startingAt: 0)) 1x \(lo.padding(toLength: 9, withPad: " ", startingAt: 0)) @2x \(hi)")
        }
        let hi = s.cursors.filter { $0.value.frames.first?.image.representations.count ?? 0 > 1 }
        print("  cursori @2x: \(hi.count) (\(hi.values.filter { $0.frames.count > 1 }.count) animati)")
        s.retinaIssues.forEach { print("  ! " + $0) }
        return 0
    }

    /// A .cur/.ico (or every frame of a RIFF ACON .ani) doubled with Scale2x, hotspot doubled, as a PNG-payload CUR.
    static func cursor2x(_ d: Data) -> Data? {
        func u16(_ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
        func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8(v >> 8 & 255)]) }
        func le32(_ v: Int) -> Data { le16(v & 0xFFFF) + le16(v >> 16) }
        if d.count > 12, d.prefix(4) == Data("RIFF".utf8) {
            // Rewrite chunk by chunk: icons doubled, everything else (anih, rate, seq, INFO) copied.
            func rewrite(_ c: Data) -> Data? {
                var out = Data(), o = c.startIndex
                while o + 8 <= c.endIndex {
                    let id = c[o..<(o + 4)]
                    let size = Int(c[o + 4]) | Int(c[o + 5]) << 8 | Int(c[o + 6]) << 16 | Int(c[o + 7]) << 24
                    guard o + 8 + size <= c.endIndex else { return nil }
                    var body = Data(c[(o + 8)..<(o + 8 + size)])
                    if id == Data("icon".utf8) {
                        guard let b = cursor2x(body) else { return nil }
                        body = b
                    } else if id == Data("LIST".utf8), body.count >= 4 {
                        guard let inner = rewrite(Data(body.dropFirst(4))) else { return nil }
                        body = Data(body.prefix(4)) + inner
                    }
                    out += id + le32(body.count) + body + (body.count & 1 == 1 ? Data([0]) : Data())
                    o += 8 + size + (size & 1)
                }
                return out
            }
            guard let inner = rewrite(Data(d.dropFirst(12))) else { return nil }
            let body = Data("ACON".utf8) + inner
            return Data("RIFF".utf8) + le32(body.count) + body
        }
        guard d.count > 22, let img = NSImage(data: d),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil), let hi = Skin.scale2x(cg),
              let png = NSBitmapImageRep(cgImage: hi).representation(using: .png, properties: [:]) else { return nil }
        let isCur = u16(2) == 2
        let hx = isCur ? u16(10) * 2 : 0, hy = isCur ? u16(12) * 2 : 0
        let side = { (v: Int) in UInt8(v >= 256 ? 0 : v) }   // 0 means 256 in ICO headers
        return le16(0) + le16(2) + le16(1) + Data([side(hi.width), side(hi.height), 0, 0]) + le16(hx) + le16(hy)
            + le32(png.count) + le32(22) + png
    }

    /// `--make-retina in.wsz out.wsz`: copies the skin and adds Scale2x @2x sheets as a starting point.
    static func make(_ input: String, _ output: String) -> Int32 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("musicamp-retina-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        func run(_ tool: String, _ args: [String], in dir: URL? = nil) -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard run("/usr/bin/unzip", ["-qq", "-o", input, "-d", tmp.path]) <= 1 else { print("unzip fallito"); return 1 }
        var made = 0
        let en = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)
        while let f = en?.nextObject() as? URL {
            let base = f.deletingPathExtension().lastPathComponent.lowercased()
            guard ["bmp", "png"].contains(f.pathExtension.lowercased()), Skin.sheetNames.contains(base),
                  !fm.fileExists(atPath: f.deletingLastPathComponent().appendingPathComponent("\(base)@2x.png").path),
                  let img = Skin.loadImage(f), let hi = Skin.scale2x(img),
                  let png = NSBitmapImageRep(cgImage: hi).representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: f.deletingLastPathComponent().appendingPathComponent("\(base)@2x.png"))
            made += 1
        }
        var cursorsMade = 0
        let en2 = fm.enumerator(at: tmp, includingPropertiesForKeys: nil)
        while let f = en2?.nextObject() as? URL {
            let base = f.deletingPathExtension().lastPathComponent.lowercased(), ext = f.pathExtension.lowercased()
            let dst = f.deletingLastPathComponent().appendingPathComponent("\(base)@2x.\(ext)")
            guard ["cur", "ani"].contains(ext), Skin.cursorNames.contains(base), !fm.fileExists(atPath: dst.path),
                  let d = try? Data(contentsOf: f), let hi = cursor2x(d) else { continue }
            try? hi.write(to: dst)
            cursorsMade += 1
        }
        if cursorsMade > 0 { print("\(cursorsMade) cursori @2x generati") }
        let out = URL(fileURLWithPath: output).standardizedFileURL
        try? fm.removeItem(at: out)
        guard run("/usr/bin/zip", ["-qrX", out.path, "."], in: tmp) == 0 else { print("zip fallito"); return 1 }
        print("\(made) bitmap @2x generati (Scale2x) → \(out.path)")
        return 0
    }
}
