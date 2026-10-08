import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Ctl {
    /// Tag editor (⌥⌘I) for the selected playlist tracks (or the current one).
    @MainActor @objc func showTagEditor() {
        let idx = playlist.selection.isEmpty ? (playlist.current.map { [$0] } ?? []) : playlist.selection.sorted()
        let urls = idx.compactMap { playlist.tracks.indices.contains($0) ? playlist.tracks[$0].url : nil }.filter(\.isFileURL)
        guard !urls.isEmpty else { NSSound.beep(); return }
        let model = TagEditorModel(urls: urls, ctl: self)
        let host = NSHostingController(rootView: TagEditorView(model: model))
        if let w = tagEditorWindowRef {
            w.contentViewController = host
        } else {
            let w = NSWindow(contentViewController: host)
            w.title = "Tag Editor"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 270 + TagEditorView.formMinWidth + 40, height: 620))
            w.contentMinSize = NSSize(width: 270 + TagEditorView.formMinWidth, height: 540)
            w.setFrameAutosaveName("MusicAmpTagEditor")
            tagEditorWindowRef = w
        }
        tagEditorWindowRef?.title = urls.count == 1 ? "Tags — \(urls[0].lastPathComponent)" : "Tags — \(urls.count) files"
        NSApp.activate(ignoringOtherApps: true)
        tagEditorWindowRef?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class TagEditorModel: ObservableObject {
    struct File: Identifiable {
        var id: URL { url }
        let url: URL
        var tags = TagSet()
        var loaded = false
        var included = true
        var error: String?
        var writable: Bool { TagIO.canWrite(url) }
    }

    @Published var files: [File]
    /// Pending changes for all included files; per-file values (track numbering) win over them.
    @Published var edits: [WritableKeyPath<TagSet, String>: String] = [:]
    @Published var perFile: [URL: [WritableKeyPath<TagSet, String>: String]] = [:]
    @Published var artwork: TagUpdate.Artwork = .keep
    @Published var saving = false
    @Published var message: String?
    weak var ctl: Ctl?

    init(urls: [URL], ctl: Ctl) {
        self.ctl = ctl
        files = urls.map { File(url: $0) }
        Task { await load() }
    }

    func load() async {
        for i in files.indices {
            let t = await TagIO.read(files[i].url)
            files[i].tags = t
            files[i].loaded = true
        }
    }

    var included: [File] { files.filter(\.included) }
    var hasChanges: Bool { !edits.isEmpty || !perFile.isEmpty || artwork != .keep }

    /// The value all included files share, nil when they differ.
    func common(_ k: WritableKeyPath<TagSet, String>) -> String? {
        let vals = Set(included.map { perFile[$0.url]?[k] ?? $0.tags[keyPath: k] })
        return vals.count <= 1 ? (vals.first ?? "") : nil
    }

    func isMixed(_ k: WritableKeyPath<TagSet, String>) -> Bool { edits[k] == nil && common(k) == nil }

    func binding(_ k: WritableKeyPath<TagSet, String>) -> Binding<String> {
        Binding(get: { self.edits[k] ?? self.common(k) ?? "" },
                set: { v in
                    self.edits[k] = v
                    for u in self.perFile.keys { self.perFile[u]?[k] = nil }   // a shared value replaces per-file ones
                })
    }

    /// Artwork shown: the pending one, or the one all included files share (nil + mixed when they differ).
    var shownArtwork: (data: Data?, mixed: Bool) {
        switch artwork {
        case .set(let d): return (d, false)
        case .remove: return (nil, false)
        case .keep:
            let arts = included.map(\.tags.artwork)
            guard let first = arts.first else { return (nil, false) }
            return arts.allSatisfy { $0 == first } ? (first, false) : (nil, true)
        }
    }

    // MARK: Batch tools

    /// Track numbers 1…n in list order, with the total.
    func autoNumber() {
        let inc = included
        for (i, f) in inc.enumerated() {
            perFile[f.url, default: [:]][\.track] = "\(i + 1)"
            perFile[f.url, default: [:]][\.trackTotal] = "\(inc.count)"
        }
        edits[\.track] = nil
        edits[\.trackTotal] = nil
    }

    func albumArtistFromArtist() {
        for f in included { perFile[f.url, default: [:]][\.albumArtist] = perFile[f.url]?[\.artist] ?? edits[\.artist] ?? f.tags.artist }
        edits[\.albumArtist] = nil
    }

    func revert() {
        edits = [:]
        perFile = [:]
        artwork = .keep
        message = nil
    }

    func setArtwork(from url: URL) {
        guard let d = try? Data(contentsOf: url), NSImage(data: d) != nil else { message = "Invalid image"; return }
        artwork = .set(Self.normalized(d))
    }

    func pasteArtwork() {
        let pb = NSPasteboard.general
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff), NSImage(data: d) != nil { artwork = .set(Self.normalized(d)) }
        else if let img = NSImage(pasteboard: pb), let t = img.tiffRepresentation { artwork = .set(Self.normalized(t)) }
        else { message = "There’s no image on the clipboard" }
    }

    /// JPEG and PNG are kept as they are; anything else (TIFF from the clipboard, HEIC…) becomes JPEG.
    static func normalized(_ d: Data) -> Data {
        let mime = TagIO.imageMIME(d)
        let b = [UInt8](d.prefix(3))
        if mime == "image/png" || b.starts(with: [0xFF, 0xD8, 0xFF]) { return d }
        guard let rep = NSBitmapImageRep(data: d), let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return d }
        return jpg
    }

    // MARK: Save

    func save() {
        let targets = included.filter(\.writable)
        let skipped = included.count - targets.count
        guard hasChanges, !targets.isEmpty else { return }
        saving = true
        message = nil
        let edits = self.edits, perFile = self.perFile, artwork = self.artwork
        Task {
            var errors: [String] = []
            for f in targets {
                var up = TagUpdate()
                up.fields = edits.merging(perFile[f.url] ?? [:]) { _, file in file }
                up.artwork = artwork
                do { try await TagIO.write(f.url, up) } catch {
                    errors.append("\(f.url.lastPathComponent): \(error.localizedDescription)")
                    if let i = files.firstIndex(where: { $0.url == f.url }) { files[i].error = error.localizedDescription }
                }
            }
            // Reload what was written and refresh the playlist, covers and Now Playing.
            for i in files.indices where targets.contains(where: { $0.url == files[i].url }) {
                files[i].tags = await TagIO.read(files[i].url)
            }
            ctl?.tagsChanged(Set(targets.map(\.url)))
            saving = false
            self.edits = [:]
            self.perFile = [:]
            self.artwork = .keep
            let saved = targets.count - errors.count
            var parts = ["Saved \(saved) \(saved == 1 ? "file" : "files")"]
            if skipped > 0 { parts.append("\(skipped) read-only skipped") }
            if !errors.isEmpty { parts.append("\(errors.count) \(errors.count == 1 ? "error" : "errors"): " + errors.joined(separator: "; ")) }
            message = parts.joined(separator: " · ")
        }
    }
}

