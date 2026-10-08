import AppKit

/// Rule-based playlists over every track MusicAmp knows (all files ever added, with their play counts and
/// ratings, plus the Music library when it has been loaded). Saved in
/// ~/Library/Application Support/MusicAmp/smart-playlists.json.
struct SmartRule: Codable, Identifiable, Equatable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case title, artist, album, albumArtist, genre, year, path, format, duration, rating, plays, skips, lastPlayed, added, bpm, key, mood, style
        var id: String { rawValue }
        var label: String {
            switch self {
            case .title: return "Title"
            case .artist: return "Artist"
            case .album: return "Album"
            case .albumArtist: return "Album Artist"
            case .genre: return "Genre"
            case .year: return "Year"
            case .bpm: return "BPM (Sonic Mix)"
            case .key: return "Key (Sonic Mix)"
            case .mood: return "Mood (Sonic Mix)"
            case .style: return "Instruments (Sonic Mix)"
            case .path: return "File Path"
            case .format: return "Format"
            case .duration: return "Length (min)"
            case .rating: return "Rating (stars)"
            case .plays: return "Plays"
            case .skips: return "Skips"
            case .lastPlayed: return "Last Played"
            case .added: return "Date Added"
            }
        }
        enum Kind { case text, number, date, key }
        var kind: Kind {
            switch self {
            case .title, .artist, .album, .albumArtist, .genre, .path, .format, .mood, .style: return .text
            case .duration, .rating, .plays, .skips, .year, .bpm: return .number
            case .lastPlayed, .added: return .date
            case .key: return .key
            }
        }
        /// Needs the Sonic Mix analysis.
        var sonic: Bool { self == .bpm || self == .key || self == .mood || self == .style }
    }

    enum Op: String, Codable, CaseIterable, Identifiable {
        case contains, notContains, equals, notEquals, startsWith, endsWith   // text
        case numEquals, numNotEquals, greater, less                       // numbers
        case inLast, notInLast                                            // dates, in days
        case keyIs, keyIsNot, keyCompatible                               // keys
        var id: String { rawValue }
        var label: String {
            switch self {
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .equals, .numEquals: return "is"
            case .notEquals, .numNotEquals: return "is not"
            case .startsWith: return "starts with"
            case .endsWith: return "ends with"
            case .greater: return "is greater than"
            case .less: return "is less than"
            case .inLast: return "is in the last (days)"
            case .notInLast: return "is not in the last (days)"
            case .keyIs: return "is"
            case .keyIsNot: return "is not"
            case .keyCompatible: return "mixes well with"
            }
        }
        static func ops(for k: Field.Kind) -> [Op] {
            switch k {
            case .text: return [.contains, .notContains, .equals, .notEquals, .startsWith, .endsWith]
            case .number: return [.numEquals, .numNotEquals, .greater, .less]
            case .date: return [.inLast, .notInLast]
            case .key: return [.keyCompatible, .keyIs, .keyIsNot]
            }
        }
    }

    var id = UUID()
    var field: Field = .artist
    var op: Op = .contains
    var text = ""
    var number: Double = 0

    enum CodingKeys: String, CodingKey { case field, op, text, number }

    /// Keeps the operator valid after the field changed.
    mutating func fixOp() {
        if !Op.ops(for: field.kind).contains(op) { op = Op.ops(for: field.kind)[0] }
    }

    func matches(_ it: SmartItem, now: Date) -> Bool {
        switch field.kind {
        case .text:
            let v = SmartRule.fold(it.text(field)), q = SmartRule.fold(text)
            switch op {
            case .contains: return v.contains(q)
            case .notContains: return !v.contains(q)
            case .equals: return v == q
            case .notEquals: return v != q
            case .startsWith: return v.hasPrefix(q)
            case .endsWith: return v.hasSuffix(q)
            default: return false
            }
        case .number:
            // Unknown values (no year tag, track not analysed) match nothing, not "0".
            guard let v = it.number(field) else { return op == .numNotEquals }
            switch op {
            case .numEquals: return abs(v - number) < 0.001
            case .numNotEquals: return abs(v - number) >= 0.001
            case .greater: return v > number
            case .less: return v < number
            default: return false
            }
        case .date:
            let since = now.addingTimeInterval(-number * 86400)
            let inside = it.date(field).map { $0 >= since } ?? false
            return op == .inLast ? inside : !inside
        case .key:
            guard let f = it.sonic, let want = SmartRule.parseKey(text) else { return op == .keyIsNot }
            let same = f.key == want.key && f.minor == want.minor
            switch op {
            case .keyIs: return same
            case .keyIsNot: return !same
            default:
                // Harmonic mixing (Camelot wheel): same key, relative major/minor, or one fifth away.
                let a = f.fifths, b = SmartRule.fifths(want.key, want.minor)
                let d = abs(a - b) % 12
                return min(d, 12 - d) <= 1 && (f.minor == want.minor || a == b)
            }
        }
    }

    /// "Am", "C#", "F♯m", "Bb", "e minor" → pitch class and mode.
    static func parseKey(_ s: String) -> (key: Int, minor: Bool)? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "♯", with: "#").replacingOccurrences(of: "♭", with: "b")
        guard let first = t.first?.uppercased(), let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][first] else { return nil }
        t.removeFirst()
        var k = base
        if t.hasPrefix("#") { k += 1; t.removeFirst() } else if t.hasPrefix("b") { k -= 1; t.removeFirst() }
        let rest = t.lowercased().trimmingCharacters(in: .whitespaces)
        let minor = rest.hasPrefix("m") && !rest.hasPrefix("maj")
        return ((k + 12) % 12, minor)
    }

    static func fifths(_ key: Int, _ minor: Bool) -> Int { ((minor ? (key + 3) % 12 : key) * 7) % 12 }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}

