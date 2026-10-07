import AppKit
import SwiftUI

/// A station from the radio-browser.info community directory.
struct RadioStation: Codable, Identifiable, Hashable {
    let stationuuid: String
    let name: String
    let url: String
    let url_resolved: String?
    let homepage: String?
    let favicon: String?
    let tags: String?
    let country: String?
    let countrycode: String?
    let codec: String?
    let bitrate: Int?
    let hls: Int?
    let votes: Int?
    let clickcount: Int?
    let lastcheckok: Int?

    var id: String { stationuuid }
    var streamURL: URL? { URL(string: (url_resolved?.isEmpty == false ? url_resolved : url) ?? url) }
    var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var format: String {
        let c = (codec ?? "").uppercased()
        let fmt = hls == 1 ? "HLS" : (c.isEmpty || c == "UNKNOWN" ? "—" : c)
        return (bitrate ?? 0) > 0 ? "\(fmt) \(bitrate!) kbps" : fmt
    }
    /// What MusicAmp can play: ICY MP3/AAC (through the engine, with EQ) or HLS (AVPlayer).
    var playable: Bool {
        if hls == 1 { return true }
        let c = (codec ?? "").uppercased()
        if ["OGG", "OPUS", "FLAC"].contains(c) { return FFmpeg.available }
        return ["MP3", "AAC", "AAC+", "UNKNOWN", ""].contains(c)
    }
}

/// radio-browser.info API: free, keyless; asks clients to send a User-Agent and to report plays via /json/url.
final class RadioDirectory: ObservableObject {
    static let shared = RadioDirectory()

    enum Source: Hashable {
        case top, country(String), votes, tag(String), favorites, search
    }

    static let genres = ["pop", "rock", "dance", "jazz", "classical", "news", "talk", "electronic", "hits",
                         "80s", "90s", "chillout", "lounge", "hiphop", "indie", "ambient", "italian", "soundtrack"]

    @Published private(set) var stations: [RadioStation] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var favorites: [RadioStation] = []
    private var server: String?
    private var request = 0

    private init() {
        favorites = (UserDefaults.standard.data(forKey: "radioFavorites")).flatMap { try? JSONDecoder().decode([RadioStation].self, from: $0) } ?? []
    }

    func isFavorite(_ s: RadioStation) -> Bool { favorites.contains { $0.id == s.id } }

    func toggleFavorite(_ s: RadioStation) {
        if isFavorite(s) { favorites.removeAll { $0.id == s.id } } else { favorites.append(s) }
        UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: "radioFavorites")
        objectWillChange.send()
    }

    /// Picks a mirror from the published server list (falls back to de1).
    private func base() async -> String {
        if let server { return server }
        var req = URLRequest(url: URL(string: "https://all.api.radio-browser.info/json/servers")!, timeoutInterval: 8)
        req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
        struct Server: Decodable { let name: String }
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let list = try? JSONDecoder().decode([Server].self, from: data),
           let pick = list.map(\.name).filter({ !$0.isEmpty }).randomElement() {
            server = "https://\(pick)"
        } else {
            server = "https://de1.api.radio-browser.info"
        }
        return server!
    }

    func load(_ source: Source, query: String = "") {
        request += 1
        let r = request
        if source == .favorites {
            stations = favorites
            error = nil
            return
        }
        loading = true
        error = nil
        Task {
            var items = [URLQueryItem(name: "hidebroken", value: "true"), URLQueryItem(name: "limit", value: "300")]
            let path: String
            switch source {
            case .top: path = "/json/stations/topclick/300"; items = [URLQueryItem(name: "hidebroken", value: "true")]
            case .votes: path = "/json/stations/topvote/300"; items = [URLQueryItem(name: "hidebroken", value: "true")]
            case .country(let cc):
                path = "/json/stations/search"
                items += [URLQueryItem(name: "countrycode", value: cc), URLQueryItem(name: "order", value: "clickcount"),
                          URLQueryItem(name: "reverse", value: "true")]
            case .tag(let t):
                path = "/json/stations/search"
                items += [URLQueryItem(name: "tag", value: t), URLQueryItem(name: "order", value: "clickcount"),
                          URLQueryItem(name: "reverse", value: "true")]
            case .search:
                path = "/json/stations/search"
                items += [URLQueryItem(name: "name", value: query), URLQueryItem(name: "order", value: "clickcount"),
                          URLQueryItem(name: "reverse", value: "true")]
            case .favorites: return
            }
            var comps = URLComponents(string: await base() + path)!
            comps.queryItems = items
            var req = URLRequest(url: comps.url!, timeoutInterval: 15)
            req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
            let result: Result<[RadioStation], Error>
            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                result = .success(try JSONDecoder().decode([RadioStation].self, from: data))
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard r == self.request else { return }
                self.loading = false
                switch result {
                case .success(let list): self.stations = list.filter { $0.playable && $0.lastcheckok != 0 }
                case .failure(let e):
                    self.error = e.localizedDescription
                    self.server = nil   // try another mirror next time
                }
            }
        }
    }

    /// Reports the play to radio-browser (its click counter) and returns the freshest stream URL.
    func resolve(_ s: RadioStation) async -> URL? {
        var req = URLRequest(url: URL(string: await base() + "/json/url/\(s.stationuuid)")!, timeoutInterval: 8)
        req.setValue(RadioStream.userAgent, forHTTPHeaderField: "User-Agent")
        struct Click: Decodable { let ok: Bool?; let url: String? }
        if let (data, _) = try? await URLSession.shared.data(for: req),
           let c = try? JSONDecoder().decode(Click.self, from: data), let u = c.url, let url = URL(string: u) {
            return url
        }
        return s.streamURL
    }
}

