import AppKit
import Combine
import SwiftUI

extension Ctl {
    @objc func showSonicMix() { openSonicMix(seed: nil, destination: nil) }

    /// Opens the Sonic Mix window, optionally starting from a track (and travelling to another one).
    func openSonicMix(seed: URL?, destination: URL?) {
        let model = SonicMixModel.shared
        if let seed { model.seed = seed }
        model.destination = destination
        model.mode = destination == nil ? .radio : .journey
        if sonicWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SonicMixView(model: model, store: .shared)))
            w.title = L("Sonic Mix")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 760, height: 600))
            w.contentMinSize = NSSize(width: 640, height: 460)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SonicMix")
            sonicWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        sonicWindowRef?.makeKeyAndOrderFront(nil)
        model.prepare()
    }

    /// Replaces the playlist with a mix. When the mix starts with the track already playing, that track keeps
    /// playing and the rest follows it; otherwise the mix starts from the top.
    func startMix(_ urls: [URL], title: String) {
        guard let first = urls.first else { return }
        if let t = playlist.currentTrack, t.url == first, audio.state != .stopped {
            playlist.clear()
            playlist.add(urls)
            if let i = playlist.tracks.firstIndex(where: { $0.url == first }) { playlist.currentTrack = playlist.tracks[i] }
            invalidateTransition()
            plView.needsDisplay = true
        } else {
            replacePlaylist(urls, play: true)
        }
        flashMarquee(title.uppercased())
    }

    @objc func sonicRadioFromSelection() {
        guard let i = playlist.selection.min() ?? playlist.current, playlist.tracks.indices.contains(i) else { return }
        openSonicMix(seed: playlist.tracks[i].url, destination: nil)
    }

    @objc func sonicJourneyToSelection() {
        guard let from = playlist.currentTrack?.url, let i = playlist.selection.min(), playlist.tracks.indices.contains(i) else { return }
        openSonicMix(seed: from, destination: playlist.tracks[i].url)
    }
}

final class SonicMixModel: ObservableObject {
    static let shared = SonicMixModel()
    enum Mode: String, CaseIterable, Identifiable { case radio = "Sonic Radio", journey = "Sonic Journey", similar = "Similar Tracks"; var id: String { rawValue } }

    @Published var mode: Mode = .radio { didSet { if mode != oldValue { build() } } }
    @Published var seed: URL? { didSet { if seed != oldValue { build() } } }
    @Published var destination: URL? { didSet { if destination != oldValue { build() } } }
    @Published var length = 25 { didSet { if length != oldValue { build() } } }
    /// Radio and Similar keep only tracks of this mood ("" = any).
    @Published var mood = "" { didSet { if mood != oldValue { build() } } }
    @Published private(set) var results: [(SonicSpace.Track, Float)] = []
    @Published private(set) var message: String?
    private var space = SonicSpace(items: [])
    private var progressWatch: AnyCancellable?

