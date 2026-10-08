import AVFoundation

final class Track {
    let url: URL
    var title: String
    var duration: Double?
    var artist: String?
    var songTitle: String?
    var album: String?
    /// "Album artist" tag (TPE2 / aART / ALBUMARTIST): groups the playlist tree.
    var albumArtist: String?
    /// Live "StreamTitle" of a radio track.
    var streamTitle: String?
    var genre: String?
    var year: Int?

    /// http(s) URLs are internet radio streams (or remote playlists that resolve to one),
    /// except podcast episodes, which are seekable remote files.
    var isStream: Bool { !url.isFileURL && !PodcastStore.shared.isEpisodeURL(url) }
    /// Podcast episode (remote or downloaded).
    var isEpisode: Bool { PodcastStore.shared.isEpisodeURL(url) }

    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : (url.host ?? url.absoluteString))
    }
}

final class Playlist {
    static let nativeExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "wav", "aif", "aiff", "aifc",
                                                "flac", "caf", "mp4", "mp2", "ac3", "3gp", "amr"]
    /// Native formats plus what an installed ffmpeg adds (Ogg, Opus, APE, WavPack…).
    static var audioExtensions: Set<String> { FFmpeg.available ? nativeExtensions.union(FFmpeg.extensions) : nativeExtensions }

    var tracks: [Track] = [] { didSet { version &+= 1 } }
    var selection = Set<Int>() { didSet { version &+= 1 } }
    /// Identity of the loaded track, so reorders and removals keep it.
    var currentTrack: Track? { didSet { version &+= 1 } }
    /// Bumped on every change (including metadata arriving), so views know when to redraw.
    private(set) var version = 0
    var onCurrentMetadata: (() -> Void)?

    var current: Int? {
        guard let c = currentTrack else { return nil }
        return tracks.firstIndex { $0 === c }
    }

    var totalDuration: Double { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
    var selectedDuration: Double { selection.reduce(0) { $0 + (tracks.indices.contains($1) ? (tracks[$1].duration ?? 0) : 0) } }

    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for u in urls {
            if !u.isFileURL, ["http", "https"].contains(u.scheme?.lowercased() ?? "") { out.append(u); continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let all = (fm.enumerator(at: u, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                // Cue sheets replace the audio files they index (one big FLAC/APE per album).
                let cues = all.filter { $0.pathExtension.lowercased() == "cue" }
                var covered = Set<String>()
                var cueTracks: [String: [URL]] = [:]
                for c in cues {
                    let tracks = CueSheet.trackURLs(c)
                    guard !tracks.isEmpty else { continue }
                    CueSheet.parse(c)?.entries.forEach { covered.insert($0.file.standardizedFileURL.path) }
                    cueTracks[c.path] = tracks
                }
                for f in all {
                    if let t = cueTracks[f.path] { out += t; continue }
                    if audioExtensions.contains(f.pathExtension.lowercased()), !covered.contains(f.standardizedFileURL.path) { out.append(f) }
                }
            } else if u.pathExtension.lowercased() == "cue", u.fragment == nil {
                out += CueSheet.trackURLs(u)
            } else if CueSheet.isCueTrack(u) {
                out.append(u)
            } else if audioExtensions.contains(u.pathExtension.lowercased()) {
                out.append(u)
            } else if ["m3u", "m3u8", "pls"].contains(u.pathExtension.lowercased()) {
                out += readList(u)
            }
        }
        return out
    }

    func add(_ urls: [URL]) {
        let new = Playlist.expand(urls).map { Track(url: $0) }
        tracks += new
        new.forEach(loadMetadata)
    }

    /// Inserts at `index` (a drop between rows) and selects what was inserted.
    func insert(_ urls: [URL], at index: Int) {
        let new = Playlist.expand(urls).map { Track(url: $0) }
        guard !new.isEmpty else { return }
        let i = max(0, min(index, tracks.count))
        tracks.insert(contentsOf: new, at: i)
        selection = Set(i..<(i + new.count))
        new.forEach(loadMetadata)
    }

    func clear() {
        tracks = []
        selection = []
        queue = []
        currentTrack = nil
    }

    func remove(_ indices: Set<Int>) {
        tracks = tracks.enumerated().filter { !indices.contains($0.offset) }.map(\.element)
        selection = []
        pruneQueue()
    }

    func crop(_ keep: Set<Int>) {
        tracks = tracks.enumerated().filter { keep.contains($0.offset) }.map(\.element)
        selection = Set(tracks.indices)
        pruneQueue()
    }

    // MARK: Queue (Winamp "Q"): queued tracks play next, in order, before the playlist continues.

    var queue: [Track] = [] { didSet { version &+= 1 } }

    func queuePosition(_ t: Track) -> Int? { queue.firstIndex { $0 === t }.map { $0 + 1 } }

    /// Q toggles: unqueued rows are appended to the queue, queued ones are taken out.
    func toggleQueue(_ indices: Set<Int>) {
        for i in indices.sorted() where tracks.indices.contains(i) {
            let t = tracks[i]
            if let q = queue.firstIndex(where: { $0 === t }) { queue.remove(at: q) } else { queue.append(t) }
        }
    }

    /// Next queued track still in the playlist, removed from the queue.
    func popQueue() -> Int? {
        while !queue.isEmpty {
            let t = queue.removeFirst()
            if let i = tracks.firstIndex(where: { $0 === t }) { return i }
        }
        return nil
    }

    private func pruneQueue() {
        let ids = Set(tracks.map(ObjectIdentifier.init))
        queue = queue.filter { ids.contains(ObjectIdentifier($0)) }
    }

    /// Moves the selected rows by `delta`, keeping them selected.
    func moveSelection(by delta: Int) {
        guard delta != 0, !selection.isEmpty else { return }
        let sel = selection.sorted()
        let d = max(-sel.first!, min(delta, tracks.count - 1 - sel.last!))
        guard d != 0 else { return }
        let moving = sel.map { tracks[$0] }
        var rest = tracks.enumerated().filter { !selection.contains($0.offset) }.map(\.element)
        let insertAt = max(0, min(rest.count, sel.first! + d))
        rest.insert(contentsOf: moving, at: insertAt)
        tracks = rest
        selection = Set(insertAt..<(insertAt + moving.count))
    }

    func sort(by key: (Track) -> String) {
        let sel = Set(selection.map { tracks[$0] }.map(ObjectIdentifier.init))
        tracks.sort { key($0).localizedStandardCompare(key($1)) == .orderedAscending }
        selection = Set(tracks.indices.filter { sel.contains(ObjectIdentifier(tracks[$0])) })
    }

    func shuffle() { tracks.shuffle(); selection = [] }
    func reverse() { tracks.reverse(); selection = [] }

    /// Bumps the version after in-place changes to a track (radio titles).
    func touch() { version &+= 1 }

    /// Re-reads a track's tags (after the tag editor wrote them).
    func reloadMetadata(_ t: Track) { loadMetadata(t) }

    private func loadMetadata(_ t: Track) {
        guard t.url.isFileURL else { return }
        if let (sheet, e) = CueSheet.entry(t.url) {
            // Cue track: everything comes from the sheet; the last track's length needs the file's duration.
            t.songTitle = e.title ?? "Track \(e.number)"
            t.artist = e.performer ?? sheet.performer
            t.album = sheet.title
            t.albumArtist = sheet.performer
            t.genre = sheet.genre
            t.year = sheet.date.flatMap { Int($0.prefix(4)) }
            t.title = t.artist.map { "\($0) - \(t.songTitle!)" } ?? t.songTitle!
            if let end = e.end { t.duration = end - e.start }
            version &+= 1
            PlayStats.shared.remember(t)
            if e.end == nil {
                let file = e.file
                Task {
                    let total = (try? await AVURLAsset(url: file).load(.duration).seconds)
                        ?? (FFmpeg.available ? FFmpeg.probe(file)?.duration : nil)
                    await MainActor.run {
                        if let total, total.isFinite, total > e.start { t.duration = total - e.start; self.version &+= 1 }
                    }
                }
            }
            return
        }
        if FFmpeg.extensions.contains(t.url.pathExtension.lowercased()) {
            // AVFoundation can't read these: ask ffprobe.
            guard FFmpeg.available else { return }
            DispatchQueue.global(qos: .utility).async {
                guard let p = FFmpeg.probe(t.url) else { return }
                DispatchQueue.main.async {
                    if p.duration > 0 { t.duration = p.duration }
                    if let title = p.title, !title.isEmpty {
                        t.title = (p.artist?.isEmpty == false) ? "\(p.artist!) - \(title)" : title
                    }
                    t.artist = p.artist
                    t.songTitle = p.title
                    t.album = p.album
                    t.albumArtist = p.albumArtist
                    t.genre = p.genre
                    t.year = p.year
                    self.version &+= 1
                    PlayStats.shared.remember(t)
                    if t === self.currentTrack { self.onCurrentMetadata?() }
                }
            }
            return
        }
        Task {
            let asset = AVURLAsset(url: t.url)
            let dur = try? await asset.load(.duration)
            let md = (try? await asset.load(.commonMetadata)) ?? []
            var artist: String?
            var title: String?
            var album: String?
            var albumArtist: String?
            for item in md {
                if item.commonKey == .commonKeyArtist { artist = try? await item.load(.stringValue) }
                if item.commonKey == .commonKeyTitle { title = try? await item.load(.stringValue) }
                if item.commonKey == .commonKeyAlbumName { album = try? await item.load(.stringValue) }
            }
            // Album artist isn't a common key: look for it in the format-specific metadata.
            for item in (try? await asset.load(.metadata)) ?? [] where
                [.iTunesMetadataAlbumArtist, .id3MetadataBand].contains(item.identifier) {
                albumArtist = try? await item.load(.stringValue)
            }
            // Genre, year and the star rating: our own readers for MP3 and FLAC (AVFoundation doesn't expose
            // Vorbis comments or POPM), AVFoundation for the MP4 family.
            var genre: String?, year: Int?, rating = 0
            switch TagIO.kind(t.url) {
            case .id3, .flac:
                let tags = TagIO.kind(t.url) == .id3 ? try? ID3.read(t.url) : try? FLACTags.read(t.url)
                genre = tags.map(\.genre).flatMap { $0.isEmpty ? nil : $0 }
                year = tags.flatMap { Int($0.year.prefix(4)) }
                rating = tags.flatMap { Int($0.rating) } ?? 0
            default:
                for item in (try? await asset.load(.metadata)) ?? [] {
                    switch item.identifier {
                    case .iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre:
                        if genre == nil { genre = try? await item.load(.stringValue) }
                    case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .quickTimeMetadataYear:
                        if year == nil, let s = try? await item.load(.stringValue) { year = Int(s.prefix(4)) }
                    default: break
                    }
                }
            }
            var display: String?
            if let title, !title.isEmpty {
                display = (artist?.isEmpty == false) ? "\(artist!) - \(title)" : title
            }
            let seconds = dur?.seconds
            await MainActor.run { [display, artist, title, album, albumArtist, genre, year, rating] in
                if let d = seconds, d.isFinite, d > 0 { t.duration = d }
                if let display { t.title = display }
                t.artist = artist
                t.songTitle = title
                t.album = album
                t.albumArtist = albumArtist
                t.genre = genre
                t.year = year
                self.version &+= 1
                PlayStats.shared.remember(t)
                if rating > 0 { PlayStats.shared.importRating(t.url, rating) }
                if t === self.currentTrack { self.onCurrentMetadata?() }
            }
        }
    }

    // MARK: M3U / PLS

    static func readList(_ url: URL) -> [URL] {
        guard let s = Skin.readText(url) else { return [] }
        let base = url.deletingLastPathComponent()
        var out: [URL] = []
        for raw in Skin.lines(s) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if url.pathExtension.lowercased() == "pls" {
                guard line.lowercased().hasPrefix("file"), let eq = line.firstIndex(of: "=") else { continue }
                line = String(line[line.index(after: eq)...])
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("file://"), let u = URL(string: line) { out.append(u); continue }
            if line.hasPrefix("http://") || line.hasPrefix("https://"), let u = URL(string: line) { out.append(u); continue }
            line = line.replacingOccurrences(of: "\\", with: "/")
            let u = line.hasPrefix("/") ? URL(fileURLWithPath: line) : base.appendingPathComponent(line)
            if FileManager.default.fileExists(atPath: u.path) { out.append(u.standardizedFileURL) }
        }
        return out
    }

    func writeM3U(to url: URL) throws {
        var s = "#EXTM3U\n"
        for t in tracks {
            s += "#EXTINF:\(Int(t.duration ?? -1)),\(t.title)\n\(t.url.isFileURL ? t.url.path : t.url.absoluteString)\n"
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Track: Equatable {
    static func == (a: Track, b: Track) -> Bool { a === b }
}
