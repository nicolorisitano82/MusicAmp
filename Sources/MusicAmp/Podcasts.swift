import AppKit
import Foundation

struct PodcastEpisode: Codable, Identifiable, Hashable {
    var id: String            // guid, or the enclosure URL
    var title: String
    var pubDate: Date?
    var enclosure: String
    var length: Int?
    var duration: Double?
    var summary: String?
    var imageURL: String?
}

struct PodcastFeed: Codable, Identifiable, Hashable {
    var feedURL: String
    var title: String
    var author: String?
    var artworkURL: String?
    var summary: String?
    var episodes: [PodcastEpisode] = []
    /// Listening speed for this show (nil = default podcast speed).
    var speed: Double?
    var lastRefresh: Date?
    var id: String { feedURL }
}

/// Per-episode listening state.
struct EpisodeState: Codable, Hashable {
    var played = false
    var position: Double = 0
    var file: String?   // downloaded file name inside the show's folder
}

/// Podcast subscriptions: RSS (with iTunes tags), Apple catalogue search, downloads, OPML, listening state.
final class PodcastStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = PodcastStore()

    @Published private(set) var feeds: [PodcastFeed] = [] { didSet { rebuildIndex() } }
    /// Enclosure URLs of all known episodes, for fast "is this playlist URL an episode?" checks.
    private var enclosures = Set<String>()

    private func rebuildIndex() { enclosures = Set(feeds.flatMap { $0.episodes.map(\.enclosure) }) }
    @Published private(set) var states: [String: EpisodeState] = [:]
    @Published private(set) var downloads: [String: Double] = [:]   // key → 0…1
    @Published private(set) var refreshing = Set<String>()

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var taskKeys: [Int: String] = [:]
    private var saveScheduled = false

    var dir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Podcasts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private var dbURL: URL { dir.deletingLastPathComponent().appendingPathComponent("podcasts.json") }

    private struct DB: Codable {
        var feeds: [PodcastFeed]
        var states: [String: EpisodeState]
    }

    override private init() {
        super.init()
        if let d = try? Data(contentsOf: dbURL), let db = try? JSONDecoder().decode(DB.self, from: d) {
            feeds = db.feeds
            states = db.states
        }
        rebuildIndex()
    }

    static func key(_ feed: PodcastFeed, _ ep: PodcastEpisode) -> String { feed.feedURL + "#" + ep.id }

    func state(_ feed: PodcastFeed, _ ep: PodcastEpisode) -> EpisodeState { states[Self.key(feed, ep)] ?? EpisodeState() }

    private func folder(_ feed: PodcastFeed) -> URL {
        let name = String(feed.feedURL.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) } & 0xFFFFFFF, radix: 16)
        let u = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Local file if downloaded, else the remote enclosure.
    func playableURL(_ feed: PodcastFeed, _ ep: PodcastEpisode) -> URL? {
        if let f = state(feed, ep).file {
            let u = folder(feed).appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return URL(string: ep.enclosure)
    }

    /// Feed and episode for a playlist URL (remote enclosure or downloaded file).
    func lookup(_ url: URL) -> (PodcastFeed, PodcastEpisode)? {
        for f in feeds {
            for e in f.episodes {
                if e.enclosure == url.absoluteString { return (f, e) }
                if url.isFileURL, let file = states[Self.key(f, e)]?.file, folder(f).appendingPathComponent(file).path == url.path { return (f, e) }
            }
        }
        return nil
    }

    func isEpisodeURL(_ url: URL) -> Bool {
        url.isFileURL ? url.path.hasPrefix(dir.path) : enclosures.contains(url.absoluteString)
    }

    // MARK: Mutations

    func update(_ feed: PodcastFeed, _ ep: PodcastEpisode, _ change: (inout EpisodeState) -> Void) {
        var s = state(feed, ep)
        change(&s)
        states[Self.key(feed, ep)] = s
        scheduleSave()
    }

    func setSpeed(_ feedURL: String, _ speed: Double?) {
        guard let i = feeds.firstIndex(where: { $0.feedURL == feedURL }) else { return }
        feeds[i].speed = speed
        scheduleSave()
    }

    func unsubscribe(_ feed: PodcastFeed) {
        try? FileManager.default.removeItem(at: folder(feed))
        feeds.removeAll { $0.feedURL == feed.feedURL }
        states = states.filter { !$0.key.hasPrefix(feed.feedURL + "#") }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(DB(feeds: self.feeds, states: self.states)) { try? d.write(to: self.dbURL, options: .atomic) }
        }
    }

    // MARK: Feeds

    @discardableResult
    func subscribe(_ urlString: String) async throws -> PodcastFeed {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw URLError(.badURL) }
        let fetched = try await Self.fetch(url)
        return await MainActor.run { () -> PodcastFeed in
            var feed = fetched
            if let i = self.feeds.firstIndex(where: { $0.feedURL == feed.feedURL }) {
                feed.speed = self.feeds[i].speed
                self.feeds[i] = feed
            } else {
                self.feeds.append(feed)
                self.feeds.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
            self.scheduleSave()
            return feed
        }
    }

    func refresh(_ feed: PodcastFeed) {
        refreshing.insert(feed.feedURL)
        Task {
            let updated = try? await Self.fetch(URL(string: feed.feedURL)!)
            await MainActor.run {
                self.refreshing.remove(feed.feedURL)
                guard var u = updated, let i = self.feeds.firstIndex(where: { $0.feedURL == feed.feedURL }) else { return }
                u.speed = self.feeds[i].speed
                self.feeds[i] = u
                self.scheduleSave()
            }
        }
    }

    func refreshAll() { feeds.forEach(refresh) }

    static func fetch(_ url: URL) async throws -> PodcastFeed {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw URLError(.badServerResponse) }
        guard var feed = RSSParser.parse(data) else { throw URLError(.cannotParseResponse) }
        feed.feedURL = url.absoluteString
        feed.lastRefresh = Date()
        return feed
    }

    // MARK: Apple catalogue search (iTunes Search API, free, no key)

    struct SearchResult: Decodable, Identifiable, Hashable {
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl600: String?
        let primaryGenreName: String?
        var id: String { feedUrl ?? collectionName ?? UUID().uuidString }
    }

    static func search(_ term: String) async throws -> [SearchResult] {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "term", value: term),
                        URLQueryItem(name: "limit", value: "40"),
                        URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "IT")]
        struct R: Decodable { let results: [SearchResult] }
        let (data, _) = try await URLSession.shared.data(from: c.url!)
        return try JSONDecoder().decode(R.self, from: data).results.filter { $0.feedUrl != nil }
    }

    // MARK: Downloads

    func download(_ feed: PodcastFeed, _ ep: PodcastEpisode) {
        guard let url = URL(string: ep.enclosure) else { return }
        let key = Self.key(feed, ep)
        guard downloads[key] == nil else { return }
        var req = URLRequest(url: url)
        req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        taskKeys[task.taskIdentifier] = key
        downloads[key] = 0
        task.resume()
    }

    func deleteDownload(_ feed: PodcastFeed, _ ep: PodcastEpisode) {
        if let f = state(feed, ep).file { try? FileManager.default.removeItem(at: folder(feed).appendingPathComponent(f)) }
        update(feed, ep) { $0.file = nil }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let key = taskKeys[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }
        downloads[key] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = taskKeys[downloadTask.taskIdentifier],
              let (feed, ep) = feeds.lazy.compactMap({ f in f.episodes.first { Self.key(f, $0) == key }.map { (f, $0) } }).first else { return }
        let ext = (URL(string: ep.enclosure)?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp3"
        let safe = ep.id.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) } & 0xFFFFFFFF
        let name = "\(String(safe, radix: 16)).\(ext)"
        let dest = folder(feed).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            update(feed, ep) { $0.file = name }
        } catch {}
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let key = taskKeys.removeValue(forKey: task.taskIdentifier) { downloads[key] = nil }
    }

    // MARK: OPML

    func exportOPML(to url: URL) throws {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n<head><title>MusicAmp podcasts</title></head>\n<body>\n"
        for f in feeds { s += "  <outline type=\"rss\" text=\"\(esc(f.title))\" title=\"\(esc(f.title))\" xmlUrl=\"\(esc(f.feedURL))\"/>\n" }
        s += "</body>\n</opml>\n"
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Feed URLs from an OPML export of any podcast app.
    static func opmlFeeds(_ data: Data) -> [String] {
        final class P: NSObject, XMLParserDelegate {
            var urls: [String] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                if name.lowercased() == "outline", let u = attributes["xmlUrl"] ?? attributes["xmlurl"] { urls.append(u) }
            }
        }
        let p = P()
        let x = XMLParser(data: data)
        x.delegate = p
        x.parse()
        return p.urls
    }
}