extension Ctl {
    /// After the tag editor wrote files: reload those tracks' metadata and forget their cached covers.
    @MainActor func tagsChanged(_ urls: Set<URL>) {
        for t in playlist.tracks where urls.contains(t.url) {
            Artwork.forget(t.url)
            playlist.reloadMetadata(t)
        }
        DockIcon.shared.coverChanged(urls)
    }
}

struct TagEditorView: View {
    @ObservedObject var model: TagEditorModel
    @State private var dropping = false
    @State private var lookingUp = false

    static let genres = ["Alternative", "Ambient", "Blues", "Classical", "Soundtrack", "Country", "Dance", "Electronic", "Folk",
                         "Hip-Hop", "Indie", "Jazz", "Latin", "Metal", "Pop", "Punk", "R&B", "Rap", "Reggae", "Rock", "Singer-Songwriter",
                         "Soul", "Techno", "Podcast", "Audiobook"]

    /// Labels (~110) + fields (≥ 300) + artwork column (200) + spacing and padding.
    static let formMinWidth: CGFloat = 720

    var body: some View {
        HStack(spacing: 0) {
            fileList.frame(width: 270)
            Divider()
            VStack(spacing: 0) {
                // Vertical-only scrolling, content pinned to the leading edge: a too-wide form used to be
                // centred and clipped on both sides (labels on the left, artwork on the right).
                ScrollView(.vertical) {
                    editor
                        .padding(.vertical, 20).padding(.leading, 20).padding(.trailing, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
            .frame(minWidth: TagEditorView.formMinWidth)
        }
        .frame(minWidth: 270 + TagEditorView.formMinWidth, minHeight: 540)
        .sheet(isPresented: $lookingUp) { TagLookupView(editor: model) }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(spacing: 0) {
            List {
                ForEach($model.files) { $f in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $f.included).labelsHidden().toggleStyle(.checkbox).disabled(model.saving)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.tags.title.isEmpty ? f.url.deletingPathExtension().lastPathComponent : f.tags.title).lineLimit(1)
                            Text([f.tags.artist, f.url.lastPathComponent].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let n = model.perFile[f.url]?[\.track] ?? (f.tags.track.isEmpty ? nil : f.tags.track) {
                            Text(n).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(f.url.pathExtension.uppercased()).font(.caption2.bold())
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
                        if !f.writable { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Tags are read-only for this format") }
                        if f.error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(f.error ?? "") }
                    }
                }
                .onMove { from, to in model.files.move(fromOffsets: from, toOffset: to) }
            }
            HStack {
                Button("All") { for i in model.files.indices { model.files[i].included = true } }
                Button("None") { for i in model.files.indices { model.files[i].included = false } }
                Spacer()
                Text("\(model.included.count)/\(model.files.count)").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless).padding(8)
        }
    }

    // MARK: Fields

    private var editor: some View {
        HStack(alignment: .top, spacing: 22) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                field("Title", \.title)
                field("Artist", \.artist)
                field("Album", \.album)
                field("Album Artist", \.albumArtist)
                GridRow {
                    label("Genre")
                    HStack(spacing: 4) {
                        textField(\.genre)
                        Menu {
                            ForEach(Self.genres, id: \.self) { g in Button(g) { model.binding(\.genre).wrappedValue = g } }
                        } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                    }
                }
                GridRow {
                    label("Year")
                    textField(\.year).frame(width: 90)
                }
                GridRow {
                    label("Track")
                    HStack(spacing: 6) {
                        textField(\.track).frame(width: 64)
                        Text("of").foregroundStyle(.secondary).fixedSize()
                        textField(\.trackTotal).frame(width: 64)
                        Text("Disc").foregroundStyle(.secondary).fixedSize().padding(.leading, 14)
                        textField(\.disc).frame(width: 50)
                        Text("of").foregroundStyle(.secondary).fixedSize()
                        textField(\.discTotal).frame(width: 50)
                        Spacer(minLength: 0)
                    }
                }
                GridRow(alignment: .top) {
                    label("Comment").padding(.top, 4)
                    TextEditor(text: model.binding(\.comment))
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 110)
                        .overlay(alignment: .topLeading) {
                            if model.isMixed(\.comment) { Text("Mixed values").foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false) }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    HStack {
                        Button("Number Tracks") { model.autoNumber() }
                            .help("Track 1…n and total for the included files, in the order shown on the left (drag to reorder)")
                        Button("Album Artist = Artist") { model.albumArtistFromArtist() }
                        Button("Look Up Online…") { lookingUp = true }
                            .disabled(model.included.isEmpty)
                            .help("Find this album on MusicBrainz and fill in tags and cover (review, then Save)")
                    }
                    .controlSize(.small)
                }
            }
            artworkPanel
        }
        .disabled(model.saving)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            .gridColumnAlignment(.trailing)   // the column takes the widest label
    }

    private func textField(_ k: WritableKeyPath<TagSet, String>) -> some View {
        let narrow = [\TagSet.year, \.track, \.trackTotal, \.disc, \.discTotal].contains(k)
        return TextField(model.isMixed(k) ? (narrow ? "mixed" : "Mixed values") : "", text: model.binding(k))
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if model.edits[k] != nil || model.perFile.values.contains(where: { $0[k] != nil }) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.trailing, 6).help("Modified")
                }
            }
    }

    private func field(_ title: String, _ k: WritableKeyPath<TagSet, String>) -> some View {
        GridRow {
            label(title)
            textField(k)
        }
    }

    // MARK: Artwork

    private var artworkPanel: some View {
        let shown = model.shownArtwork
        return VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                if let d = shown.data, let img = NSImage(data: d) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: shown.mixed ? "square.stack" : "photo").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(shown.mixed ? "Mixed artwork" : "No artwork").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if dropping { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3) }
            }
            .frame(width: 190, height: 190)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                if p.canLoadObject(ofClass: URL.self) {
                    _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { Task { @MainActor in model.setArtwork(from: u) } } }
                } else {
                    _ = p.loadDataRepresentation(for: .image) { d, _ in
                        if let d { Task { @MainActor in model.artwork = .set(TagEditorModel.normalized(d)) } }
                    }
                }
                return true
            }
            if let d = shown.data, let img = NSImage(data: d) {
                Text("\(Int(img.size.width))×\(Int(img.size.height)) · \(TagIO.imageMIME(d).replacingOccurrences(of: "image/", with: "").uppercased()) · \(d.count / 1024) KB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.allowedContentTypes = [.image]
                    if p.runModal() == .OK, let u = p.url { model.setArtwork(from: u) }
                }
                Button("Paste") { model.pasteArtwork() }
            }
            HStack {
                Button("Remove") { model.artwork = .remove }.disabled(shown.data == nil && !shown.mixed)
                Button("Export…") {
                    guard let d = shown.data else { return }
                    let p = NSSavePanel()
                    p.nameFieldStringValue = "cover." + (TagIO.imageMIME(d) == "image/png" ? "png" : "jpg")
                    if p.runModal() == .OK, let u = p.url { try? d.write(to: u) }
                }
                .disabled(shown.data == nil)
            }
            if model.artwork != .keep {
                Text(model.artwork == .remove ? "Will be removed" : "Will be replaced").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .frame(width: 200)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if model.saving { ProgressView().controlSize(.small) }
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            else if model.included.contains(where: { !$0.writable }) {
                Text("Files with a lock can’t be edited (read-only format).").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert Changes") { model.revert() }.disabled(!model.hasChanges || model.saving)
            Button(model.included.filter(\.writable).count == 1 ? "Save 1 File" : "Save \(model.included.filter(\.writable).count) Files") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.hasChanges || model.saving || !model.included.contains(where: \.writable))
        }
        .padding(12)
    }
}