extension Ctl {
    @objc func showRadio() {
        if radioWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: RadioView(ctl: self, dir: .shared)))
            w.title = "Radio"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 860, height: 520))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MusicAmpRadio")
            radioWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        radioWindowRef?.makeKeyAndOrderFront(nil)
    }

    func playStation(_ s: RadioStation, play: Bool = true) {
        Task {
            let url = await RadioDirectory.shared.resolve(s)
            await MainActor.run {
                guard let url else { NSSound.beep(); return }
                self.addStream(url, title: s.cleanName, play: play)
            }
        }
    }
}

struct RadioView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var dir: RadioDirectory
    @State private var source: RadioDirectory.Source? = .country(Locale.current.region?.identifier ?? "IT")
    @State private var query = ""
    @State private var selection = Set<RadioStation.ID>()

    private var home: String { Locale.current.region?.identifier ?? "IT" }
    private var homeName: String { Locale.current.localizedString(forRegionCode: home) ?? home }

    private func selected(_ ids: Set<RadioStation.ID>) -> [RadioStation] { dir.stations.filter { ids.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $source) {
                Section("Stazioni") {
                    Label("In evidenza", systemImage: "star.circle").tag(RadioDirectory.Source.top)
                    Label(homeName, systemImage: "flag").tag(RadioDirectory.Source.country(home))
                    Label("Più votate", systemImage: "hand.thumbsup").tag(RadioDirectory.Source.votes)
                    Label("Preferiti (\(dir.favorites.count))", systemImage: "heart").tag(RadioDirectory.Source.favorites)
                    if source == .search { Label("Risultati ricerca", systemImage: "magnifyingglass").tag(RadioDirectory.Source.search) }
                }
                Section("Generi") {
                    ForEach(RadioDirectory.genres, id: \.self) { g in
                        Label(g.prefix(1).uppercased() + g.dropFirst(), systemImage: "music.note").tag(RadioDirectory.Source.tag(g))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                Table(dir.stations, selection: $selection) {
                    TableColumn("") { s in Image(systemName: dir.isFavorite(s) ? "heart.fill" : "heart").foregroundStyle(dir.isFavorite(s) ? .pink : .secondary) }
                        .width(18)
                    TableColumn("Stazione") { s in Text(s.cleanName) }
                    TableColumn("Paese") { s in Text(s.country ?? "") }.width(min: 60, ideal: 110)
                    TableColumn("Formato") { s in Text(s.format) }.width(min: 70, ideal: 100)
                    TableColumn("Generi") { s in Text((s.tags ?? "").split(separator: ",").prefix(3).joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: RadioStation.ID.self) { ids in
                    Button("Ascolta") { selected(ids).first.map { ctl.playStation($0) } }
                    Button("Aggiungi alla playlist") { selected(ids).forEach { ctl.playStation($0, play: false) } }
                    Button("Aggiungi o togli dai preferiti") { selected(ids).forEach(dir.toggleFavorite) }
                    Divider()
                    Button("Copia indirizzo dello stream") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selected(ids).compactMap { $0.streamURL?.absoluteString }.joined(separator: "\n"), forType: .string)
                    }
                    if let home = selected(ids).first?.homepage, let u = URL(string: home), !home.isEmpty {
                        Button("Apri il sito della radio") { NSWorkspace.shared.open(u) }
                    }
                } primaryAction: { ids in
                    selected(ids).first.map { ctl.playStation($0) }
                }
                footer
            }
        }
        .onAppear { dir.load(source ?? .top) }
        .onChange(of: source) { s in if let s, s != .search { selection = []; dir.load(s) } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca una radio per nome", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        source = .search
                        dir.load(.search, query: query)
                    }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .frame(maxWidth: 320)
            Spacer()
            Button { selected(selection).first.map { ctl.playStation($0) } } label: { Label("Ascolta", systemImage: "play.fill") }
                .disabled(selection.isEmpty)
            Button { selected(selection).forEach(dir.toggleFavorite) } label: { Label("Preferito", systemImage: "heart") }
                .disabled(selection.isEmpty)
            Button { ctl.openURL() } label: { Label("Apri URL…", systemImage: "link") }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if dir.loading { ProgressView().controlSize(.small) }
            Text("\(dir.stations.count) stazioni").monospacedDigit()
            if let e = dir.error { Text("· \(e)").foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text("Catalogo: radio-browser.info").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
