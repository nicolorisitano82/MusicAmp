import AppKit
import CoreText

/// Resolves the playlist font named in a skin's pledit.txt.
/// Order: installed on the Mac → bundled in the .wsz → local cache → Google Fonts (exact name)
/// → look-alike substitutes (local first, then Google Fonts) → Arial.
/// Downloads are cached in ~/Library/Application Support/MusicAmp/Fonts and registered for this process only.
final class FontResolver: ObservableObject {
    static let shared = FontResolver()

    enum Status: Equatable {
        case installed
        case bundled
        case downloaded(String)      // family fetched from Google Fonts (same name or substitute)
        case substituted(String)     // look-alike already installed on the Mac
        case searching
        case missing
    }

    /// Look-alikes for Windows fonts that neither macOS nor Google Fonts ship. Tried in order.
    static let substitutes: [String: [String]] = [
        "ms sans serif": ["Microsoft Sans Serif", "Pixelify Sans"],
        "ms serif": ["Times New Roman"],
        "small fonts": ["Silkscreen", "Pixelify Sans"],
        "system": ["Pixelify Sans"],
        "terminal": ["VT323"],
        "fixedsys": ["VT323"],
        "lucida console": ["Cousine", "IBM Plex Mono"],
        "lucida sans": ["Lucida Grande", "Source Sans 3"],
        "lucida sans unicode": ["Lucida Grande", "Source Sans 3"],
        "franklin gothic": ["Libre Franklin"],
        "franklin gothic medium": ["Libre Franklin"],
        "franklin gothic book": ["Libre Franklin"],
        "segoe ui": ["Open Sans"],
        "eurostile": ["Michroma"],
        "bank gothic": ["Michroma"],
        "agency fb": ["Saira Condensed"],
        "bitstream vera sans": ["Open Sans"],
        "bitstream vera sans mono": ["Cousine"],
        "century gothic": ["Questrial"],
        "consolas": ["Inconsolata"],
        "gill sans mt": ["Gill Sans", "Lato"],
        "copperplate gothic bold": ["Copperplate"],
        "haettenschweiler": ["Anton"],
        "ocr a extended": ["Share Tech Mono"],
        "garamond": ["EB Garamond"],
        "book antiqua": ["Palatino", "EB Garamond"],
        "palatino linotype": ["Palatino", "EB Garamond"],
        "arial black": ["Archivo Black"],
        "arial rounded mt bold": ["Arial Rounded MT Bold", "Nunito"],
        "tw cen mt": ["Tenor Sans"],
    ]

    @Published private(set) var statuses: [String: Status] = [:]
    var autoDownload = true

    /// requested name (lowercased) -> family name to use. Persisted so resolved fonts work offline.
    private var mapping: [String: String]
    private var inFlight = Set<String>()
    private var bundledFamilies: [String: String] = [:]
    private var fontCache: [String: NSFont] = [:]

    var fontsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private init() {
        mapping = UserDefaults.standard.dictionary(forKey: "fontMapping") as? [String: String] ?? [:]
        registerCachedFonts()
    }

    // MARK: Public

    /// Font to draw with. Returns Arial (or system) while a lookup is pending; `onChange` lets callers redraw.
    func font(_ requested: String, size: CGFloat) -> NSFont {
        let key = Self.normalize(requested)
        let cacheKey = "\(key)|\(size)"
        if let f = fontCache[cacheKey] { return f }
        if let fam = family(for: requested), let f = Self.make(fam, size) {
            fontCache[cacheKey] = f
            return f
        }
        return Self.make("Arial", size) ?? .systemFont(ofSize: size)
    }

    /// Family available right now for `requested`, kicking off an online lookup when needed.
    func family(for requested: String) -> String? {
        let key = Self.normalize(requested)
        guard !key.isEmpty else { return nil }
        // Check our own mapping first: a downloaded font is registered and would otherwise look "installed".
        if let fam = mapping[key], Self.isInstalled(fam) {
            if statuses[key] == nil { setStatus(key, isCached(fam) ? .downloaded(fam) : .substituted(fam)) }
            return fam
        }
        if let fam = bundledFamilies[key] {
            setStatus(key, .bundled)
            return fam
        }
        if Self.isInstalled(requested) {
            setStatus(key, .installed)
            return requested
        }
        // A local look-alike works offline; still try the exact font online first if allowed.
        if !autoDownload, let local = Self.substitutes[key]?.first(where: Self.isInstalled) {
            setStatus(key, .substituted(local))
            return local
        }
        // Already searched without success this session: don't hit the network on every redraw.
        if statuses[key] == .missing || statuses[key] == .searching { return nil }
        if autoDownload { lookup(requested) } else { setStatus(key, .missing) }
        return nil
    }

