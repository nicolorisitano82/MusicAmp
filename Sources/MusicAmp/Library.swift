import AppKit
import SwiftUI
import iTunesLibrary

struct LibrarySong: Identifiable, Hashable {
    let id: String
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let trackNumber: Int
}

struct LibraryPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let songIDs: [String]
}

/// Two sources: the Music app library (iTunesLibrary framework, local files only) and a scan of ~/Music.
final class MusicLibrary: ObservableObject {
    static let shared = MusicLibrary()

    enum Source: Hashable { case music, folder, playlist(String) }

    @Published private(set) var musicSongs: [LibrarySong] = []
    @Published private(set) var playlists: [LibraryPlaylist] = []
    @Published private(set) var folderSongs: [LibrarySong] = []
    @Published private(set) var cloudOnly = 0
    @Published private(set) var musicError: String?
    @Published private(set) var loading = false
    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        reload()
    }

    func reload() {
        loaded = true
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let music = Self.readMusicLibrary()
            let folder = Self.scanMusicFolder()
            DispatchQueue.main.async {
                switch music {
                case .success(let r):
                    self.musicSongs = r.songs
                    self.playlists = r.playlists
                    self.cloudOnly = r.cloudOnly
                    self.musicError = nil
                case .failure(let e):
                    self.musicError = e.localizedDescription
                }
                self.folderSongs = folder
                self.loading = false
            }
        }
    }

    func songs(for source: Source) -> [LibrarySong] {
        switch source {
        case .music: return musicSongs
        case .folder: return folderSongs
        case .playlist(let id):
            guard let p = playlists.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(musicSongs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return p.songIDs.compactMap { byID[$0] }
        }
    }

    private static func readMusicLibrary() -> Result<(songs: [LibrarySong], playlists: [LibraryPlaylist], cloudOnly: Int), Error> {
        do {
            let lib = try ITLibrary(apiVersion: "1.1")
            var songs: [LibrarySong] = []
            var cloud = 0
            for item in lib.allMediaItems where item.mediaKind == .kindSong {
                guard let url = item.location, item.locationType == .file else { cloud += 1; continue }
                songs.append(LibrarySong(
                    id: item.persistentID.stringValue, url: url, title: item.title,
                    artist: item.artist?.name ?? item.album.albumArtist ?? "", album: item.album.title ?? "",
                    duration: item.totalTime > 0 ? Double(item.totalTime) / 1000 : nil, trackNumber: item.trackNumber))
            }
            let playable = Set(songs.map(\.id))
            let lists = lib.allPlaylists
                .filter { $0.isVisible && !$0.isPrimary && $0.kind != .folder && $0.distinguishedKind == .kindNone }
                .map { LibraryPlaylist(id: $0.persistentID.stringValue, name: $0.name,
                                       songIDs: $0.items.map { $0.persistentID.stringValue }.filter(playable.contains)) }
                .filter { !$0.songIDs.isEmpty }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return .success((songs, lists, cloud))
        } catch {
            return .failure(error)
        }
    }

    /// ~/Music without the Music app's own package; "Artist - Album" folder names give artist and album.
    private static func scanMusicFolder() -> [LibrarySong] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [LibrarySong] = []
        for case let u as URL in en {
            let name = u.lastPathComponent
            if name.hasSuffix(".musiclibrary") || name == "Media.localized" || name == "Previous Libraries.localized" {
                en.skipDescendants()
                continue
            }
            guard Playlist.audioExtensions.contains(u.pathExtension.lowercased()) else { continue }
            let folder = u.deletingLastPathComponent().lastPathComponent
            let parts = folder.components(separatedBy: " - ")
            var title = u.deletingPathExtension().lastPathComponent
            var number = 0
            if let r = title.range(of: #"^\d{1,3}[\.\-\s]+"#, options: .regularExpression) {
                number = Int(title[r].filter(\.isNumber)) ?? 0
                title.removeSubrange(r)
            }
            out.append(LibrarySong(id: u.path, url: u, title: title,
                                   artist: parts.count > 1 ? parts[0] : "",
                                   album: parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : folder,
                                   duration: nil, trackNumber: number))
        }
        return out.sorted { ($0.artist, $0.album, $0.trackNumber, $0.title) < ($1.artist, $1.album, $1.trackNumber, $1.title) }
    }
}

