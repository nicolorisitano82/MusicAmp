import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Ctl {
    @objc func showPodcasts() {
        if podcastWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PodcastView(ctl: self, store: .shared)))
            w.title = "Podcast"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 920, height: 560))
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MusicAmpPodcasts")
            podcastWindowRef = w
            PodcastStore.shared.refreshAll()
        }
        NSApp.activate(ignoringOtherApps: true)
        podcastWindowRef?.makeKeyAndOrderFront(nil)
    }
}

struct PodcastView: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var store: PodcastStore
    @State private var selectedFeed: String?
    @State private var selection = Set<PodcastEpisode.ID>()
    @State private var showAdd = false

    private var feed: PodcastFeed? { store.feeds.first { $0.feedURL == selectedFeed } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedFeed) {
                ForEach(store.feeds) { f in
                    HStack(spacing: 8) {
                        Cover(url: f.artworkURL, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.title).lineLimit(1)
                            Text("\(unplayed(f)) da ascoltare").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(f.feedURL)
                    .contextMenu {
                        Button("Aggiorna") { store.refresh(f) }
                        Button("Disiscriviti") { store.unsubscribe(f); if selectedFeed == f.feedURL { selectedFeed = nil } }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { showAdd = true } label: { Label("Aggiungi", systemImage: "plus") }
                    Spacer()
                    Button { store.refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Aggiorna tutti")
                }
                .buttonStyle(.borderless).padding(8)
            }
        } detail: {
            if let f = feed { episodes(f) } else { empty }
        }
        .sheet(isPresented: $showAdd) { AddPodcastSheet(store: store, isPresented: $showAdd) }
        .onAppear { if selectedFeed == nil { selectedFeed = store.feeds.first?.feedURL } }
    }

    private func unplayed(_ f: PodcastFeed) -> Int { f.episodes.filter { !store.state(f, $0).played }.count }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Nessun podcast").font(.title3)
            Text("Cerca nel catalogo Apple, incolla l'URL di un feed o importa un OPML da un'altra app.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
            Button("Aggiungi un podcast…") { showAdd = true }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func episodes(_ f: PodcastFeed) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Cover(url: f.artworkURL, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.title).font(.title3.bold()).lineLimit(1)
                    if let a = f.author { Text(a).foregroundStyle(.secondary).lineLimit(1) }
                    Text(f.summary ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("Velocità", selection: Binding(get: { f.speed ?? ctl.podcastSpeed },
                                                         set: { store.setSpeed(f.feedURL, $0); ctl.applySpeed() })) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5], id: \.self) { v in Text(String(format: "%.2g×", v)).tag(v) }
                    }
                    .frame(width: 150)
                    if store.refreshing.contains(f.feedURL) { ProgressView().controlSize(.small) }
                }
            }
            .padding(12)
            Divider()
            Table(f.episodes, selection: $selection) {
                TableColumn("") { e in statusIcon(f, e) }.width(22)
                TableColumn("Episodio") { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).lineLimit(1).fontWeight(store.state(f, e).played ? .regular : .semibold)
                        if let s = e.summary, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                TableColumn("Data") { e in Text(e.pubDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "") }.width(min: 70, ideal: 95)
                TableColumn("Durata") { e in Text(remaining(f, e)) }.width(min: 60, ideal: 90)
            }
            .contextMenu(forSelectionType: PodcastEpisode.ID.self) { ids in
                let eps = f.episodes.filter { ids.contains($0.id) }
                Button("Ascolta") { eps.first.map { ctl.playEpisode(f, $0) } }
                Button("Aggiungi alla playlist") { eps.forEach { ctl.playEpisode(f, $0, play: false) } }
                Divider()
                Button("Scarica") { eps.forEach { store.download(f, $0) } }
                Button("Elimina download") { eps.forEach { store.deleteDownload(f, $0) } }
                Divider()
                Button("Segna come ascoltato") { eps.forEach { e in store.update(f, e) { $0.played = true; $0.position = 0 } } }
                Button("Segna come da ascoltare") { eps.forEach { e in store.update(f, e) { $0.played = false } } }
            } primaryAction: { ids in
                f.episodes.first { ids.contains($0.id) }.map { ctl.playEpisode(f, $0) }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ f: PodcastFeed, _ e: PodcastEpisode) -> some View {
        let s = store.state(f, e)
        if let p = store.downloads[PodcastStore.key(f, e)] {
            ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).help("Download \(Int(p * 100))%")
        } else if s.played {
            Image(systemName: "checkmark").foregroundStyle(.secondary).help("Ascoltato")
        } else if s.position > 5 {
            Image(systemName: "circle.lefthalf.filled").foregroundStyle(.tint).help("In corso")
        } else if s.file != nil {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.secondary).help("Scaricato")
        } else {
            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.tint).help("Nuovo")
        }
    }

    /// "45:12", or "restano 12:03" when partly heard.
    private func remaining(_ f: PodcastFeed, _ e: PodcastEpisode) -> String {
        guard let d = e.duration, d > 0 else { return "" }
        let s = store.state(f, e)
        return s.position > 5 && !s.played ? "restano " + Ctl.hmmss(d - s.position) : Ctl.hmmss(d)
    }
}