// MARK: - Online lookup (MusicBrainz)

/// State of the "Look Up Online…" sheet. It only fills the editor's pending changes: nothing is written until Save.
@MainActor
final class TagLookupModel: ObservableObject {
    struct Row: Identifiable {
        var id: URL { url }
        let url: URL
        let track: MusicBrainz.Track?
        let fileLength: Double?
        /// File and recording lengths differ by more than 5 s: probably the wrong track.
        var mismatch: Bool {
            guard let a = fileLength, let b = track?.length else { return false }
            return abs(a - b) > 5
        }
    }

    let editor: TagEditorModel
    /// Included files when the sheet opened, in list order.
    let files: [TagEditorModel.File]
    @Published var album: String
    @Published var artist: String
    @Published var results: [MusicBrainz.ReleaseSummary] = []
    @Published var selection: String?
    @Published var release: MusicBrainz.Release?
    @Published var mapping: (indices: [Int?], byNumber: Bool) = ([], false)
    @Published var durations: [URL: Double] = [:]
    @Published var includeCover = true
    @Published var busy: String?
    @Published var error: String?
    private var releaseTask: Task<Void, Never>?

    init(editor: TagEditorModel) {
        self.editor = editor
        files = editor.included
        func value(_ k: WritableKeyPath<TagSet, String>) -> String { editor.edits[k] ?? editor.common(k) ?? "" }
        album = value(\.album)
        artist = value(\.albumArtist).isEmpty ? value(\.artist) : value(\.albumArtist)
        Task {
            for f in files { if let d = await MusicBrainz.duration(of: f.url) { durations[f.url] = d } }
        }
    }