extension Ctl {
    @objc func showLibrary() {
        if libraryWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LibraryView(ctl: self, lib: .shared)))
            w.title = L("Library")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 860, height: 520))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MusicAmpLibrary")
            libraryWindowRef = w
        }
        MusicLibrary.shared.loadIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        libraryWindowRef?.makeKeyAndOrderFront(nil)
    }

    func playSongs(_ songs: [LibrarySong], startAt: Int = 0) {
        guard !songs.isEmpty else { return }
        replacePlaylist(songs.map(\.url), play: false)
        playIndex(min(startAt, playlist.tracks.count - 1))
    }

    func enqueueSongs(_ songs: [LibrarySong]) {
        playlist.add(songs.map(\.url))
        flashMarquee("ADDED \(songs.count) TRACKS")
    }
}

struct LibraryView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var lib: MusicLibrary
    @State private var source: MusicLibrary.Source? = .music
    @State private var query = ""
    @State private var selection = Set<LibrarySong.ID>()
    @State private var sort = [KeyPathComparator(\LibrarySong.artist), KeyPathComparator(\LibrarySong.album),
                               KeyPathComparator(\LibrarySong.trackNumber)]

    private var rows: [LibrarySong] {
        let all = lib.songs(for: source ?? .music)
        let q = query.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
        if case .playlist = source, sort.isEmpty { return filtered }
        return filtered.sorted(using: sort)
    }

    private func selected(_ ids: Set<LibrarySong.ID>) -> [LibrarySong] { rows.filter { ids.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $source) {
                Section("Library") {
                    Label("Music (\(lib.musicSongs.count))", systemImage: "music.note.house").tag(MusicLibrary.Source.music)
                    Label("Music Folder (\(lib.folderSongs.count))", systemImage: "folder").tag(MusicLibrary.Source.folder)
                }
                if !lib.playlists.isEmpty {
                    Section("Music Playlists") {
                        ForEach(lib.playlists) { p in
                            Label(p.name, systemImage: "music.note.list").tag(MusicLibrary.Source.playlist(p.id))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                Table(rows, selection: $selection, sortOrder: $sort) {
                    TableColumn("#", value: \.trackNumber) { s in Text(s.trackNumber > 0 ? "\(s.trackNumber)" : "") }.width(28)
                    TableColumn("Title", value: \.title)
                    TableColumn("Artist", value: \.artist)
                    TableColumn("Album", value: \.album)
                    TableColumn("Duration") { s in Text(s.duration.map(Ctl.mmss) ?? "") }.width(56)
                }
                .contextMenu(forSelectionType: LibrarySong.ID.self) { ids in
                    Button("Play") { ctl.playSongs(selected(ids)) }
                    Button("Add to Playlist") { ctl.enqueueSongs(selected(ids)) }
                    Divider()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(selected(ids).map(\.url)) }
                } primaryAction: { ids in
                    // Double click: play the visible list from the clicked song, like Music.
                    let list = rows
                    if let first = list.firstIndex(where: { ids.contains($0.id) }) { ctl.playSongs(list, startAt: first) }
                }
                footer
            }
        }
        .onAppear { lib.loadIfNeeded() }
    }

    /// Search and actions inside the view: SwiftUI toolbars are not bridged into an AppKit-hosted window on macOS 13.
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Title, artist, album", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .frame(maxWidth: 320)
            Spacer()
            Button { ctl.playSongs(selection.isEmpty ? rows : selected(selection)) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .help("Play the selection, or the whole list if nothing is selected")
            Button { ctl.enqueueSongs(selection.isEmpty ? rows : selected(selection)) } label: {
                Label("Add", systemImage: "text.badge.plus")
            }
            .help("Add to Playlist")
            Button { lib.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if lib.loading { ProgressView().controlSize(.small) }
            Text("\(rows.count) tracks").monospacedDigit()
            if source == .music, lib.cloudOnly > 0 {
                Text("· \(lib.cloudOnly) only in iCloud or Apple Music, not playable").foregroundStyle(.secondary)
            }
            if source == .music, let e = lib.musicError {
                Text("· Music library unavailable: \(e)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}
