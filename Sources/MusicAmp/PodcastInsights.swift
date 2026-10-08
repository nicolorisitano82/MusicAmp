import CryptoKit
import FoundationModels
import SwiftUI

/// Smart podcasts, on this Mac: a downloaded episode is transcribed (SpeechAnalyzer), then Apple's language model
/// writes chapters, a summary with key points, and finds the ads/sponsor reads, which playback can skip.
/// Transcripts are searchable across episodes. Stored in ~/Library/Application Support/MusicAmp/Transcripts.
struct PodcastInsights: Codable, Equatable {
    struct Sentence: Codable, Equatable, Identifiable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
    }
    struct Chapter: Codable, Equatable, Identifiable {
        var id: Int { Int(start * 10) }
        var start: Double
        var title: String
        var summary: String
    }
    struct Span: Codable, Equatable { var start: Double; var end: Double }

    var feedURL: String
    var episodeID: String
    var language: String
    var sentences: [Sentence]
    var chapters: [Chapter] = []
    var summary = ""
    var keyPoints: [String] = []
    var ads: [Span] = []
    var created = Date()

    var adTime: Double { ads.reduce(0) { $0 + $1.end - $1.start } }
}

@MainActor
final class PodcastInsightsStore: ObservableObject {
    static let shared = PodcastInsightsStore()

    enum Stage: Equatable { case transcribing(Double), reading(Int, Int), summarising }
    @Published private(set) var working: [String: Stage] = [:]   // episode key → stage
    @Published private(set) var errors: [String: String] = [:]
    @Published var skipAds = UserDefaults.standard.object(forKey: "podcast.skipAds") as? Bool ?? true {
        didSet { UserDefaults.standard.set(skipAds, forKey: "podcast.skipAds") }
    }
    private var memory: [String: PodcastInsights] = [:]

    static var folder: URL {
        let u = PlayStats.file.deletingLastPathComponent().appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func key(_ feed: PodcastFeed, _ ep: PodcastEpisode) -> String {
        SHA256.hash(data: Data("\(feed.feedURL)|\(ep.id)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    func insights(_ feed: PodcastFeed, _ ep: PodcastEpisode) -> PodcastInsights? {
        let k = Self.key(feed, ep)
        if let m = memory[k] { return m }
        guard let d = try? Data(contentsOf: Self.folder.appendingPathComponent(k + ".json")),
              let i = try? JSONDecoder().decode(PodcastInsights.self, from: d) else { return nil }
        memory[k] = i
        return i
    }

    /// Every stored transcript (for search across episodes).
    func all() -> [PodcastInsights] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? JSONDecoder().decode(PodcastInsights.self, from: Data(contentsOf: $0)) }
    }

    private func save(_ i: PodcastInsights, _ k: String) {
        memory[k] = i
        if let d = try? JSONEncoder().encode(i) { try? d.write(to: Self.folder.appendingPathComponent(k + ".json"), options: .atomic) }
        objectWillChange.send()
    }

    func delete(_ feed: PodcastFeed, _ ep: PodcastEpisode) {
        let k = Self.key(feed, ep)
        memory[k] = nil
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(k + ".json"))
        objectWillChange.send()
    }

    // MARK: Pipeline

    /// Transcribe → chapters, ads and summary. The episode must be downloaded.
    func analyse(_ feed: PodcastFeed, _ ep: PodcastEpisode) {
        let k = Self.key(feed, ep)
        guard working[k] == nil else { return }
        guard let url = PodcastStore.shared.playableURL(feed, ep), url.isFileURL else {
            errors[k] = "Download the episode first: transcription works on the file."
            return
        }
        errors[k] = nil
        working[k] = .transcribing(0)
        Task {
            do {
                let lang = AI.language(of: [ep.title, ep.summary ?? "", feed.title].joined(separator: ". ")) ?? Locale.current
                let words = try await AI.transcribe(url, locale: lang) { p in Task { @MainActor in self.working[k] = .transcribing(p) } }
                var ins = PodcastInsights(feedURL: feed.feedURL, episodeID: ep.id, language: lang.identifier, sentences: Self.sentences(words))
                save(ins, k)   // the transcript is useful (searchable) even if the model part fails
                if AI.languageModelAvailable {
                    try await Self.understand(&ins) { done, total in Task { @MainActor in self.working[k] = .reading(done, total) } }
                    working[k] = .summarising
                    try await Self.summarise(&ins)
                    save(ins, k)
                } else {
                    errors[k] = (AI.unavailableReason ?? "") + " The transcript is ready; chapters and summary need Apple Intelligence."
                }
            } catch {
                errors[k] = error.localizedDescription
            }
            working[k] = nil
        }
    }

