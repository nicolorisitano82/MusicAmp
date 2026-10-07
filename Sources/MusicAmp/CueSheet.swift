import Foundation

/// Cue sheets: one audio file (or several) split into tracks by a `.cue` index.
/// A cue track is addressed as `file:///…/album.cue#track=3`: a stable URL that the playlist saves and
/// restores; the engine resolves it to the audio file plus a segment (start and end in seconds).
enum CueSheet {
    struct Entry {
        var number: Int
        var title: String?
        var performer: String?
        var file: URL
        var start: Double
        /// nil = until the end of the file.
        var end: Double?
    }

    struct Sheet {
        var title: String?
        var performer: String?
        var date: String?
        var genre: String?
        var entries: [Entry]
    }

    // MARK: URLs

    static func isCueTrack(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "cue" && (url.fragment ?? "").hasPrefix("track=")
    }

    static func trackURL(_ cue: URL, _ n: Int) -> URL {
        var c = URLComponents(url: cue, resolvingAgainstBaseURL: false)!
        c.fragment = "track=\(n)"
        return c.url!
    }

    /// The cue file without the `#track=` fragment.
    static func cueFile(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.fragment = nil
        return c.url ?? url
    }

    static func entry(_ url: URL) -> (Sheet, Entry)? {
        guard isCueTrack(url), let n = Int((url.fragment ?? "").dropFirst(6)), let sheet = parse(cueFile(url)),
              let e = sheet.entries.first(where: { $0.number == n }) else { return nil }
        return (sheet, e)
    }

    /// What to open for playback, artwork and tags: the referenced audio file (or the URL itself).
    static func audioURL(_ url: URL) -> URL { entry(url)?.1.file ?? url }

    /// Start/end (seconds) of a cue track inside its audio file.
    static func segment(_ url: URL) -> (start: Double, end: Double?)? {
        entry(url).map { ($0.1.start, $0.1.end) }
    }

    static func trackURLs(_ cue: URL) -> [URL] {
        (parse(cue)?.entries ?? []).map { trackURL(cue, $0.number) }
    }

    // MARK: Parsing (cached per file and modification date)

    private static var cache: [String: (Date, Sheet)] = [:]
    private static let lock = NSLock()

    static func parse(_ url: URL) -> Sheet? {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock()
        if let c = cache[url.path], c.0 == mod { lock.unlock(); return c.1 }
        lock.unlock()
        guard let data = try? Data(contentsOf: url) else { return nil }
        // UTF-8 (with or without BOM), else Windows-1252: old rippers wrote ANSI cue sheets.
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        guard let sheet = parse(text: text, folder: url.deletingLastPathComponent()) else { return nil }
        lock.lock(); cache[url.path] = (mod, sheet); lock.unlock()
        return sheet
    }

    static func parse(text: String, folder: URL) -> Sheet? {
        var sheet = Sheet(entries: [])
        var file: URL?
        var current: Entry?
        func flush() { if let c = current { sheet.entries.append(c) }; current = nil }
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (cmd, rest) = split(line)
            switch cmd {
            case "FILE":
                flush()
                file = resolve(quoted(rest).0, in: folder)
            case "TRACK":
                flush()
                guard let f = file, let n = Int(rest.split(separator: " ").first ?? "") else { continue }
                current = Entry(number: n, file: f, start: -1)
            case "TITLE":
                if current != nil { current?.title = quoted(rest).0 } else { sheet.title = quoted(rest).0 }
            case "PERFORMER":
                if current != nil { current?.performer = quoted(rest).0 } else { sheet.performer = quoted(rest).0 }
            case "INDEX":
                let parts = rest.split(separator: " ")
                guard parts.count == 2, let idx = Int(parts[0]), let t = time(String(parts[1])) else { continue }
                // INDEX 01 is where the track starts; INDEX 00 (pregap) only when there is no 01.
                if idx == 1 || (idx == 0 && (current?.start ?? 0) < 0) { current?.start = t }
            case "REM":
                let (k, v) = split(rest)
                if k == "DATE" { sheet.date = quoted(v).0 }
                if k == "GENRE" { sheet.genre = quoted(v).0 }
            default: break
            }
        }
        flush()
        sheet.entries.removeAll { $0.start < 0 }
        guard !sheet.entries.isEmpty else { return nil }
        // A track ends where the next one starts in the same file.
        for i in sheet.entries.indices {
            if i + 1 < sheet.entries.count, sheet.entries[i + 1].file == sheet.entries[i].file {
                sheet.entries[i].end = sheet.entries[i + 1].start
            }
        }
        return sheet
    }

    /// "mm:ss:ff" (75 frames per second) → seconds.
    static func time(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Double(p[0]) * 60 + Double(p[1]) + Double(p[2]) / 75
    }

    private static func split(_ line: String) -> (String, String) {
        guard let sp = line.firstIndex(of: " ") else { return (line.uppercased(), "") }
        return (line[..<sp].uppercased(), line[line.index(after: sp)...].trimmingCharacters(in: .whitespaces))
    }

    /// `"Name with spaces" WAVE` → ("Name with spaces", "WAVE"); unquoted values are taken whole.
    private static func quoted(_ s: String) -> (String, String) {
        if s.hasPrefix("\""), let end = s.dropFirst().firstIndex(of: "\"") {
            return (String(s[s.index(after: s.startIndex)..<end]), s[s.index(after: end)...].trimmingCharacters(in: .whitespaces))
        }
        // Unquoted FILE names may still end with the type (e.g. `album.flac WAVE`).
        let parts = s.split(separator: " ")
        if parts.count >= 2, ["WAVE", "MP3", "AIFF", "BINARY", "MOTOROLA", "FLAC"].contains(parts.last!.uppercased()) {
            return (parts.dropLast().joined(separator: " "), String(parts.last!))
        }
        return (s, "")
    }

    /// The audio file a cue names; if it was converted since (cue says .wav, folder has .flac), the same
    /// name with another audio extension; failing that, the only audio file in the folder.
    static func resolve(_ name: String, in folder: URL) -> URL {
        let direct = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let base = (name as NSString).deletingPathExtension.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let audio = files.filter { Playlist.audioExtensions.contains($0.pathExtension.lowercased()) }
        if let same = audio.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == base }) { return same }
        if audio.count == 1 { return audio[0] }
        return direct
    }
}
