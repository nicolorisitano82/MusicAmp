import FoundationModels
import SwiftUI

/// "Fix Tags with Apple Intelligence…" in the tag editor: proposes artist, title, album and track number for messy
/// files from their names, folders and current tags. Track numbers come from the file name by rule (03_, 1-03, 03.);
/// the rest from Apple's on-device language model. Proposals are reviewed and only fill the editor's pending changes.
@MainActor
final class TagFixModel: ObservableObject {
    struct Row: Identifiable {
        var id: URL { url }
        let url: URL
        let current: TagSet
        var artist = "", title = "", album = "", track = ""
        var accept = true
        var done = false
        var error: String?
        var changes: Bool {
            (!artist.isEmpty && artist != current.artist) || (!title.isEmpty && title != current.title)
                || (!album.isEmpty && album != current.album) || (!track.isEmpty && track != current.track)
        }
    }

    @Published var rows: [Row]
    @Published var running = false
    @Published var message: String?
    private var task: Task<Void, Never>?

    init(files: [TagEditorModel.File]) {
        rows = files.map { Row(url: $0.url, current: $0.tags) }
    }

    func start() {
        guard !running else { return }
        guard AI.languageModelAvailable else { message = AI.unavailableReason; return }
        running = true
        message = nil
        task = Task {
            for i in rows.indices where !rows[i].done {
                if Task.isCancelled { break }
                do {
                    let g = try await TagFixModel.guess(rows[i].url, current: rows[i].current)
                    rows[i].artist = g.artist; rows[i].title = g.title; rows[i].album = g.album; rows[i].track = g.track
                    rows[i].accept = rows[i].changes
                } catch {
                    rows[i].error = error.localizedDescription
                    rows[i].accept = false
                }
                rows[i].done = true
            }
            running = false
            let n = rows.filter(\.changes).count
            message = n == 0 ? "The tags already look tidy." : "\(n) of \(rows.count) files with proposed changes."
        }
    }

    func cancel() { task?.cancel(); running = false }

    /// Puts the accepted proposals into the editor's per-file changes (nothing is written until Save).
    func apply(to editor: TagEditorModel) {
        for r in rows where r.accept && r.changes {
            var e = editor.perFile[r.url] ?? [:]
            if !r.artist.isEmpty, r.artist != r.current.artist { e[\.artist] = r.artist }
            if !r.title.isEmpty, r.title != r.current.title { e[\.title] = r.title }
            if !r.album.isEmpty, r.album != r.current.album { e[\.album] = r.album }
            if !r.track.isEmpty, r.track != r.current.track { e[\.track] = r.track }
            editor.perFile[r.url] = e
            for k in e.keys { editor.edits[k] = nil }   // per-file values for those fields
        }
    }

    struct Guess { var artist: String; var title: String; var album: String; var track: String }

    /// Track number by rule; artist, title, album by the model.
    static func guess(_ url: URL, current: TagSet) async throws -> Guess {
        let name = url.deletingPathExtension().lastPathComponent
        let session = try AI.session("""
            You tidy up music file tags. From a file name, its folders and its current tags, give the artist, the song \
            title and the album. Fix capitalisation, underscores, dashes used as separators and junk (track numbers, \
            'copy', '(1)', 'official video', bitrates, site names). Keep the original language and spelling of names. \
            Prefer existing tags only when they match the file name; when they look unrelated, trust the file name. \
            The title always comes from the file name or the title tag, never from the folder. A double underscore or \
            a slash joins two song titles ("Song A / Song B"). Never invent an album: leave it empty when unsure.

            Examples:
            file "07_wish_you_were_here(2)", folder "PinkFloyd-WYWH" → artist Pink Floyd, title Wish You Were Here, album Wish You Were Here.
            file "Bohemian Rhapsody - Queen - 128kbps mp3juice", folder "Downloads" → artist Queen, title Bohemian Rhapsody, album empty.
            file "02 la cura", folder "Franco Battiato - L'imboscata" → artist Franco Battiato, title La cura, album L'imboscata.
            file "05 in_the_flesh__the_thin_ice" → title In the Flesh? / The Thin Ice.
            """)
        let folder = url.deletingLastPathComponent()
        let prompt = """
            File name: \(name)
            Folder: \(folder.lastPathComponent)
            Parent folder: \(folder.deletingLastPathComponent().lastPathComponent)
            Current artist: \(current.artist.isEmpty ? "(none)" : current.artist)
            Current title: \(current.title.isEmpty ? "(none)" : current.title)
            Current album: \(current.album.isEmpty ? "(none)" : current.album)
            """
        let g = try await session.respond(to: prompt, generating: AITagGuess.self).content
        return Guess(artist: g.artist.trimmingCharacters(in: .whitespaces), title: g.title.trimmingCharacters(in: .whitespaces),
                     album: g.album.trimmingCharacters(in: .whitespaces),
                     track: trackNumber(name) ?? (current.track.isEmpty ? "" : current.track))
    }