    /// The file's current value, pending edits included.
    private func current(_ f: TagEditorModel.File, _ k: WritableKeyPath<TagSet, String>) -> String {
        editor.perFile[f.url]?[k] ?? editor.edits[k] ?? f.tags[keyPath: k]
    }

    var rows: [Row] {
        files.enumerated().map { i, f in
            let idx = mapping.indices.indices.contains(i) ? mapping.indices[i] : nil
            return Row(url: f.url, track: idx.flatMap { release?.tracks[$0] }, fileLength: durations[f.url])
        }
    }

    func search() {
        guard !album.trimmingCharacters(in: .whitespaces).isEmpty || !artist.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        releaseTask?.cancel()
        busy = "Searching…"
        error = nil
        results = []
        selection = nil
        release = nil
        let album = album, artist = artist
        Task {
            do {
                results = try await MusicBrainz.search(album: album, artist: artist)
                if results.isEmpty { error = "No results" }
            } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    /// Fetches the selected release and maps the files onto its tracks.
    func select(_ id: String?) {
        releaseTask?.cancel()
        release = nil
        guard let id else { return }
        busy = "Loading release…"
        error = nil
        releaseTask = Task {
            do {
                let r = try await MusicBrainz.release(id)
                guard !Task.isCancelled else { return }
                mapping = MusicBrainz.mapFiles(files.map { (current($0, \.track), current($0, \.disc)) }, to: r.tracks)
                release = r
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }

    /// Fills the editor: album-wide values into `edits`, per-track values into `perFile`, the cover into `artwork`.
    func apply() async {
        guard let r = release else { return }
        let ed = editor
        func shared(_ k: WritableKeyPath<TagSet, String>, _ v: String) {
            guard !v.isEmpty else { return }
            ed.edits[k] = v
            for u in ed.perFile.keys { ed.perFile[u]?[k] = nil }   // as when typing a shared value
        }
        shared(\.album, r.title)
        shared(\.albumArtist, r.artist)
        shared(\.year, r.year)
        shared(\.genre, r.genre)
        shared(\.discTotal, "\(r.discCount)")
        for k in [\TagSet.title, \.artist, \.track, \.trackTotal, \.disc] { ed.edits[k] = nil }
        for row in rows {
            guard let t = row.track else { continue }
            ed.perFile[row.url, default: [:]].merge([\.title: t.title, \.artist: t.artist, \.track: "\(t.position)",
                                                     \.trackTotal: "\(t.discTrackCount)", \.disc: "\(t.disc)"]) { _, new in new }
        }
        var note = "Filled from MusicBrainz — review, then Save"
        if includeCover {
            busy = "Downloading cover…"
            let rg = results.first { $0.id == r.id }?.releaseGroupID ?? r.releaseGroupID
            if let d = await MusicBrainz.cover(release: r.id, releaseGroup: rg) { ed.artwork = .set(TagEditorModel.normalized(d)) }
            else { note += " (no cover found)" }
            busy = nil
        }
        ed.message = note
    }
}

struct TagLookupView: View {
    @StateObject private var lookup: TagLookupModel
    @Environment(\.dismiss) private var dismiss

    init(editor: TagEditorModel) { _lookup = StateObject(wrappedValue: TagLookupModel(editor: editor)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Look Up on MusicBrainz").font(.headline)
            HStack {
                TextField("Album", text: $lookup.album).onSubmit { lookup.search() }
                TextField("Artist", text: $lookup.artist).onSubmit { lookup.search() }.frame(width: 220)
                Button("Search") { lookup.search() }
            }
            .textFieldStyle(.roundedBorder)
            List(lookup.results, selection: $lookup.selection) { r in resultRow(r) }
                .frame(height: 210)
            preview.frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                if let b = lookup.busy { ProgressView().controlSize(.small); Text(b).font(.caption).foregroundStyle(.secondary) }
                else if let e = lookup.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Toggle("Include cover", isOn: $lookup.includeCover).toggleStyle(.checkbox)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") { Task { await lookup.apply(); dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lookup.release == nil || lookup.busy != nil)
            }
        }
        .padding(16)
        .frame(width: 860, height: 640)
        .onChange(of: lookup.selection) { lookup.select($1) }
        .onAppear { if !lookup.album.isEmpty { lookup.search() } }
    }

    private func resultRow(_ r: MusicBrainz.ReleaseSummary) -> some View {
        let matches = r.trackCount == lookup.files.count
        return HStack(spacing: 10) {
            CoverThumbnail(release: r.id).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title + (r.disambiguation.isEmpty ? "" : " (\(r.disambiguation))")).lineLimit(1)
                Text(r.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text([r.date, r.country, r.format, r.status == "Official" ? "" : r.status].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("\(r.trackCount) tracks")
                .font(.caption.monospacedDigit().weight(matches ? .bold : .regular))
                .foregroundStyle(matches ? Color.green : Color.secondary)
                .help(matches ? "Same number of tracks as the selected files" : "")
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .tag(r.id)
    }

    @ViewBuilder private var preview: some View {
        if let r = lookup.release {
            VStack(alignment: .leading, spacing: 6) {
                Text([r.title, r.artist, r.year, r.genre, r.discCount > 1 ? "\(r.discCount) discs" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout.bold()).lineLimit(1)
                Text(lookup.mapping.byNumber ? "Files matched by their track numbers" : "Files matched in list order (drag files on the left to reorder)")
                    .font(.caption).foregroundStyle(.secondary)
                Table(lookup.rows) {
                    TableColumn("File") { row in Text(row.url.lastPathComponent).lineLimit(1) }
                    TableColumn("Track") { row in Text(row.track.map { "\($0.position)/\($0.discTrackCount)" } ?? "—").monospacedDigit() }
                        .width(50)
                    TableColumn("Disc") { row in Text(row.track.map { "\($0.disc)/\(r.discCount)" } ?? "—").monospacedDigit() }
                        .width(40)
                    TableColumn("Title") { row in Text(row.track?.title ?? "No matching track").lineLimit(1).foregroundStyle(row.track == nil ? .secondary : .primary) }
                    TableColumn("Artist") { row in Text(row.track?.artist ?? "").lineLimit(1) }
                    TableColumn("Length") { row in
                        HStack(spacing: 3) {
                            if row.mismatch { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            Text("\(Self.time(row.fileLength)) / \(Self.time(row.track?.length))").monospacedDigit()
                        }
                        .help(row.mismatch ? "File and track lengths differ by more than 5 seconds" : "File length / MusicBrainz length")
                    }
                    .width(min: 100, ideal: 110)
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06))
                Text(lookup.results.isEmpty ? "Search for the album, then pick a release" : "Select a release to preview the tags")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func time(_ s: Double?) -> String {
        guard let s else { return "–" }
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Cover Art Archive thumbnail, loaded lazily; a placeholder when the release has none.
private struct CoverThumbnail: View {
    let release: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).clipShape(RoundedRectangle(cornerRadius: 4)) }
            else { Image(systemName: "opticaldisc").foregroundStyle(.tertiary) }
        }
        .task(id: release) {
            image = await MusicBrainz.thumbnail(release: release).flatMap(NSImage.init(data:))
        }
    }
}
