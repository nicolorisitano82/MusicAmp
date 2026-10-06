import AppKit

@inline(__always) func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

struct PlaylistStyle {
    var normal = rgb(0, 255, 0)
    var current = rgb(255, 255, 255)
    var normalBG = rgb(0, 0, 0)
    var selectedBG = rgb(0, 0, 198)
    var font = "Arial"
}

enum SkinError: LocalizedError {
    case notFound, unzip, invalid
    var errorDescription: String? {
        switch self {
        case .notFound: return "File non trovato."
        case .unzip: return "Impossibile estrarre l'archivio."
        case .invalid: return "Non sembra una skin Winamp classic (manca main.bmp)."
        }
    }
}

/// A classic Winamp 2.x skin: bitmaps plus viscolor/pledit/region config.
/// Missing bitmaps fall back to the built-in default skin, as Winamp falls back to its base skin.
final class Skin {
    let name: String
    var images: [String: CGImage] = [:]
    var visColors: [CGColor] = Skin.defaultVisColors
    var playlist = PlaylistStyle()
    var regions: [String: [[CGPoint]]] = [:]
    var cursors: [String: SkinCursor] = [:]

    init(name: String) { self.name = name }

    static let sheetNames = ["main", "titlebar", "cbuttons", "numbers", "nums_ex", "text", "posbar",
                             "volume", "balance", "shufrep", "playpaus", "monoster", "eqmain", "eq_ex", "pledit",
                             "gen", "genex"]
    static let cursorNames = ["normal", "close", "min", "mainmenu", "titlebar", "posbar", "volbal", "volbar",
                              "songname", "winbut", "wsnormal", "wsclose", "wsmin", "wsposbar", "wswinbut",
                              "eqnormal", "eqclose", "eqslid", "eqtitle", "pnormal", "pclose", "psize",
                              "ptbar", "pvscroll", "pwinbut", "pwsnorm", "pwssize", "mmenu"]

    static let fallback: Skin = DefaultSkin.make()

    func image(_ name: String) -> CGImage? {
        if let i = images[name] { return i }
        return self === Skin.fallback ? nil : Skin.fallback.images[name]
    }

    var hasNumsEx: Bool { images["nums_ex"] != nil }

    lazy var eqLineColors: [CGColor] = {
        guard let img = image("eqmain"), img.height >= 313 else { return Array(repeating: rgb(0, 255, 0), count: 19) }
        let px = Skin.pixels(img, R(115, 294, 1, 19))
        return px.count == 19 ? px : Array(repeating: rgb(0, 255, 0), count: 19)
    }()

    // MARK: Loading

    static func load(from url: URL) throws -> Skin {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw SkinError.notFound }
        var root = url
        var tmp: URL?
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        if !isDir.boolValue {
            let t = fm.temporaryDirectory.appendingPathComponent("musicamp-skin-\(UUID().uuidString)")
            try fm.createDirectory(at: t, withIntermediateDirectories: true)
            tmp = t
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            p.arguments = ["-qq", "-o", url.path, "-d", t.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            // unzip exits 1 for warnings (odd paths/encodings) but still extracts.
            guard p.terminationStatus <= 1 else { throw SkinError.unzip }
            root = t
        }

        // Index files case-insensitively, preferring the shallowest match.
        var files: [String: URL] = [:]
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let f as URL in en where !f.path.contains("__MACOSX") {
                let key = f.lastPathComponent.lowercased()
                if let old = files[key], old.pathComponents.count <= f.pathComponents.count { continue }
                files[key] = f
            }
        }