    /// Words → sentences: at sentence punctuation, at pauses of a second, or every 40 words.
    nonisolated static func sentences(_ words: [AI.Word]) -> [PodcastInsights.Sentence] {
        var out: [PodcastInsights.Sentence] = []
        var cur: [AI.Word] = []
        func flush() {
            guard let f = cur.first, let l = cur.last else { return }
            out.append(.init(id: out.count, start: f.start, end: l.end, text: cur.map(\.text).joined(separator: " ")))
            cur = []
        }
        for w in words {
            if let p = cur.last, w.start - p.end >= 1.0 { flush() }
            cur.append(w)
            if let c = w.text.last, ".?!…".contains(c) || cur.count >= 40 { flush() }
        }
        flush()
        return out
    }

    /// ~700-word blocks: a chapter title and summary each, and the sentences that are ads.
    nonisolated static func understand(_ ins: inout PodcastInsights, progress: @escaping @Sendable (Int, Int) -> Void) async throws {
        var blocks: [[PodcastInsights.Sentence]] = []
        var cur: [PodcastInsights.Sentence] = [], count = 0
        for s in ins.sentences {
            cur.append(s)
            count += s.text.split(separator: " ").count
            if count >= 700 { blocks.append(cur); cur = []; count = 0 }
        }
        if !cur.isEmpty { blocks.append(cur) }
        var chapters: [PodcastInsights.Chapter] = []
        var adIDs = Set<Int>()
        for (bi, block) in blocks.enumerated() {
            progress(bi, blocks.count)
            let session = try AI.session("""
                You read part of a podcast transcript, its sentences numbered. Give a short chapter title and a one or two \
                sentence summary of this part, in the transcript's language. List the numbers of the sentences that are \
                advertising: sponsor reads, promo codes, "this episode is brought to you by", ads for other shows or \
                products. Do not list ordinary conversation, the show's own intro or outro, or calls to subscribe.
                """)
            let numbered = block.enumerated().map { "[\($0.offset)] \($0.element.text)" }.joined(separator: "\n")
            let r = try await session.respond(to: numbered, generating: AIChunkInsight.self).content
            chapters.append(.init(start: block.first!.start, title: r.chapterTitle, summary: r.summary))
            for i in r.adSentences where block.indices.contains(i) { adIDs.insert(block[i].id) }
        }
        progress(blocks.count, blocks.count)
        // Merge neighbouring chapters with the same title.
        ins.chapters = chapters.reduce(into: []) { acc, c in if acc.last?.title.lowercased() != c.title.lowercased() { acc.append(c) } }
        // Ad sentences → spans (consecutive ones merged, gaps under 3 s bridged); single short sentences are
        // mentions, not ad breaks: a span must last 10 s.
        var spans: [PodcastInsights.Span] = []
        for s in ins.sentences where adIDs.contains(s.id) {
            if let last = spans.last, s.start - last.end < 3 { spans[spans.count - 1].end = s.end } else { spans.append(.init(start: s.start, end: s.end)) }
        }
        ins.ads = spans.filter { $0.end - $0.start >= 10 }
    }

    nonisolated static func summarise(_ ins: inout PodcastInsights) async throws {
        let session = try AI.session("You summarise a podcast episode from the summaries of its parts, in the episode's language.")
        let parts = ins.chapters.map { "\($0.title): \($0.summary)" }.joined(separator: "\n")
        let r = try await session.respond(to: parts, generating: AIEpisodeSummary.self).content
        ins.summary = r.summary
        ins.keyPoints = r.keyPoints
    }

    // MARK: Playback

    /// Called by the controller's timer: inside an ad break of the playing episode, jump past it.
    func skipAdIfNeeded(_ c: Ctl) {
        guard skipAds, c.audio.state == .playing, let (f, e) = c.currentEpisode, let ins = insights(f, e), !ins.ads.isEmpty else { return }
        let t = c.audio.currentTime
        if let ad = ins.ads.first(where: { t >= $0.start && t < $0.end - 1 }) {
            c.audio.seek(to: ad.end)
            c.flashMarquee(String(format: "SKIPPED AD (%.0f S)", ad.end - t))
        }
    }
}

// MARK: - Window

extension Ctl {
    @MainActor func showInsights(_ feed: PodcastFeed, _ ep: PodcastEpisode) {
        let view = PodcastInsightsView(feed: feed, episode: ep, store: .shared, ctl: self)
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = ep.title
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 720, height: 640))
        w.isReleasedWhenClosed = false
        insightsWindowRef = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if PodcastInsightsStore.shared.insights(feed, ep) == nil { PodcastInsightsStore.shared.analyse(feed, ep) }
    }

    /// Plays an episode from a time (search hits, chapters).
    func playEpisode(_ feed: PodcastFeed, _ ep: PodcastEpisode, at t: Double) {
        if let (f, e) = currentEpisode, f.feedURL == feed.feedURL, e.id == ep.id {
            audio.seek(to: t)
            if audio.state != .playing { play() }
            return
        }
        playEpisode(feed, ep)
        // Once the episode is loaded, go to the point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.audio.seek(to: t) }
    }
}