    /// "03 - Song", "03_song", "1-03 Song" (disc-track), "03. Song" → "3".
    static func trackNumber(_ name: String) -> String? {
        let patterns = [#"^\d{1,2}-(\d{1,3})[\s._-]"#, #"^(\d{1,3})[\s._-]"#]
        for p in patterns {
            if let r = name.range(of: p, options: .regularExpression) {
                let m = String(name[r])
                let digits = m.split(whereSeparator: { !$0.isNumber })
                if let last = digits.last, let n = Int(last), n > 0, n < 400 { return String(n) }
            }
        }
        return nil
    }
}

struct TagFixView: View {
    @ObservedObject var fix: TagFixModel
    let editor: TagEditorModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "apple.intelligence").foregroundStyle(.tint)
                Text("Fix Tags with Apple Intelligence").font(.headline)
                Spacer()
                if fix.running { ProgressView().controlSize(.small) }
            }
            Text("Proposals from the file names, folders and current tags, made on this Mac. Review them: only the ticked rows go into the editor, and nothing is written until you Save.")
                .font(.caption).foregroundStyle(.secondary)
            Table($fix.rows) {
                TableColumn("") { $r in Toggle("", isOn: $r.accept).labelsHidden().disabled(!r.changes) }.width(24)
                TableColumn("File") { $r in Text(r.url.lastPathComponent).lineLimit(1).foregroundStyle(.secondary) }
                TableColumn("#") { $r in field($r.track, r.current.track, done: r.done) }.width(40)
                TableColumn("Artist") { $r in field($r.artist, r.current.artist, done: r.done) }
                TableColumn("Title") { $r in field($r.title, r.current.title, done: r.done) }
                TableColumn("Album") { $r in field($r.album, r.current.album, done: r.done) }
            }
            .frame(minHeight: 300)
            HStack {
                if let m = fix.message { Text(m).font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { fix.cancel(); isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Apply") { fix.apply(to: editor); isPresented = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(fix.running || !fix.rows.contains { $0.accept && $0.changes })
            }
        }
        .padding(16)
        .frame(width: 900, height: 520)
        .onAppear { fix.start() }
    }

    /// Editable proposal; highlighted when it differs from the current tag.
    @ViewBuilder private func field(_ value: Binding<String>, _ current: String, done: Bool) -> some View {
        if !done {
            Text(current.isEmpty ? "…" : current).foregroundStyle(.tertiary).lineLimit(1)
        } else {
            TextField("", text: value)
                .textFieldStyle(.plain)
                .fontWeight(value.wrappedValue != current && !value.wrappedValue.isEmpty ? .semibold : .regular)
                .foregroundStyle(value.wrappedValue != current && !value.wrappedValue.isEmpty ? Color.accentColor : .primary)
                .help(current.isEmpty ? "No current value" : "Current: \(current)")
        }
    }
}