/// A track as smart playlists see it.
struct SmartItem: Identifiable, Hashable {
    let key: String
    let url: URL
    let stats: PlayStats.Entry
    var id: String { key }

    static func == (a: SmartItem, b: SmartItem) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }

    var title: String { stats.title ?? CueSheet.audioURL(url).deletingPathExtension().lastPathComponent }

    func text(_ f: SmartRule.Field) -> String {
        switch f {
        case .title: return title
        case .artist: return stats.artist ?? ""
        case .album: return stats.album ?? ""
        case .albumArtist: return stats.albumArtist ?? stats.artist ?? ""
        case .genre: return stats.genre ?? ""
        case .mood: return sonic?.mood ?? ""
        case .style: return sonic?.style?.joined(separator: ", ") ?? ""
        case .path: return CueSheet.audioURL(url).path
        case .format: return CueSheet.audioURL(url).pathExtension
        default: return ""
        }
    }

    func number(_ f: SmartRule.Field) -> Double? {
        switch f {
        case .duration: return (stats.duration ?? 0) / 60
        case .rating: return Double(stats.rating)
        case .plays: return Double(stats.plays)
        case .skips: return Double(stats.skips)
        case .year: return stats.year.map(Double.init)
        case .bpm: return sonic.flatMap { $0.bpm > 0 ? Double($0.bpm) : nil }
        default: return nil
        }
    }

    /// Sonic Mix analysis, when done.
    var sonic: SonicFeatures? { SonicStore.shared.features[key] }

    func date(_ f: SmartRule.Field) -> Date? {
        switch f {
        case .lastPlayed: return stats.lastPlayed
        case .added: return stats.added
        default: return nil
        }
    }
}

