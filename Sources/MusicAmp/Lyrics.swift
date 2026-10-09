import AVFoundation
import Foundation
import Speech

/// Song lyrics: plain text and, when available, time-synced lines (LRC).
struct Lyrics: Codable, Equatable {
    struct Line: Codable, Equatable {
        var time: Double
        var text: String
        /// Word timings from enhanced LRC ("<mm:ss.xx>word"), when the source has them.
        var words: [Word]?
    }

    struct Word: Codable, Equatable {
        var time: Double
        var text: String
    }

    /// A word with its sung interval, for karaoke highlighting.
    struct TimedWord: Equatable {
        var start: Double
        var end: Double
        var text: String
        /// Sung much longer than the other words of the line (a held note): the karaoke emphasises it.
        var held = false
        var duration: Double { end - start }
        /// 0 before, 1 after, in between while sung.
        func progress(_ t: Double) -> Double { end <= start ? (t >= start ? 1 : 0) : max(0, min(1, (t - start) / (end - start))) }
    }

    /// Words of line `i` with start/end times: real ones from enhanced LRC, otherwise estimated by
    /// spreading the line over its words in proportion to their length, at a realistic singing pace.
    func timedWords(_ i: Int) -> [TimedWord] {
        guard let s = synced, s.indices.contains(i) else { return [] }
        let line = s[i]
        let next = i + 1 < s.count ? s[i + 1].time : line.time + 6
        if let w = line.words, !w.isEmpty {
            return Lyrics.markHeld(w.enumerated().map { k, word in
                TimedWord(start: word.time, end: k + 1 < w.count ? w[k + 1].time : max(word.time + 0.3, min(next - 0.15, word.time + 4)),
                          text: word.text)
            })
        }
        let tokens = line.text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        let chars = tokens.reduce(0) { $0 + max(1, $1.count) }
        // ~13 characters per second plus a little breath, never past the next line.
        let span = max(0.4, min(next - line.time - 0.1, Double(chars) / 13 + 0.5))
        var t = line.time
        var words = tokens.map { tok -> TimedWord in
            let d = span * Double(max(1, tok.count)) / Double(chars)
            defer { t += d }
            return TimedWord(start: t, end: t + d, text: tok)
        }
        // Much more time than the words need: the phrase usually ends on a held note.
        let spare = next - 0.2 - t
        if spare > 0.8, words.count > 1, let last = words.last {
            words[words.count - 1].end = min(last.end + spare, last.end + 3)
        }
        return Lyrics.markHeld(words)
    }

    /// Flags words sung for at least 0.8 s and over twice the line's median word length.
    static func markHeld(_ words: [TimedWord]) -> [TimedWord] {
        guard words.count > 1 else { return words }
        let sorted = words.map(\.duration).sorted()
        let median = sorted[sorted.count / 2]
        return words.map { w in
            var x = w
            x.held = w.duration >= max(0.8, median * 2.2)
            return x
        }
    }

    /// Seconds until line `i + 1` starts; a long one is an instrumental break.
    func gap(after i: Int) -> Double {
        guard let s = synced, s.indices.contains(i), i + 1 < s.count else { return 0 }
        return s[i + 1].time - s[i].time
    }
    var plain: String?
    var synced: [Line]?
    var instrumental = false
    var source: String   // "LRCLIB", ".lrc file", "file tags"
    var link: String?

    var isEmpty: Bool { (plain ?? "").isEmpty && (synced ?? []).isEmpty && !instrumental }

    /// Index of the line being sung at `t` seconds.
    func lineIndex(at t: Double) -> Int? {
        guard let s = synced, !s.isEmpty else { return nil }
        var lo = 0, hi = s.count - 1, best: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if s[mid].time <= t { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

enum LRC {
    /// "[mm:ss.xx]text", several timestamps per line allowed, "[offset:±ms]" honoured, other tags ignored.
    static func parse(_ text: String) -> [Lyrics.Line]? {
        var lines: [Lyrics.Line] = []
        var offset = 0.0
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for raw in Skin.lines(text) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.lowercased().hasPrefix("[offset:"), let v = Double(l.dropFirst(8).dropLast().trimmingCharacters(in: .whitespaces)) {
                offset = v / 1000
                continue
            }
            let ns = l as NSString
            let matches = stamp.matches(in: l, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            var body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            let words = enhancedWords(body, offset: offset)
            if words != nil {
                body = body.replacingOccurrences(of: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            }
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: 3))
                    frac = (Double(f) ?? 0) / pow(10, Double(f.count))
                }
                lines.append(Lyrics.Line(time: max(0, mm * 60 + ss + frac - offset), text: body, words: words))
            }
        }
        lines.sort { $0.time < $1.time }
        return lines.isEmpty ? nil : lines
    }

