import Foundation

/// Parametric EQ (after the Winamp-style graphic EQ) with headphone correction profiles from AutoEq
/// (https://github.com/jaakkopasanen/AutoEq, MIT). Profiles use the Equalizer APO text format:
///   Preamp: -6.3 dB
///   Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
struct PEQFilter: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case peak = "PK", lowShelf = "LSC", highShelf = "HSC", lowPass = "LP", highPass = "HP"
        var label: String {
            switch self {
            case .peak: return "Peak"
            case .lowShelf: return "Low Shelf"
            case .highShelf: return "High Shelf"
            case .lowPass: return "Low Pass"
            case .highPass: return "High Pass"
            }
        }
    }
    var id = UUID()
    var enabled = true
    var kind: Kind = .peak
    var frequency: Double = 1000
    var gain: Double = 0
    var q: Double = 0.707

    enum CodingKeys: String, CodingKey { case enabled, kind, frequency, gain, q }
}

struct PEQProfile: Codable, Equatable {
    var name = "Custom"
    var preamp: Double = 0
    var filters: [PEQFilter] = []

    /// At most this many bands run in the engine (AutoEq profiles use 10).
    static let maxBands = 16

    // MARK: Equalizer APO text

    static func parse(_ text: String, name: String) -> PEQProfile? {
        var p = PEQProfile(name: name)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("preamp:") {
                p.preamp = number(after: "Preamp:", in: line) ?? 0
                continue
            }
            guard line.lowercased().hasPrefix("filter"), let colon = line.firstIndex(of: ":") else { continue }
            let words = line[line.index(after: colon)...].split(separator: " ").map(String.init)
            guard words.count >= 2 else { continue }
            var f = PEQFilter()
            f.enabled = words[0].uppercased() == "ON"
            switch words[1].uppercased() {
            case "PK", "PEQ", "MODAL": f.kind = .peak
            case "LS", "LSC", "LSQ", "LS 6DB", "LS 12DB": f.kind = .lowShelf
            case "HS", "HSC", "HSQ", "HS 6DB", "HS 12DB": f.kind = .highShelf
            case "LP", "LPQ": f.kind = .lowPass
            case "HP", "HPQ": f.kind = .highPass
            default: continue
            }
            func value(_ key: String) -> Double? {
                guard let i = words.firstIndex(where: { $0.caseInsensitiveCompare(key) == .orderedSame }), i + 1 < words.count else { return nil }
                return Double(words[i + 1].replacingOccurrences(of: ",", with: "."))
            }
            f.frequency = value("Fc") ?? 1000
            f.gain = value("Gain") ?? 0
            f.q = value("Q") ?? (f.kind == .peak ? 1 : 0.707)
            p.filters.append(f)
        }
        return p.filters.isEmpty && p.preamp == 0 ? nil : p
    }

    private static func number(after key: String, in line: String) -> Double? {
        guard let r = line.range(of: key, options: .caseInsensitive) else { return nil }
        let rest = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(rest.split(separator: " ").first?.replacingOccurrences(of: ",", with: ".") ?? "")
    }

    var text: String {
        var out = String(format: "Preamp: %.1f dB\n", preamp)
        for (i, f) in filters.enumerated() {
            out += String(format: "Filter %d: %@ %@ Fc %.0f Hz Gain %.1f dB Q %.2f\n", i + 1, f.enabled ? "ON" : "OFF", f.kind.rawValue, f.frequency, f.gain, f.q)
        }
        return out
    }

    /// Preamp that keeps the loudest boost from clipping.
    var safePreamp: Double {
        let peak = stride(from: 20.0, through: 20000, by: 10).map { response(at: $0) - preamp }.max() ?? 0
        return -max(0, peak)
    }

    // MARK: Frequency response (RBJ biquads), for the graph

    /// Total gain in dB at `f` Hz, including the preamp.
    func response(at f: Double, sampleRate: Double = 48000) -> Double {
        filters.filter(\.enabled).reduce(preamp) { $0 + PEQProfile.magnitude($1, f, sampleRate) }
    }

    static func magnitude(_ flt: PEQFilter, _ f: Double, _ fs: Double) -> Double {
        let A = pow(10, flt.gain / 40), w0 = 2 * .pi * flt.frequency / fs
        let alpha = sin(w0) / (2 * max(0.01, flt.q)), c = cos(w0)
        var b0, b1, b2, a0, a1, a2: Double
        switch flt.kind {
        case .peak:
            b0 = 1 + alpha * A; b1 = -2 * c; b2 = 1 - alpha * A
            a0 = 1 + alpha / A; a1 = -2 * c; a2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * c + s); b1 = 2 * A * ((A - 1) - (A + 1) * c); b2 = A * ((A + 1) - (A - 1) * c - s)
            a0 = (A + 1) + (A - 1) * c + s; a1 = -2 * ((A - 1) + (A + 1) * c); a2 = (A + 1) + (A - 1) * c - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * c + s); b1 = -2 * A * ((A - 1) + (A + 1) * c); b2 = A * ((A + 1) + (A - 1) * c - s)
            a0 = (A + 1) - (A - 1) * c + s; a1 = 2 * ((A - 1) - (A + 1) * c); a2 = (A + 1) - (A - 1) * c - s
        case .lowPass:
            b0 = (1 - c) / 2; b1 = 1 - c; b2 = (1 - c) / 2; a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        case .highPass:
            b0 = (1 + c) / 2; b1 = -(1 + c); b2 = (1 + c) / 2; a0 = 1 + alpha; a1 = -2 * c; a2 = 1 - alpha
        }
        let w = 2 * .pi * f / fs
        // |H(e^jw)|² for a biquad.
        func mag2(_ x0: Double, _ x1: Double, _ x2: Double) -> Double {
            let re = x0 + x1 * cos(w) + x2 * cos(2 * w), im = -(x1 * sin(w) + x2 * sin(2 * w))
            return re * re + im * im
        }
        return 10 * log10(max(1e-12, mag2(b0, b1, b2) / mag2(a0, a1, a2)))
    }

    /// AVAudioUnitEQ wants a peak's width in octaves: BW = 2·asinh(1 / 2Q) / ln 2.
    static func octaves(q: Double) -> Float { Float(2 * asinh(1 / (2 * max(0.05, q))) / log(2)) }
}

