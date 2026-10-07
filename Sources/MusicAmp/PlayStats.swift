import AppKit

/// Play counts, skips, ratings and "date added" of every local track MusicAmp has seen, with the tags it last read
/// (smart playlists search them without opening files). Stored in ~/Library/Application Support/MusicAmp/stats.json.
///
/// A play counts once the track has really been listened to for half its length or 4 minutes, whichever comes
/// first (the Last.fm rule; tracks under 30 s must play almost whole); leaving a track after 3 s but before that is a skip. Radio streams aren't counted.
final class PlayStats: ObservableObject {
    static let shared = PlayStats()

    struct Entry: Codable, Equatable {
        var plays = 0
        var skips = 0
        var lastPlayed: Date?
        var lastSkipped: Date?
        /// 0 = not rated, 1…5 stars.
        var rating = 0
        var added = Date()
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var duration: Double?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    /// Bumped on every change (views and smart playlists cache on it).
    private(set) var version = 0

    static var file: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MusicAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }

    /// Debug / tests: an in-memory store (never saved).
    var inMemory = false
    private var saveScheduled = false

    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        guard !inMemory, let d = try? Data(contentsOf: PlayStats.file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        entries = (try? dec.decode([String: Entry].self, from: d)) ?? [:]
    }

    /// Stable key: the file path, or the URL for cue tracks ("…/album.cue#track=3"). nil for streams and episodes.
    static func key(_ url: URL) -> String? {
        guard url.isFileURL, !PodcastStore.shared.isEpisodeURL(url) else { return nil }
        return url.fragment == nil ? url.path : url.absoluteString
    }

    static func url(forKey k: String) -> URL {
        k.hasPrefix("file:") ? (URL(string: k) ?? URL(fileURLWithPath: k)) : URL(fileURLWithPath: k)
    }

    func entry(_ url: URL) -> Entry? { PlayStats.key(url).flatMap { entries[$0] } }
    func rating(_ url: URL) -> Int { entry(url)?.rating ?? 0 }

    private func update(_ url: URL, _ body: (inout Entry) -> Void) {
        guard let k = PlayStats.key(url) else { return }
        var e = entries[k] ?? Entry()
        let before = e
        body(&e)
        guard e != before || entries[k] == nil else { return }
        entries[k] = e
        version &+= 1
        scheduleSave()
    }

    // MARK: Library of known tracks

    /// A track was added or its tags were read: remember it (with the date first seen) and its tags.
    func remember(_ t: Track) {
        update(t.url) { e in
            if let s = t.songTitle ?? (t.title.isEmpty ? nil : t.title) { e.title = s }
            if t.artist != nil { e.artist = t.artist }
            if t.album != nil { e.album = t.album }
            if t.albumArtist != nil { e.albumArtist = t.albumArtist }
            if let d = t.duration { e.duration = d }
        }
    }

    func setRating(_ url: URL, _ stars: Int) {
        update(url) { $0.rating = max(0, min(5, stars)) }
    }

    /// Forget tracks whose files are gone (Smart Playlists → Clean Up).
    func removeMissing() -> Int {
        let gone = entries.keys.filter { !FileManager.default.fileExists(atPath: CueSheet.audioURL(PlayStats.url(forKey: $0)).path) }
        gone.forEach { entries[$0] = nil }
        if !gone.isEmpty { version &+= 1; scheduleSave() }
        return gone.count
    }

    // MARK: Listening

    private var watched: Track?
    private var listened: Double = 0
    private var counted = false
    private var lastPosition: Double = 0
    private var lastDuration: Double = 0
    private var lastTick: Date?

    /// Seconds of real listening that make a play (short interludes: almost all of them).
    static func threshold(duration: Double) -> Double { duration < 30 ? max(1, duration * 0.9) : min(240, duration / 2) }

    /// Called by the controller's timer and on transport changes.
    func observe(track: Track?, playing: Bool, position: Double, duration: Double, now: Date = Date()) {
        if track !== watched {
            finishWatched(now: now)
            watched = track
            listened = 0
            counted = false
            lastTick = nil
            if let t = track { remember(t) }
        }
        guard let t = track, !t.isStream, PlayStats.key(t.url) != nil else { lastTick = nil; return }
        if playing, let last = lastTick {
            listened += min(1, max(0, now.timeIntervalSince(last)))   // seeks and sleeps don't count
        }
        lastTick = playing ? now : nil
        lastPosition = position
        if duration > 0 { lastDuration = duration }
        if !counted, lastDuration > 0, listened >= PlayStats.threshold(duration: lastDuration) {
            counted = true
            update(t.url) { e in e.plays += 1; e.lastPlayed = now }
        }
    }

    /// The watched track is being left: a skip when it was played a bit, not to the end, and not counted.
    private func finishWatched(now: Date) {
        guard let t = watched, !counted, !t.isStream, listened >= 3 else { return }
        let nearEnd = lastDuration > 0 && lastPosition >= lastDuration - 5
        guard !nearEnd else { return }
        update(t.url) { e in e.skips += 1; e.lastSkipped = now }
    }

    // MARK: Persistence

    private func scheduleSave() {
        objectWillChange.send()
        guard !inMemory, !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        guard !inMemory else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(entries) { try? d.write(to: PlayStats.file, options: .atomic) }
    }

    static func stars(_ n: Int, empty: Bool = true) -> String {
        String(repeating: "★", count: n) + (empty ? String(repeating: "☆", count: max(0, 5 - n)) : "")
    }
}