struct SmartPlaylist: Codable, Identifiable, Equatable {
    enum Order: String, Codable, CaseIterable, Identifiable {
        case random, mostPlayed, leastPlayed, highestRated, lowestRated, recentlyPlayed, leastRecentlyPlayed, recentlyAdded, album, artist, title, year, bpm
        var id: String { rawValue }
        var label: String {
            switch self {
            case .random: return "Random"
            case .mostPlayed: return "Most Played"
            case .leastPlayed: return "Least Played"
            case .highestRated: return "Highest Rating"
            case .lowestRated: return "Lowest Rating"
            case .recentlyPlayed: return "Most Recently Played"
            case .leastRecentlyPlayed: return "Least Recently Played"
            case .recentlyAdded: return "Most Recently Added"
            case .album: return "Album"
            case .artist: return "Artist"
            case .title: return "Title"
            case .year: return "Year"
            case .bpm: return "BPM"
            }
        }
    }

    var id = UUID()
    var name = "New Smart Playlist"
    var matchAll = true
    var rules: [SmartRule] = [SmartRule()]
    /// 0 = no limit.
    var limit = 0
    var order: Order = .artist
    /// Hide tracks whose file is gone (an external disk unplugged, a file deleted).
    var onlyExisting = true

    func evaluate(_ pool: [SmartItem], now: Date = Date()) -> [SmartItem] {
        var out = pool.filter { it in
            rules.isEmpty || (matchAll ? rules.allSatisfy { $0.matches(it, now: now) } : rules.contains { $0.matches(it, now: now) })
        }
        if onlyExisting { out = out.filter { FileManager.default.fileExists(atPath: CueSheet.audioURL($0.url).path) } }
        func byAlbum(_ a: SmartItem, _ b: SmartItem) -> Bool {
            let ka = (SmartRule.fold(a.text(.albumArtist)), SmartRule.fold(a.text(.album)), a.url.absoluteString)
            let kb = (SmartRule.fold(b.text(.albumArtist)), SmartRule.fold(b.text(.album)), b.url.absoluteString)
            return ka < kb
        }
        let far = Date.distantPast
        switch order {
        case .random: out.shuffle()
        case .mostPlayed: out.sort { ($0.stats.plays, $1.stats.lastPlayed ?? far) > ($1.stats.plays, $0.stats.lastPlayed ?? far) }
        case .leastPlayed: out.sort { $0.stats.plays < $1.stats.plays }
        case .highestRated: out.sort { ($0.stats.rating, $0.stats.plays) > ($1.stats.rating, $1.stats.plays) }
        case .lowestRated: out.sort { $0.stats.rating < $1.stats.rating }
        case .recentlyPlayed: out.sort { ($0.stats.lastPlayed ?? far) > ($1.stats.lastPlayed ?? far) }
        case .leastRecentlyPlayed: out.sort { ($0.stats.lastPlayed ?? far) < ($1.stats.lastPlayed ?? far) }
        case .recentlyAdded: out.sort { $0.stats.added > $1.stats.added }
        case .album: out.sort(by: byAlbum)
        case .artist: out.sort { (SmartRule.fold($0.text(.artist)), SmartRule.fold($0.text(.album)), $0.url.absoluteString) < (SmartRule.fold($1.text(.artist)), SmartRule.fold($1.text(.album)), $1.url.absoluteString) }
        case .title: out.sort { SmartRule.fold($0.title) < SmartRule.fold($1.title) }
        case .year: out.sort { ($0.stats.year ?? Int.max) < ($1.stats.year ?? Int.max) }
        case .bpm: out.sort { ($0.sonic?.bpm ?? .infinity) < ($1.sonic?.bpm ?? .infinity) }
        }
        if limit > 0, out.count > limit { out = Array(out.prefix(limit)) }
        return out
    }