    func status(for requested: String) -> Status? { statuses[Self.normalize(requested)] }

    /// Forces a new online search (e.g. from the preferences panel).
    func retry(_ requested: String) {
        let key = Self.normalize(requested)
        mapping[key] = nil
        statuses[key] = nil
        fontCache = fontCache.filter { !$0.key.hasPrefix(key + "|") }
        lookup(requested)
    }

    /// Registers fonts shipped inside a skin archive (data already read into memory).
    func registerBundled(_ fonts: [Data]) {
        for data in fonts {
            guard let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) else { continue }
            var err: Unmanaged<CFError>?
            CTFontManagerRegisterGraphicsFont(cg, &err)
            let family = CTFontCopyFamilyName(CTFontCreateWithGraphicsFont(cg, 12, nil, nil)) as String
            bundledFamilies[Self.normalize(family)] = family
            if let ps = cg.postScriptName { bundledFamilies[Self.normalize(ps as String)] = family }
        }
        fontCache = [:]
    }

    func clearCache() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)) ?? [] {
            CTFontManagerUnregisterFontsForURL(f as CFURL, .process, nil)
            try? fm.removeItem(at: f)
        }
        mapping = [:]
        statuses = [:]
        fontCache = [:]
        UserDefaults.standard.removeObject(forKey: "fontMapping")
    }

    var cachedFontCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: fontsDir.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    // MARK: Lookup

    private func lookup(_ requested: String) {
        let key = Self.normalize(requested)
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        setStatus(key, .searching)
        let candidates = [requested] + (Self.substitutes[key] ?? [])
        Task {
            var result: Status = .missing
            var family: String?
            for (i, cand) in candidates.enumerated() {
                if i > 0, Self.isInstalled(cand) {
                    family = cand
                    result = .substituted(cand)
                    break
                }
                if let fam = await self.download(cand) {
                    family = fam
                    result = .downloaded(fam)
                    break
                }
            }
            await MainActor.run { [family, result] in
                self.inFlight.remove(key)
                if let family {
                    self.mapping[key] = family
                    UserDefaults.standard.set(self.mapping, forKey: "fontMapping")
                }
                self.fontCache = self.fontCache.filter { !$0.key.hasPrefix(key + "|") }
                self.setStatus(key, result)
                Ctl.shared.redraw()
            }
        }
    }

    /// Fetches `family` from the Google Fonts CSS API (a non-browser user agent gets TTF URLs),
    /// caches the file and registers it. Returns the family name found inside the file.
    private func download(_ family: String) async -> String? {
        var comps = URLComponents(string: "https://fonts.googleapis.com/css2")!
        comps.queryItems = [URLQueryItem(name: "family", value: family)]
        guard let cssURL = comps.url else { return nil }
        var req = URLRequest(url: cssURL, timeoutInterval: 15)
        req.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let css = String(data: data, encoding: .utf8), css.contains("@font-face"),
              let r = css.range(of: #"url\((https://[^)]+)\)"#, options: .regularExpression)
        else { return nil }
        let urlString = String(css[r].dropFirst(4).dropLast())
        // "/l/font?kit=" serves commercially licensed fonts (e.g. Monotype) for Google's own products,
        // not the open catalog: never download or cache those.
        guard !urlString.contains("/l/font"), let fontURL = URL(string: urlString),
              let (fontData, fontResp) = try? await URLSession.shared.data(from: fontURL),
              (fontResp as? HTTPURLResponse)?.statusCode == 200,
              let descs = CTFontManagerCreateFontDescriptorsFromData(fontData as CFData) as? [CTFontDescriptor],
              let desc = descs.first,
              let realFamily = CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute) as? String
        else { return nil }
        let file = fontsDir.appendingPathComponent(Self.fileName(family))
        do { try fontData.write(to: file, options: .atomic) } catch { return nil }
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        return realFamily
    }

    // MARK: Helpers

    private func registerCachedFonts() {
        for f in (try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)) ?? []
            where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    private func isCached(_ family: String) -> Bool {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(atPath: fontsDir.path))?.contains { $0.lowercased() == Self.fileName(family).lowercased() } ?? false
    }

    private func setStatus(_ key: String, _ s: Status) {
        if statuses[key] != s { statuses[key] = s }
    }

    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).lowercased()
    }

    static func fileName(_ family: String) -> String {
        family.replacingOccurrences(of: "/", with: "-") + ".ttf"
    }

    static func isInstalled(_ family: String) -> Bool {
        let f = normalize(family)
        if NSFontManager.shared.availableFontFamilies.contains(where: { $0.lowercased() == f }) { return true }
        return NSFont(name: family, size: 12) != nil
    }

    static func make(_ family: String, _ size: CGFloat) -> NSFont? {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont(name: family, size: size)
    }
}