    /// Enhanced (A2) LRC: "<00:12.30>word <00:12.80>next" inside a line.
    static func enhancedWords(_ body: String, offset: Double) -> [Lyrics.Word]? {
        let re = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>([^<]*)"#)
        let ns = body as NSString
        let ms = re.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return nil }
        var out: [Lyrics.Word] = []
        for m in ms {
            let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var frac = 0.0
            if m.range(at: 3).location != NSNotFound {
                let f = ns.substring(with: m.range(at: 3))
                frac = (Double(f) ?? 0) / pow(10, Double(f.count))
            }
            let text = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for piece in text.split(separator: " ") {
                out.append(Lyrics.Word(time: max(0, mm * 60 + ss + frac - offset), text: String(piece)))
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Finds lyrics for the current track: sidecar .lrc, embedded tags, then LRCLIB (free, open database).
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    enum State: Equatable {
        case idle, loading, found(Lyrics), notFound, error(String)
    }

    struct Query: Equatable {
        var artist: String
        var title: String
        var album: String?
        var duration: Double?
        var file: URL?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var query: Query?
    /// 0…1 while lyrics are being synced from the audio (transcription on this Mac).
    @Published private(set) var syncing: Double?
    @Published private(set) var syncError: String?
    /// Sync plain lyrics from the audio by themselves when the lyrics panel or karaoke shows them.
    @Published var autoSync = UserDefaults.standard.object(forKey: "lyrics.autoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "lyrics.autoSync") }
    }
    private var request = 0
    private var autoTried = Set<String>()

    static let userAgent = "MusicAmp/0.5 (https://github.com/nicolorisitano82/MusicAmp)"

    var cacheDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private struct Cached: Codable {
        var lyrics: Lyrics?
        var date: Date
    }

    /// Artist and title for a playlist track (tags, "Artist - Title" names, or a radio's live title).
    static func query(for t: Track, duration: Double) -> Query? {
        if t.isStream {
            guard let live = t.streamTitle else { return nil }
            let parts = live.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            return Query(artist: parts[0], title: parts.dropFirst().joined(separator: " - "), album: nil, duration: nil, file: nil)
        }
        if t.isEpisode { return nil }
        var artist = t.artist, title = t.songTitle
        if artist == nil || title == nil {
            let parts = t.title.components(separatedBy: " - ")
            if parts.count >= 2 { artist = artist ?? parts[0]; title = title ?? parts.dropFirst().joined(separator: " - ") }
        }
        guard let a = artist, let s = title, !a.isEmpty, !s.isEmpty else { return nil }
        return Query(artist: a, title: s, album: t.album, duration: duration > 0 ? duration : t.duration,
                     file: t.url.isFileURL ? t.url : nil)
    }

    func load(_ q: Query?, force: Bool = false) {
        guard let q else { query = nil; state = .idle; return }
        if !force, q == query, state != .idle { return }
        query = q
        request += 1
        let r = request
        state = .loading
        Task {
            let result = await Self.find(q, cacheDir: cacheDir, force: force)
            await MainActor.run {
                guard r == self.request else { return }
                switch result {
                case .success(let l?): self.state = .found(l)
                case .success(nil): self.state = .notFound
                case .failure(let e): self.state = .error(e.localizedDescription)
                }
            }
        }
    }

    /// The lyrics being shown, if any.
    var lyrics: Lyrics? { if case .found(let l) = state { return l } else { return nil } }

    // MARK: Synced from the audio

    /// Can the current lyrics be timed from the audio? A local, non-cue file, lyrics without times (or none).
    var canSync: Bool {
        guard syncing == nil, let f = query?.file, f.isFileURL, !CueSheet.isCueTrack(f), SpeechTranscriber.isAvailable else { return false }
        switch state {
        case .notFound: return true
        case .found(let l): return l.synced == nil && !l.instrumental
        default: return false
        }
    }

    /// Called by the views showing lyrics: syncs plain lyrics automatically once per track.
    func autoSyncIfUseful() {
        guard autoSync, canSync, case .found = state, let q = query else { return }
        let key = Self.cacheKey(q)
        guard autoTried.insert(key).inserted else { return }
        syncFromAudio()
    }

    /// Transcribes the track on this Mac and times its plain lyrics (or, with none, uses what was heard as the
    /// lyrics), then caches the result like downloaded lyrics so the panel and karaoke use it from now on.
    func syncFromAudio() {
        guard canSync, let q = query, let file = q.file else { return }
        let plain: String? = { if case .found(let l) = state { return l.plain } else { return nil } }()
        let r = request
        syncing = 0
        syncError = nil
        Task {
            do {
                let locale = plain.flatMap(AI.language) ?? AI.language(of: q.title) ?? Locale.current
                let words = try await AI.transcribe(file, locale: locale) { p in Task { @MainActor in if r == self.request { self.syncing = p } } }
                let lines = plain.map { AI.align(lyrics: $0, to: words) } ?? AI.lines(from: words)
                guard !lines.isEmpty else { throw TranscriptionEmpty() }
                let lyrics = Lyrics(plain: plain ?? lines.map(\.text).joined(separator: "\n"), synced: lines,
                                    source: plain == nil ? "Heard on this Mac" : "Synced on this Mac")
                let cacheFile = cacheDir.appendingPathComponent(Self.cacheKey(q) + ".json")
                if let d = try? JSONEncoder().encode(Cached(lyrics: lyrics, date: Date())) { try? d.write(to: cacheFile, options: .atomic) }
                await MainActor.run {
                    self.syncing = nil
                    if r == self.request { self.state = .found(lyrics) }
                }
            } catch {
                await MainActor.run {
                    self.syncing = nil
                    self.syncError = error.localizedDescription
                }
            }
        }
    }

    struct TranscriptionEmpty: LocalizedError { var errorDescription: String? { "No singing could be recognised in this track." } }

    // MARK: Sources

    static func find(_ q: Query, cacheDir: URL, force: Bool) async -> Result<Lyrics?, Error> {
        if let f = q.file {
            if let l = sidecar(f) { return .success(l) }
            if let l = await embedded(f) { return .success(l) }
        }
        let key = cacheKey(q)
        let cacheFile = cacheDir.appendingPathComponent(key + ".json")
        if !force, let d = try? Data(contentsOf: cacheFile), let c = try? JSONDecoder().decode(Cached.self, from: d) {
            // A miss is retried after a week: the community database grows.
            if c.lyrics != nil || Date().timeIntervalSince(c.date) < 7 * 86400 { return .success(c.lyrics) }
        }
        do {
            let l = try await lrclib(q)
            if let d = try? JSONEncoder().encode(Cached(lyrics: l, date: Date())) { try? d.write(to: cacheFile, options: .atomic) }
            return .success(l)
        } catch {
            return .failure(error)
        }
    }

    static func cacheKey(_ q: Query) -> String {
        let s = "\(q.artist.lowercased())|\(q.title.lowercased())|\(Int((q.duration ?? 0).rounded()))"
        return String(s.unicodeScalars.reduce(UInt64(5381)) { ($0 << 5) &+ $0 &+ UInt64($1.value) }, radix: 16)
    }

    /// "Song.lrc" (or .txt) next to "Song.mp3".
    static func sidecar(_ f: URL) -> Lyrics? {
        for ext in ["lrc", "LRC", "txt"] {
            let u = f.deletingPathExtension().appendingPathExtension(ext)
            guard let text = Skin.readText(u), !text.isEmpty else { continue }
            if let s = LRC.parse(text) { return Lyrics(plain: s.map(\.text).joined(separator: "\n"), synced: s, source: ".\(ext.lowercased()) file") }
            if ext == "txt" { return Lyrics(plain: text, synced: nil, source: ".txt file") }
        }
        return nil
    }

    /// Lyrics stored in the file's tags (ID3 USLT/SYLT, iTunes ©lyr, Vorbis LYRICS).
    static func embedded(_ f: URL) async -> Lyrics? {
        let asset = AVURLAsset(url: f)
        var items = (try? await asset.load(.metadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for fmt in formats { items += (try? await asset.loadMetadata(for: fmt)) ?? [] }
        }
        for item in items {
            let id = (item.identifier?.rawValue ?? "").lowercased()
            guard id.contains("lyr") || id.hasSuffix("/uslt") || id.hasSuffix("/sylt") || id.contains("unsyncedlyrics") else { continue }
            guard let text = try? await item.load(.stringValue), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let s = LRC.parse(text) { return Lyrics(plain: s.map(\.text).joined(separator: "\n"), synced: s, source: "file tags") }
            return Lyrics(plain: text, synced: nil, source: "file tags")
        }
        return nil
    }

    // MARK: LRCLIB (https://lrclib.net) — free, no key; asks for an identifying User-Agent.

    private struct Record: Decodable {
        let id: Int
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Search, then pick the version whose length is closest (synced preferred, small penalty otherwise).
    static func lrclib(_ q: Query) async throws -> Lyrics? {
        func search(_ items: [URLQueryItem]) async throws -> [Record] {
            var c = URLComponents(string: "https://lrclib.net/api/search")!
            c.queryItems = items
            var req = URLRequest(url: c.url!, timeoutInterval: 12)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode == 404 { return [] }
            return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        }
        var records = try await search([URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist)])
        if records.isEmpty {
            // Second try without "(feat. …)", "- Remastered 2011", "[Live]" and similar decorations.
            let clean = q.title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s+-\s+.*(remaster|version|live|edit|mix).*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            records = try await search([URLQueryItem(name: "q", value: "\(q.artist) \(clean)")])
        }
        func score(_ r: Record) -> Double {
            var s = 0.0
            if let d = q.duration, let rd = r.duration { s += abs(d - rd) }
            if (r.syncedLyrics ?? "").isEmpty { s += 4 }
            if (r.plainLyrics ?? "").isEmpty && !(r.instrumental ?? false) { s += 100 }
            return s
        }
        guard let best = records.min(by: { score($0) < score($1) }) else { return nil }
        if let d = q.duration, let rd = best.duration, abs(d - rd) > 20 { return nil }   // probably another song
        let link = "https://lrclib.net/search/" + "\(q.artist) \(q.title)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        return Lyrics(plain: best.plainLyrics, synced: best.syncedLyrics.flatMap(LRC.parse),
                      instrumental: best.instrumental ?? false, source: "LRCLIB", link: link)
    }
}