    static var defaults: [SmartPlaylist] {
        func rule(_ f: SmartRule.Field, _ op: SmartRule.Op, _ n: Double = 0, _ t: String = "") -> SmartRule { SmartRule(field: f, op: op, text: t, number: n) }
        return [
            SmartPlaylist(name: "Top 25 Most Played", rules: [rule(.plays, .greater, 0)], limit: 25, order: .mostPlayed),
            SmartPlaylist(name: "Recently Played", rules: [rule(.lastPlayed, .inLast, 14)], limit: 100, order: .recentlyPlayed),
            SmartPlaylist(name: "Recently Added", rules: [rule(.added, .inLast, 30)], limit: 200, order: .recentlyAdded),
            SmartPlaylist(name: "Top Rated", rules: [rule(.rating, .greater, 3)], order: .highestRated),
            SmartPlaylist(name: "Never Played", rules: [rule(.plays, .numEquals, 0)], limit: 50, order: .random),
            SmartPlaylist(name: "Forgotten Favorites", rules: [rule(.rating, .greater, 3), rule(.lastPlayed, .notInLast, 60)], limit: 50, order: .random),
            SmartPlaylist(name: "Often Skipped", rules: [rule(.skips, .greater, 2)], order: .lowestRated),
        ]
    }
}

final class SmartPlaylistStore: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = SmartPlaylistStore()

    @Published var playlists: [SmartPlaylist] = [] { didSet { save() } }

    static var file: URL { PlayStats.file.deletingLastPathComponent().appendingPathComponent("smart-playlists.json") }

    override init() {
        super.init()
        if let d = try? Data(contentsOf: SmartPlaylistStore.file), let p = try? JSONDecoder().decode([SmartPlaylist].self, from: d) {
            playlists = p
        } else {
            playlists = SmartPlaylist.defaults
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(playlists) { try? d.write(to: SmartPlaylistStore.file, options: .atomic) }
        // Siri phrases name the playlists ("Play Top Rated in MusicAmp").
        MusicAmpShortcuts.updateAppShortcutParameters()
    }

    /// Every known track: the play statistics (all files ever added) and the Music library, when loaded.
    static func pool(stats: PlayStats = .shared) -> [SmartItem] {
        var items: [String: SmartItem] = [:]
        for (k, e) in stats.entries { items[k] = SmartItem(key: k, url: PlayStats.url(forKey: k), stats: e) }
        let lib = MusicLibrary.shared
        for s in lib.musicSongs + lib.folderSongs {
            guard let k = PlayStats.key(s.url), items[k] == nil else { continue }
            var e = PlayStats.Entry()
            e.added = .distantPast
            e.title = s.title; e.artist = s.artist; e.album = s.album; e.duration = s.duration
            items[k] = SmartItem(key: k, url: s.url, stats: e)
        }
        return Array(items.values)
    }

    func tracks(_ p: SmartPlaylist) -> [SmartItem] { p.evaluate(SmartPlaylistStore.pool()) }

    /// Replaces the playlist with the smart playlist and plays it (or appends it).
    @MainActor
    func play(_ p: SmartPlaylist, append: Bool = false) -> Int {
        let urls = tracks(p).map(\.url)
        guard !urls.isEmpty else { return 0 }
        let c = Ctl.shared
        if append { c.playlist.add(urls) } else { c.replacePlaylist(urls, play: true) }
        c.flashMarquee(p.name.uppercased())
        return urls.count
    }

    // MARK: Menu (File → Smart Playlists)

    func menu() -> NSMenu {
        let m = NSMenu(title: "Smart Playlists")
        m.delegate = self
        return m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        for (i, p) in playlists.enumerated() {
            let it = m.addItem(withTitle: p.name, action: #selector(menuPlay(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
        }
        if !playlists.isEmpty { m.addItem(.separator()) }
        let edit = m.addItem(withTitle: "Edit Smart Playlists…", action: #selector(Ctl.showSmartPlaylists), keyEquivalent: "")
        edit.target = Ctl.shared
    }

    @objc private func menuPlay(_ s: NSMenuItem) {
        guard playlists.indices.contains(s.tag) else { return }
        MainActor.assumeIsolated {
            if play(playlists[s.tag]) == 0 { Ctl.shared.flashMarquee("SMART PLAYLIST IS EMPTY"); NSSound.beep() }
        }
    }
}
