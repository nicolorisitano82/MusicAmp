import AVFoundation
import Foundation

/// Online tag lookup: MusicBrainz (https://musicbrainz.org/doc/MusicBrainz_API) for release metadata and the
/// Cover Art Archive (https://coverartarchive.org) for covers. Free and keyless, but MusicBrainz asks for a
/// descriptive User-Agent and at most one request per second — both enforced here for every call.
/// Self-contained (Foundation + AVFoundation only); the UI lives in TagEditorView.swift.
enum MusicBrainz {
    static let userAgent = "MusicAmp/0.4 ( https://github.com/nicolorisitano82/MusicAmp )"

    // MARK: Model

    /// A search result.
    struct ReleaseSummary: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let date: String
        let country: String
        let format: String          // "CD", "2×CD", "12\" Vinyl + CD"…
        let trackCount: Int
        let status: String          // "Official", "Bootleg"…
        let disambiguation: String
        let releaseGroupID: String?
    }

    struct Track: Hashable {
        let disc: Int               // medium position, 1-based
        let position: Int           // track position on its medium, 1-based
        let discTrackCount: Int     // tracks on that medium
        let title: String
        let artist: String
        let length: Double?         // seconds
    }

    /// A fetched release, flattened to what the tag editor needs.
    struct Release {
        let id: String
        let title: String
        let artist: String
        let year: String
        let genre: String
        let releaseGroupID: String?
        let discCount: Int
        let tracks: [Track]         // all media in order
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: API

    /// Lucene query for a release search; empty fields are left out.
    static func searchQuery(album: String, artist: String) -> String {
        var parts: [String] = []
        let a = album.trimmingCharacters(in: .whitespacesAndNewlines), r = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { parts.append("release:\"\(luceneEscaped(a))\"") }
        if !r.isEmpty { parts.append("artist:\"\(luceneEscaped(r))\"") }
        return parts.joined(separator: " AND ")
    }

    /// Backslash-escapes Lucene's special characters: + - & | ! ( ) { } [ ] ^ " ~ * ? : \ /
    static func luceneEscaped(_ s: String) -> String {
        let special = Set("+-&|!(){}[]^\"~*?:\\/")
        var out = ""
        for c in s {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// Strict percent-encoding for a query value (URLComponents leaves `+`, `&`… alone).
    static func queryEncoded(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    static func search(album: String, artist: String) async throws -> [ReleaseSummary] {
        let q = searchQuery(album: album, artist: artist)
        guard !q.isEmpty else { return [] }
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(queryEncoded(q))&fmt=json&limit=15"),
              let data = try await fetch(url, throttled: true) else { return [] }
        let json = try decode(SearchJSON.self, data)
        return (json.releases ?? []).map { r in
            let media = r.media ?? []
            let mediaCount = media.reduce(0) { $0 + ($1.trackCount ?? 0) }
            return ReleaseSummary(id: r.id, title: r.title ?? "", artist: credit(r.artistCredit), date: r.date ?? "",
                                  country: r.country ?? "", format: formatSummary(media), trackCount: mediaCount > 0 ? mediaCount : (r.trackCount ?? 0),
                                  status: r.status ?? "", disambiguation: r.disambiguation ?? "", releaseGroupID: r.releaseGroup?.id)
        }
    }

    static func release(_ id: String) async throws -> Release {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/\(queryEncoded(id))?inc=recordings+artist-credits+release-groups+genres+labels&fmt=json"),
              let data = try await fetch(url, throttled: true) else { throw Failure(message: "Release not found") }
        let r = try decode(ReleaseJSON.self, data)
        let albumArtist = credit(r.artistCredit)
        let media = (r.media ?? []).sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        var tracks: [Track] = []
        for (mi, m) in media.enumerated() {
            let list = m.tracks ?? []
            for (ti, t) in list.enumerated() {
                let ms = t.length ?? t.recording?.length
                let a = credit(t.artistCredit)
                tracks.append(Track(disc: m.position ?? mi + 1, position: t.position ?? ti + 1, discTrackCount: m.trackCount ?? list.count,
                                    title: t.title ?? t.recording?.title ?? "", artist: a.isEmpty ? albumArtist : a,
                                    length: ms.map { Double($0) / 1000 }))
            }
        }
        let date = (r.date ?? "").isEmpty ? (r.releaseGroup?.firstReleaseDate ?? "") : (r.date ?? "")
        let genres = (r.genres ?? []).isEmpty ? (r.releaseGroup?.genres ?? []) : (r.genres ?? [])
        let top = genres.max { ($0.count ?? 0) < ($1.count ?? 0) }
        return Release(id: r.id, title: r.title ?? "", artist: albumArtist, year: String(date.prefix(4)),
                       genre: top?.name.capitalized ?? "", releaseGroupID: r.releaseGroup?.id,
                       discCount: max(1, media.count), tracks: tracks)
    }

    /// Full-size front cover: 1200 px, else 500 px, else the release group's. nil when there's none.
    static func cover(release: String, releaseGroup: String?) async -> Data? {
        var urls = ["https://coverartarchive.org/release/\(release)/front-1200", "https://coverartarchive.org/release/\(release)/front-500"]
        if let rg = releaseGroup { urls.append("https://coverartarchive.org/release-group/\(rg)/front-500") }
        for s in urls {
            guard let u = URL(string: s) else { continue }
            if let d = try? await fetch(u, throttled: false), isImage(d) { return d }
        }
        return nil
    }

    private static let thumbs = NSCache<NSString, NSData>()

    /// 250 px front cover for the result list (cached; nil = no cover, which is common).
    static func thumbnail(release: String) async -> Data? {
        if let d = thumbs.object(forKey: release as NSString) { return d as Data }
        guard let u = URL(string: "https://coverartarchive.org/release/\(release)/front-250"),
              let d = try? await fetch(u, throttled: false), isImage(d) else { return nil }
        thumbs.setObject(d as NSData, forKey: release as NSString)
        return d
    }

    /// JPEG, PNG, GIF or WebP magic bytes.
    static func isImage(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        return b.starts(with: [0xFF, 0xD8, 0xFF]) || b.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || b.starts(with: [0x47, 0x49, 0x46]) || (b.count == 12 && b[0...3] == [0x52, 0x49, 0x46, 0x46] && b[8...11] == [0x57, 0x45, 0x42, 0x50])
    }

    /// File duration in seconds via AVFoundation (nil for formats it can't open, e.g. those played through FFmpeg).
    static func duration(of url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric, d.seconds > 0 else { return nil }
        return d.seconds
    }

    // MARK: Track mapping

    /// Which release track (index into `tracks`) each file gets. Uses the files' own disc/track numbers when every
    /// file has one and they point to distinct tracks; otherwise list order. nil = no track for that file.
    /// Without a disc number on a multi-disc release, the track number counts straight through the discs.
    static func mapFiles(_ files: [(track: String, disc: String)], to tracks: [Track]) -> (indices: [Int?], byNumber: Bool) {
        func num(_ s: String) -> Int? { Int(s.split(separator: "/").first?.trimmingCharacters(in: .whitespaces) ?? "") }
        let singleDisc = Set(tracks.map(\.disc)).count <= 1
        var byNumber: [Int] = []
        for f in files {
            guard let n = num(f.track) else { break }
            let idx: Int?
            if let d = num(f.disc) {
                idx = tracks.firstIndex { $0.disc == d && $0.position == n }
            } else if singleDisc {
                idx = tracks.firstIndex { $0.position == n }
            } else {
                idx = tracks.indices.contains(n - 1) ? n - 1 : nil
            }
            guard let idx else { break }
            byNumber.append(idx)
        }
        if !files.isEmpty, byNumber.count == files.count, Set(byNumber).count == byNumber.count {
            return (byNumber, true)
        }
        return (files.indices.map { tracks.indices.contains($0) ? $0 : nil }, false)
    }

    // MARK: Networking

    /// Serial 1 request/s gate for musicbrainz.org: each caller reserves the next free slot before sleeping,
    /// so concurrent callers queue up instead of bursting.
    private actor Throttle {
        private var next = Date.distantPast
        func wait() async {
            let now = Date()
            let slot = max(now, next)
            next = slot.addingTimeInterval(1.0)
            let delay = slot.timeIntervalSince(now)
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
    }

    private static let throttle = Throttle()

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: c)   // follows redirects (Cover Art Archive → archive.org)
    }()

    /// GET with our User-Agent; nil on 404. A 503 (rate limited) is retried once after 1.5 s.
    private static func fetch(_ url: URL, throttled: Bool) async throws -> Data? {
        for attempt in 0..<2 {
            if throttled { await throttle.wait() }
            var req = URLRequest(url: url)
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if throttled { req.setValue("application/json", forHTTPHeaderField: "Accept") }
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
            if code == 503 && attempt == 0 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                continue
            }
            if code == 404 { return nil }
            guard (200..<300).contains(code) else {
                throw Failure(message: code == 503 ? "MusicBrainz is busy (HTTP 503), try again in a moment" : "Server error (HTTP \(code))")
            }
            return data
        }
        return nil
    }

    // MARK: JSON

    private struct Credit: Decodable { let name: String?; let joinphrase: String? }
    private struct Genre: Decodable { let name: String; let count: Int? }
    private struct Recording: Decodable { let title: String?; let length: Int? }
    private struct TrackJSON: Decodable { let position: Int?; let title: String?; let length: Int?; let artistCredit: [Credit]?; let recording: Recording? }
    private struct Medium: Decodable { let position: Int?; let format: String?; let trackCount: Int?; let tracks: [TrackJSON]? }
    private struct ReleaseGroup: Decodable { let id: String; let firstReleaseDate: String?; let genres: [Genre]? }
    private struct ReleaseJSON: Decodable {
        let id: String
        let title, status, date, country, disambiguation: String?
        let artistCredit: [Credit]?
        let releaseGroup: ReleaseGroup?
        let media: [Medium]?
        let trackCount: Int?
        let genres: [Genre]?
    }
    private struct SearchJSON: Decodable { let releases: [ReleaseJSON]? }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { stringValue = "\(intValue)"; self.intValue = intValue }
    }

    /// MusicBrainz uses kebab-case keys ("artist-credit" → artistCredit).
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .custom { path in
            let parts = path.last!.stringValue.split(separator: "-")
            guard parts.count > 1 else { return path.last! }
            return Key(stringValue: String(parts[0]) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined())
        }
        do { return try dec.decode(type, from: data) } catch { throw Failure(message: "Unexpected response from MusicBrainz") }
    }

    /// Artist credit as displayed: names joined with their join phrases ("A feat. B").
    private static func credit(_ c: [Credit]?) -> String {
        (c ?? []).map { ($0.name ?? "") + ($0.joinphrase ?? "") }.joined().trimmingCharacters(in: .whitespaces)
    }

    /// "CD", "2×CD", "12\" Vinyl + CD"…
    private static func formatSummary(_ media: [Medium]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for m in media {
            let f = m.format ?? "Unknown"
            if counts[f] == nil { order.append(f) }
            counts[f, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\(counts[$0]!)×\($0)" : $0 }.joined(separator: " + ")
    }

    // MARK: Self-test

    /// Real lookups against MusicBrainz / Cover Art Archive plus pure checks (escaping, track mapping).
    /// Returns (passed, description) pairs; takes a few seconds because of the 1 request/s limit.
    static func selfTest() async -> [(Bool, String)] {
        var out: [(Bool, String)] = []
        func check(_ ok: Bool, _ s: String) { out.append((ok, s)) }

        // Escaping and encoding.
        let esc = luceneEscaped("AC/DC \"Back in Black\" (Remastered)")
        check(esc == "AC\\/DC \\\"Back in Black\\\" \\(Remastered\\)", "Lucene escaping: \(esc)")
        let q = searchQuery(album: "Back in Black (Remastered)", artist: "AC/DC")
        check(q == "release:\"Back in Black \\(Remastered\\)\" AND artist:\"AC\\/DC\"", "Search query: \(q)")
        let enc = queryEncoded("a+b & \"c\"")
        check(enc == "a%2Bb%20%26%20%22c%22", "Query encoding: \(enc)")

        // Track mapping (pure).
        func t(_ d: Int, _ p: Int, _ n: Int) -> Track { Track(disc: d, position: p, discTrackCount: n, title: "\(d)-\(p)", artist: "", length: nil) }
        let one = (1...5).map { t(1, $0, 5) }
        let two = (1...3).map { t(1, $0, 3) } + (1...2).map { t(2, $0, 2) }
        var m = mapFiles([("", ""), ("", ""), ("", "")], to: one)
        check(m.indices == [0, 1, 2] && !m.byNumber, "Mapping by order (3 files, no numbers): \(m.indices)")
        m = mapFiles([("3", ""), ("1/5", ""), ("2", "")], to: one)
        check(m.indices == [2, 0, 1] && m.byNumber, "Mapping by track numbers: \(m.indices)")
        m = mapFiles([("2", "2"), ("1", "1"), ("1", "2")], to: two)
        check(m.indices == [4, 0, 3] && m.byNumber, "Mapping by disc + track numbers: \(m.indices)")
        m = mapFiles([("1", ""), ("1", ""), ("", "")], to: one)
        check(m.indices == [0, 1, 2] && !m.byNumber, "Duplicate/missing numbers fall back to order: \(m.indices)")
        m = mapFiles((0..<7).map { _ in ("", "") }, to: one)
        check(m.indices.compactMap { $0 }.count == 5 && m.indices.last! == nil, "More files than tracks leaves extras unmapped")
        m = mapFiles([("4", ""), ("5", "")], to: two)
        check(m.indices == [3, 4] && m.byNumber, "Multi-disc without disc numbers counts through discs: \(m.indices)")

        // Network: search, fetch, cover.
        do {
            let started = Date()
            let results = try await search(album: "Abbey Road", artist: "The Beatles")
            check(!results.isEmpty, "Search \"Abbey Road\" / \"The Beatles\": \(results.count) results")
            guard let pick = results.first(where: { $0.status == "Official" }) ?? results.first else { return out }
            let r = try await release(pick.id)
            let elapsed = Date().timeIntervalSince(started)
            check(r.tracks.count >= 17 && r.tracks.allSatisfy { !$0.title.isEmpty },
                  "Release \(pick.id): \(r.tracks.count) tracks, \(r.discCount) disc(s), year \(r.year), genre \"\(r.genre)\"")
            check(!r.title.isEmpty && !r.artist.isEmpty && r.year.count == 4, "Release fields: title/artist/year present")
            check(r.tracks.filter { $0.length != nil }.count >= 17, "Track lengths: \(r.tracks.filter { $0.length != nil }.count)")
            check(elapsed >= 1.0, String(format: "Rate limit: 2 MusicBrainz requests took %.2f s", elapsed))
            let cover = await cover(release: pick.id, releaseGroup: pick.releaseGroupID ?? r.releaseGroupID)
            check(cover.map(isImage) == true, "Cover download: \(cover?.count ?? 0) bytes")
            let thumb = await thumbnail(release: pick.id)
            check(true, "Thumbnail: \(thumb.map { "\($0.count) bytes" } ?? "none (normal for some releases)")")
        } catch {
            check(false, "Network: \(error.localizedDescription)")
        }
        return out
    }
}