        let skin = Skin(name: url.deletingPathExtension().lastPathComponent)
        for n in sheetNames {
            for ext in ["bmp", "png"] {
                if let f = files["\(n).\(ext)"], let img = loadImage(f) {
                    skin.images[n] = img
                    break
                }
            }
        }
        guard skin.images["main"] != nil else { throw SkinError.invalid }
        // Winamp uses volume.bmp when balance.bmp is missing.
        if skin.images["balance"] == nil, let v = skin.images["volume"] { skin.images["balance"] = v }
        if let f = files["viscolor.txt"], let s = readText(f) { skin.parseVisColors(s) }
        if let f = files["pledit.txt"], let s = readText(f) { skin.parsePledit(s) }
        if let f = files["region.txt"], let s = readText(f) { skin.parseRegions(s) }
        for c in cursorNames {
            if let f = files["\(c).ani"] ?? files["\(c).cur"], let cur = SkinCursor.load(f) { skin.cursors[c] = cur }
        }
        // Some skins ship the playlist font next to the bitmaps.
        let fonts = files.filter { ["ttf", "otf"].contains(($0.key as NSString).pathExtension) }.values.compactMap { try? Data(contentsOf: $0) }
        if !fonts.isEmpty { FontResolver.shared.registerBundled(fonts) }
        return skin
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        // Normalize to 32-bit RGBA so cropping/drawing behaves the same for 8/24-bit BMPs.
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }

    static func readText(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(data: d, encoding: .isoLatin1)
    }

    static func lines(_ s: String) -> [String] {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    }

    func parseVisColors(_ s: String) {
        var colors: [CGColor] = []
        for line in Skin.lines(s) {
            let content = line.components(separatedBy: "//")[0]
            let nums = content.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count >= 3 { colors.append(rgb(min(255, nums[0]), min(255, nums[1]), min(255, nums[2]))) }
            if colors.count == 24 { break }
        }
        for (i, c) in colors.enumerated() { visColors[i] = c }
    }

    func parsePledit(_ s: String) {
        for line in Skin.lines(s) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "normal": if let c = Skin.hexColor(val) { playlist.normal = c }
            case "current": if let c = Skin.hexColor(val) { playlist.current = c }
            case "normalbg": if let c = Skin.hexColor(val) { playlist.normalBG = c }
            case "selectedbg": if let c = Skin.hexColor(val) { playlist.selectedBG = c }
            case "font": if !val.isEmpty { playlist.font = val }
            default: break
            }
        }
    }

    static func hexColor(_ s: String) -> CGColor? {
        let h = s.trimmingCharacters(in: CharacterSet(charactersIn: "# \t")).prefix(6)
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return rgb((v >> 16) & 255, (v >> 8) & 255, v & 255)
    }

    func parseRegions(_ s: String) {
        var section = ""
        var counts: [String: [Int]] = [:]
        var points: [String: [Int]] = [:]
        for raw in Skin.lines(s) {
            let line = raw.components(separatedBy: ";")[0].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("[") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let vals = line[line.index(after: eq)...].split(whereSeparator: { !($0.isNumber || $0 == "-") }).compactMap { Int($0) }
            if key == "numpoints" { counts[section] = vals } else if key == "pointlist" { points[section] = vals }
        }
        for (sec, cs) in counts {
            guard let pts = points[sec] else { continue }
            var idx = 0
            var polys: [[CGPoint]] = []
            for c in cs where c > 0 {
                guard idx + c * 2 <= pts.count else { break }
                polys.append((0..<c).map { CGPoint(x: pts[idx + 2 * $0], y: pts[idx + 2 * $0 + 1]) })
                idx += c * 2
            }
            if !polys.isEmpty { regions[sec] = polys }
        }
    }

    // MARK: Pixel helpers

    static func pixels(_ img: CGImage, _ r: CGRect) -> [CGColor] {
        guard let sub = img.cropping(to: r) else { return [] }
        let w = sub.width, h = sub.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        return (0..<(w * h)).map { rgb(Int(data[$0 * 4]), Int(data[$0 * 4 + 1]), Int(data[$0 * 4 + 2])) }
    }

    // MARK: TEXT.BMP font map (5x6 cells)

    static let fontMap: [Character: (Int, Int)] = {
        var m: [Character: (Int, Int)] = [:]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz\"@".enumerated() { m[c] = (i, 0) }
        m[" "] = (30, 0)
        for (i, c) in "0123456789….:()-'!_+\\/[]^&%,=$#".enumerated() { m[c] = (i, 1) }
        for (i, c) in "ÅÖÄ?*".enumerated() { m[c] = (i, 2) }
        m["<"] = (13, 1); m[">"] = (14, 1); m["{"] = (22, 1); m["}"] = (23, 1)
        m["`"] = (16, 1); m["|"] = (21, 1); m[";"] = (12, 1); m["~"] = (15, 1)
        return m
    }()

    static func charPos(_ c: Character) -> (Int, Int) {
        if let p = fontMap[c] { return p }
        if let l = c.lowercased().first, let p = fontMap[l] { return p }
        if let u = c.uppercased().first, let p = fontMap[u] { return p }
        if let f = String(c).folding(options: .diacriticInsensitive, locale: nil).lowercased().first, let p = fontMap[f] { return p }
        return (30, 0)
    }

    static let defaultVisColors: [CGColor] = [
        rgb(0, 0, 0), rgb(24, 33, 41),
        rgb(239, 49, 16), rgb(206, 41, 16), rgb(214, 90, 0), rgb(214, 102, 0), rgb(214, 115, 0), rgb(198, 123, 8),
        rgb(222, 165, 24), rgb(214, 181, 33), rgb(189, 222, 41), rgb(148, 222, 33), rgb(41, 206, 16), rgb(50, 190, 16),
        rgb(57, 181, 16), rgb(49, 156, 8), rgb(41, 148, 0), rgb(24, 132, 8),
        rgb(255, 255, 255), rgb(214, 214, 222), rgb(181, 189, 189), rgb(160, 170, 175), rgb(148, 156, 165),
        rgb(150, 150, 150),
    ]
}