/// RSS 2.0 + iTunes podcast namespace.
final class RSSParser: NSObject, XMLParserDelegate {
    private var feed = PodcastFeed(feedURL: "", title: "")
    private var item: PodcastEpisode?
    private var text = ""
    private var inImage = false

    static func parse(_ data: Data) -> PodcastFeed? {
        let p = RSSParser()
        let x = XMLParser(data: data)
        x.delegate = p
        x.shouldProcessNamespaces = false
        guard x.parse() || !p.feed.episodes.isEmpty, !p.feed.title.isEmpty || !p.feed.episodes.isEmpty else { return nil }
        p.feed.episodes.sort { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        return p.feed
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        text = ""
        switch name {
        case "item": item = PodcastEpisode(id: "", title: "", enclosure: "")
        case "image": inImage = true
        case "enclosure":
            item?.enclosure = attributes["url"] ?? ""
            item?.length = Int(attributes["length"] ?? "")
        case "itunes:image":
            if let h = attributes["href"] { if item != nil { item?.imageURL = h } else { feed.artworkURL = h } }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { text += String(data: data, encoding: .utf8) ?? "" }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if item != nil {
            switch name {
            case "title": item?.title = t
            case "guid": item?.id = t
            case "pubDate": item?.pubDate = Self.date(t)
            case "itunes:duration": item?.duration = Self.duration(t)
            case "itunes:summary", "description":
                if item?.summary == nil || name == "itunes:summary" { item?.summary = Self.plain(t) }
            case "item":
                if var it = item, !it.enclosure.isEmpty {
                    if it.id.isEmpty { it.id = it.enclosure }
                    feed.episodes.append(it)
                }
                item = nil
            default: break
            }
        } else {
            switch name {
            case "title" where !inImage && feed.title.isEmpty: feed.title = t
            case "itunes:author": feed.author = t
            case "url" where inImage && feed.artworkURL == nil: feed.artworkURL = t
            case "image": inImage = false
            case "description", "itunes:summary": if feed.summary == nil { feed.summary = Self.plain(t) }
            default: break
            }
        }
        text = ""
    }

    /// "1:02:03", "62:03" or seconds.
    static func duration(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                    "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func plain(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Remembers where you stopped in long files (audiobooks, podcasts, files over 20 minutes).
final class PlaybackPositions {
    static let shared = PlaybackPositions()
    private var positions: [String: Double]
    private var saveScheduled = false

    private var url: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("positions.json")
    }

    private init() {
        positions = [:]
        if let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([String: Double].self, from: d) { positions = p }
    }

    static func key(_ u: URL) -> String { u.isFileURL ? u.path : u.absoluteString }

    /// Audiobook formats always; other files when they are at least 20 minutes long.
    static func remembers(_ url: URL, duration: Double) -> Bool {
        ["m4b", "aa", "aax"].contains(url.pathExtension.lowercased()) || duration >= 20 * 60
    }

    func position(_ url: URL) -> Double? { positions[Self.key(url)] }

    func set(_ url: URL, _ t: Double?) {
        positions[Self.key(url)] = t
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            if let d = try? JSONEncoder().encode(self.positions) { try? d.write(to: self.url, options: .atomic) }
        }
    }
}