// MARK: - AutoEq catalogue

/// The AutoEq index (~9,000 headphones and earphones) and their parametric profiles, cached on disk.
final class AutoEqCatalog: ObservableObject {
    static let shared = AutoEqCatalog()

    struct Entry: Identifiable, Hashable {
        var id: String { path }
        let name: String
        let path: String      // relative, URL-encoded, e.g. "oratory1990/over-ear/Sennheiser%20HD%20600"
        let source: String    // measurement source, e.g. "oratory1990" or "crinacle on GRAS 43AG-7"
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicAmp/AutoEq", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Loads the cached index, downloading it when missing or older than a week.
    @MainActor
    func load() async {
        guard entries.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        let cache = AutoEqCatalog.folder.appendingPathComponent("INDEX.md")
        let age = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { -$0.timeIntervalSinceNow } ?? .infinity
        var text = try? String(contentsOf: cache, encoding: .utf8)
        if text == nil || age > 7 * 86400 {
            do {
                var req = URLRequest(url: URL(string: AutoEqCatalog.base + "INDEX.md")!)
                req.setValue("MusicAmp/0.2", forHTTPHeaderField: "User-Agent")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200, let t = String(data: data, encoding: .utf8) else { throw URLError(.badServerResponse) }
                try? data.write(to: cache)
                text = t
            } catch {
                if text == nil { self.error = "Can't download the AutoEq list: \(error.localizedDescription)" }
            }
        }
        entries = AutoEqCatalog.parseIndex(text ?? "")
    }

    /// "- [Name](./source/rig/Name%20Encoded) by source on rig"
    static func parseIndex(_ text: String) -> [Entry] {
        var out: [Entry] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("- [") {
            guard let nameEnd = line.range(of: "](./"), let pathEnd = line.range(of: ")", range: nameEnd.upperBound..<line.endIndex) else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<nameEnd.lowerBound])
            let path = String(line[nameEnd.upperBound..<pathEnd.lowerBound])
            var source = String(line[pathEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
            if source.hasPrefix("by ") { source.removeFirst(3) }
            out.append(Entry(name: name, path: path, source: source))
        }
        return out
    }

    func search(_ q: String, limit: Int = 200) -> [Entry] {
        let words = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(separator: " ")
        guard !words.isEmpty else { return Array(entries.prefix(limit)) }
        var out: [Entry] = []
        for e in entries {
            let hay = e.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if words.allSatisfy({ hay.contains($0) }) { out.append(e); if out.count == limit { break } }
        }
        return out
    }

    /// Downloads (or reads from cache) the parametric profile of a headphone.
    func profile(_ e: Entry) async throws -> PEQProfile {
        let file = e.name + " ParametricEQ.txt"
        let cache = AutoEqCatalog.folder.appendingPathComponent(e.path.removingPercentEncoding?.replacingOccurrences(of: "/", with: "_") ?? e.name)
            .appendingPathExtension("txt")
        if let t = try? String(contentsOf: cache, encoding: .utf8), let p = PEQProfile.parse(t, name: e.name) { return p }
        let enc = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? file
        guard let url = URL(string: AutoEqCatalog.base + e.path + "/" + enc) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("MusicAmp/0.2", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let t = String(data: data, encoding: .utf8),
              let p = PEQProfile.parse(t, name: e.name) else { throw URLError(.cannotParseResponse) }
        try? data.write(to: cache)
        return p
    }
}