    init() {
        // While the library is being analysed, refresh the mix as tracks come in (not on every one).
        progressWatch = SonicStore.shared.$progress
            .throttle(for: .seconds(1.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in if SonicStore.shared.analyzing { self?.build() } }
    }

    /// Everything MusicAmp knows (play statistics, Music library) plus the playlist.
    var pool: [SmartItem] {
        var items = Dictionary(SmartPlaylistStore.pool().map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for t in Ctl.shared.playlist.tracks {
            guard let k = PlayStats.key(t.url), items[k] == nil else { continue }
            var e = PlayStats.Entry()
            e.title = t.songTitle ?? t.title; e.artist = t.artist; e.album = t.album; e.duration = t.duration
            items[k] = SmartItem(key: k, url: t.url, stats: e)
        }
        return items.values.filter { FileManager.default.fileExists(atPath: CueSheet.audioURL($0.url).path) }
    }

    /// Analyses what isn't yet, then builds the mix.
    func prepare() {
        if seed == nil { seed = Ctl.shared.playlist.currentTrack.flatMap { $0.isStream ? nil : $0.url } }
        let items = pool
        SonicStore.shared.analyze(items.map(\.url)) { [weak self] in self?.build() }
        build()
    }

    func build() {
        space = SonicSpace(items: pool)
        if !mood.isEmpty, mode != .journey { space = space.keeping { $0.f.mood == mood || $0.item.url == seed } }
        guard let s = seed else { results = []; message = "Play a track, or choose one in the playlist and pick “Sonic Radio from This Track”."; return }
        guard let st = space.track(s) else {
            results = []
            message = SonicStore.shared.analyzing ? "Analysing the library…" : "This track can't be analysed (stream, missing file or unsupported format)."
            return
        }
        if SonicStore.shared.analyzing {
            message = "Mixing from the \(space.tracks.count) tracks analysed so far; the rest join as they're analysed."
        } else {
            message = space.tracks.count < 8 ? "Only \(space.tracks.count) tracks analysed so far: add more music for better mixes." : nil
        }
        switch mode {
        case .radio:
            let r = space.radio(from: st, count: length)
            results = r.map { ($0, SonicSpace.distance(st, $0)) }
        case .similar:
            results = [(st, 0)] + space.similar(to: st, count: length)
        case .journey:
            guard let d = destination, let dt = space.track(d) else {
                results = []
                message = "Choose where the journey goes: select a track in the playlist and pick “Sonic Journey to This Track”, or pick one below."
                return
            }
            let j = space.journey(from: st, to: dt, steps: max(1, length - 2))
            results = zip(j, j.indices).map { t, i in (t, i == 0 ? 0 : SonicSpace.distance(j[i - 1], t)) }
        }
    }

    func reshuffle() { build() }

    var urls: [URL] { results.map(\.0.item.url) }
    var allTracks: [SonicSpace.Track] { space.tracks.sorted { $0.item.title.localizedCaseInsensitiveCompare($1.item.title) == .orderedAscending } }
}

struct SonicMixView: View {
    @ObservedObject var model: SonicMixModel
    @ObservedObject var store: SonicStore
    @State private var pickingDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $model.mode) { ForEach(SonicMixModel.Mode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                Spacer()
                if model.mode != .journey {
                    Picker("Mood", selection: $model.mood) {
                        Text("Any mood").tag("")
                        ForEach(SonicFeatures.moods, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                }
                Stepper("\(model.length) tracks", value: $model.length, in: 5...100, step: 5).fixedSize()
            }
            seedRow
            if model.mode == .journey { destinationRow }
            if store.analyzing {
                HStack {
                    ProgressView(value: Double(store.progress.done), total: Double(max(1, store.progress.total)))
                    Text("Analysing \(store.progress.done)/\(store.progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stop") { store.cancel() }.controlSize(.small)
                }
            }
            if let m = model.message { Text(m).font(.callout).foregroundStyle(.secondary) }
            Table(model.results.enumerated().map { SonicRow($0.offset + 1, $0.element.0, $0.element.1) }) {
                TableColumn("#") { Text("\($0.index)").monospacedDigit().foregroundStyle(.secondary) }.width(28)
                TableColumn("Title") { Text($0.title).lineLimit(1) }
                TableColumn("Artist") { Text($0.artist).lineLimit(1) }
                TableColumn("BPM") { Text($0.bpm).monospacedDigit() }.width(44)
                TableColumn("Key") { Text($0.key) }.width(44)
                TableColumn("Mood") { Text($0.mood).lineLimit(1) }.width(80)
                TableColumn("Instruments") { Text($0.style).lineLimit(1).foregroundStyle(.secondary) }
                TableColumn(model.mode == .journey ? "Step" : "Match") { r in
                    HStack(spacing: 4) {
                        ProgressView(value: Double(r.match), total: 100).frame(width: 50)
                        Text("\(r.match)%").monospacedDigit().font(.caption)
                    }
                }.width(100)
            }
            HStack {
                Text("Analysis on this Mac: timbre, key, tempo, energy, mood (estimated) and instruments of 45 s of each track.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.mode == .radio { Button("Shuffle Again") { model.reshuffle() } }
                Button("Add to Playlist") { Ctl.shared.playlist.add(model.urls) }.disabled(model.results.isEmpty)
                Button("Play") { Ctl.shared.startMix(model.urls, title: model.mode.rawValue) }
                .keyboardShortcut(.defaultAction).disabled(model.results.isEmpty)
            }
        }
        .padding(16)
        .sheet(isPresented: $pickingDestination) { TrackPicker(model: model, isPresented: $pickingDestination) }
    }

    private var seedRow: some View {
        HStack(spacing: 8) {
            Text(model.mode == .journey ? "From" : "Seed").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            trackLabel(model.seed)
            Spacer()
            Button("Use Current Track") { model.seed = Ctl.shared.playlist.currentTrack.flatMap { $0.isStream ? nil : $0.url } }
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Text("To").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            trackLabel(model.destination)
            Spacer()
            Button("Choose…") { pickingDestination = true }
        }
    }

    @ViewBuilder private func trackLabel(_ url: URL?) -> some View {
        if let url, let f = store.feature(for: url) {
            let t = Ctl.shared.playlist.tracks.first { $0.url == url }
            Text([t?.artist, t?.songTitle ?? t?.title ?? url.deletingPathExtension().lastPathComponent].compactMap { $0 }.joined(separator: " — "))
                .fontWeight(.medium).lineLimit(1)
            Text("\(Int(f.bpm.rounded())) BPM · \(f.keyName)").font(.caption).foregroundStyle(.secondary)
        } else if let url {
            Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
            Text("not analysed yet").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }
}

private struct SonicRow: Identifiable {
    let id: String
    let index: Int
    let title: String
    let artist: String
    let bpm: String
    let key: String
    let mood: String
    let style: String
    let match: Int

    init(_ index: Int, _ t: SonicSpace.Track, _ d: Float) {
        id = t.item.key
        self.index = index
        title = t.item.title
        artist = t.item.stats.artist ?? ""
        bpm = t.f.bpm > 0 ? "\(Int(t.f.bpm.rounded()))" : "—"
        key = t.f.keyName
        mood = t.f.mood ?? ""
        style = (t.f.style ?? []).joined(separator: ", ")
        match = SonicSpace.similarity(d)
    }
}

/// Searchable list of analysed tracks, for the journey's destination.
private struct TrackPicker: View {
    @ObservedObject var model: SonicMixModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection: String?

    var body: some View {
        let words = query.lowercased().split(separator: " ")
        let tracks = model.allTracks.filter { t in
            let hay = "\(t.item.title) \(t.item.stats.artist ?? "") \(t.item.stats.album ?? "")".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        VStack(alignment: .leading, spacing: 10) {
            Text("Journey to…").font(.headline)
            TextField("Search title, artist or album", text: $query).textFieldStyle(.roundedBorder)
            List(tracks, id: \.item.key, selection: $selection) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.item.title)
                    Text([t.item.stats.artist, "\(Int(t.f.bpm.rounded())) BPM", t.f.keyName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(t.item.key)
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Choose") {
                    if let k = selection, let t = tracks.first(where: { $0.item.key == k }) { model.destination = t.item.url }
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}