struct PodcastInsightsView: View {
    let feed: PodcastFeed
    let episode: PodcastEpisode
    @ObservedObject var store: PodcastInsightsStore
    let ctl: Ctl
    @State private var tab = 0
    @State private var query = ""
    @State private var everywhere = false

    var body: some View {
        let k = PodcastInsightsStore.key(feed, episode)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title).font(.title3.bold()).lineLimit(2)
                    Text(feed.title).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Skip ads", isOn: $store.skipAds).toggleStyle(.switch).controlSize(.small)
                    .help("Jump over the sponsor reads found in transcribed episodes while they play")
            }
            if let stage = store.working[k] { progress(stage) }
            if let e = store.errors[k] { Text(e).font(.callout).foregroundStyle(.orange) }
            if let ins = store.insights(feed, episode) {
                Picker("", selection: $tab) {
                    Text("Summary").tag(0); Text("Chapters").tag(1); Text("Transcript").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case 0: summary(ins)
                case 1: chapters(ins)
                default: transcript(ins)
                }
                HStack {
                    Text("\(ins.sentences.count) sentences · \(ins.chapters.count) chapters · ads \(Ctl.mmss(ins.adTime))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Analyse Again") { store.delete(feed, episode); store.analyse(feed, episode) }.disabled(store.working[k] != nil)
                }
            } else if store.working[k] == nil {
                VStack(spacing: 10) {
                    Text("Transcribe this episode on this Mac to get a summary, chapters, ad skipping and search.").foregroundStyle(.secondary)
                    Button("Transcribe and Summarise") { store.analyse(feed, episode) }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }

    @ViewBuilder private func progress(_ s: PodcastInsightsStore.Stage) -> some View {
        switch s {
        case .transcribing(let p):
            HStack { ProgressView(value: p).frame(width: 220); Text("Transcribing… \(Int(p * 100))%").font(.caption) }
        case .reading(let d, let t):
            HStack { ProgressView(value: Double(d), total: Double(max(1, t))).frame(width: 220); Text("Finding chapters and ads… \(d)/\(t)").font(.caption) }
        case .summarising:
            HStack { ProgressView().controlSize(.small); Text("Writing the summary…").font(.caption) }
        }
    }

    private func summary(_ ins: PodcastInsights) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if ins.summary.isEmpty {
                    Text("No summary yet (needs Apple Intelligence).").foregroundStyle(.secondary)
                } else {
                    Text(ins.summary).textSelection(.enabled)
                    ForEach(ins.keyPoints, id: \.self) { Label($0, systemImage: "checkmark.circle").textSelection(.enabled) }
                }
                if !ins.ads.isEmpty {
                    Divider()
                    Text("Ad breaks").font(.headline)
                    ForEach(ins.ads, id: \.start) { a in
                        Text("\(Ctl.mmss(a.start)) – \(Ctl.mmss(a.end))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chapters(_ ins: PodcastInsights) -> some View {
        List(ins.chapters) { c in
            Button { ctl.playEpisode(feed, episode, at: c.start) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(Ctl.mmss(c.start)).monospacedDigit().foregroundStyle(.secondary)
                        Text(c.title).fontWeight(.semibold)
                    }
                    Text(c.summary).font(.callout).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private struct Hit: Identifiable { let id: String; let feed: PodcastFeed; let episode: PodcastEpisode; let sentence: PodcastInsights.Sentence }

    private func transcript(_ ins: PodcastInsights) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search the transcript", text: $query).textFieldStyle(.roundedBorder)
                Toggle("All episodes", isOn: $everywhere).controlSize(.small)
            }
            List(hits(ins)) { h in
                Button { ctl.playEpisode(h.feed, h.episode, at: h.sentence.start) } label: {
                    HStack(alignment: .top) {
                        Text(Ctl.mmss(h.sentence.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            if everywhere { Text(h.episode.title).font(.caption).foregroundStyle(.secondary) }
                            Text(h.sentence.text)
                                .foregroundStyle(ins.ads.contains { h.sentence.start >= $0.start && h.sentence.start < $0.end } && h.episode.id == episode.id ? .orange : .primary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hits(_ ins: PodcastInsights) -> [Hit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        func match(_ s: String) -> Bool { words.isEmpty || words.allSatisfy { s.lowercased().contains($0) } }
        if everywhere && !words.isEmpty {
            var out: [Hit] = []
            for other in store.all() {
                guard let f = PodcastStore.shared.feeds.first(where: { $0.feedURL == other.feedURL }),
                      let e = f.episodes.first(where: { $0.id == other.episodeID }) else { continue }
                for s in other.sentences where match(s.text) { out.append(Hit(id: "\(e.id)#\(s.id)", feed: f, episode: e, sentence: s)) }
                if out.count > 500 { break }
            }
            return out
        }
        return ins.sentences.filter { match($0.text) }.map { Hit(id: "\($0.id)", feed: feed, episode: episode, sentence: $0) }
    }
}