/// Cached cover image from a URL.
struct Cover: View {
    let url: String?
    let size: CGFloat
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { img in
            img.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Image(systemName: "mic.fill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }
}

struct AddPodcastSheet: View {
    @ObservedObject var store: PodcastStore
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var results: [PodcastStore.SearchResult] = []
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aggiungi un podcast").font(.headline)
            HStack {
                TextField("Cerca per nome, oppure incolla l'URL del feed RSS", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button("Cerca", action: go).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List(results) { r in
                HStack(spacing: 10) {
                    Cover(url: r.artworkUrl600, size: 40)
                    VStack(alignment: .leading) {
                        Text(r.collectionName ?? "").lineLimit(1)
                        Text([r.artistName, r.primaryGenreName].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if store.feeds.contains(where: { $0.feedURL == r.feedUrl }) {
                        Text("Iscritto").foregroundStyle(.secondary)
                    } else {
                        Button("Iscriviti") { subscribe(r.feedUrl ?? "") }
                    }
                }
            }
            .frame(minHeight: 260)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let m = message { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button("Importa OPML…", action: importOPML)
                Button("Esporta OPML…", action: exportOPML).disabled(store.feeds.isEmpty)
                Button("Chiudi") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
            Text("Ricerca: catalogo podcast di Apple (iTunes Search API).").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 600, height: 460)
    }

    private func go() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if q.hasPrefix("http") { subscribe(q); return }
        busy = true
        message = nil
        Task {
            let r = try? await PodcastStore.search(q)
            await MainActor.run {
                busy = false
                results = r ?? []
                message = r == nil ? "Ricerca non riuscita" : (r!.isEmpty ? "Nessun risultato" : nil)
            }
        }
    }

    private func subscribe(_ url: String) {
        busy = true
        message = nil
        Task {
            do {
                let f = try await store.subscribe(url)
                await MainActor.run { busy = false; message = "Iscritto a \(f.title) (\(f.episodes.count) episodi)" }
            } catch {
                await MainActor.run { busy = false; message = "Feed non valido: \(error.localizedDescription)" }
            }
        }
    }

    private func importOPML() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "opml"), .xml].compactMap { $0 }
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        let urls = PodcastStore.opmlFeeds(d)
        busy = true
        message = "Importo \(urls.count) podcast…"
        Task {
            var ok = 0
            for u in urls { if (try? await store.subscribe(u)) != nil { ok += 1 } }
            await MainActor.run { busy = false; message = "Importati \(ok) di \(urls.count) podcast" }
        }
    }

    private func exportOPML() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "MusicAmp-podcast.opml"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try store.exportOPML(to: u); message = "Esportati \(store.feeds.count) podcast" } catch { message = error.localizedDescription }
    }
}
