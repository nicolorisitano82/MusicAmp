import AppKit
import SwiftUI

extension Ctl {
    @objc func showSmartPlaylists() {
        if smartWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SmartPlaylistsView(store: .shared, stats: .shared)))
            w.title = "Smart Playlists"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 980, height: 620))
            w.contentMinSize = NSSize(width: 820, height: 480)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("SmartPlaylists")
            smartWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        smartWindowRef?.makeKeyAndOrderFront(nil)
    }
}

struct SmartPlaylistsView: View {
    @ObservedObject var store: SmartPlaylistStore
    @ObservedObject var stats: PlayStats
    @State private var selection: SmartPlaylist.ID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.playlists) { p in
                    Label(p.name, systemImage: "gearshape.2").tag(p.id)
                }
                .onMove { store.playlists.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 4) {
                    Button { add() } label: { Image(systemName: "plus") }.help("New smart playlist")
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil).help("Delete")
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.disabled(selection == nil).help("Duplicate")
                    Spacer()
                    Menu {
                        Button("Add Missing Default Playlists") { restoreDefaults() }
                        Button("Forget Tracks Whose Files Are Gone") { _ = stats.removeMissing() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            if let i = store.playlists.firstIndex(where: { $0.id == selection }) {
                SmartPlaylistEditor(playlist: $store.playlists[i], store: store, stats: stats)
                    .id(store.playlists[i].id)
            } else {
                Text("Select or create a smart playlist").foregroundStyle(.secondary)
            }
        }
        .onAppear { if selection == nil { selection = store.playlists.first?.id } }
    }

    private func add() {
        let p = SmartPlaylist()
        store.playlists.append(p)
        selection = p.id
    }

    private func remove() {
        guard let i = store.playlists.firstIndex(where: { $0.id == selection }) else { return }
        store.playlists.remove(at: i)
        selection = store.playlists.indices.contains(i) ? store.playlists[i].id : store.playlists.last?.id
    }

    private func duplicate() {
        guard let p = store.playlists.first(where: { $0.id == selection }) else { return }
        var copy = p
        copy.id = UUID()
        copy.name += " copy"
        store.playlists.append(copy)
        selection = copy.id
    }

    private func restoreDefaults() {
        let names = Set(store.playlists.map(\.name))
        store.playlists += SmartPlaylist.defaults.filter { !names.contains($0.name) }
    }
}

private struct SmartPlaylistEditor: View {
    @Binding var playlist: SmartPlaylist
    let store: SmartPlaylistStore
    @ObservedObject var stats: PlayStats
    @State private var results: [SmartItem] = []
    @State private var tableSelection = Set<SmartItem.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $playlist.name).font(.title3).textFieldStyle(.plain)
            HStack {
                Text("Match")
                Picker("", selection: $playlist.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden().fixedSize()
                Text("of the following rules:")
            }
            VStack(spacing: 6) {
                ForEach($playlist.rules) { $rule in
                    RuleRow(rule: $rule,
                            remove: { playlist.rules.removeAll { $0.id == rule.id } },
                            add: { if let i = playlist.rules.firstIndex(where: { $0.id == rule.id }) { playlist.rules.insert(SmartRule(), at: i + 1) } })
                }
                if playlist.rules.isEmpty {
                    Button("Add Rule") { playlist.rules.append(SmartRule()) }
                }
            }
            HStack {
                Toggle("Limit to", isOn: Binding(get: { playlist.limit > 0 }, set: { playlist.limit = $0 ? 25 : 0 }))
                TextField("", value: $playlist.limit, format: .number.locale(HeadphonesTab.numbers)).frame(width: 60).disabled(playlist.limit == 0)
                Text("tracks")
                Spacer().frame(width: 20)
                Picker("Order", selection: $playlist.order) {
                    ForEach(SmartPlaylist.Order.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                Spacer()
                Toggle("Only files that exist", isOn: $playlist.onlyExisting)
            }
            Divider()
            Table(results, selection: $tableSelection) {
                TableColumn("Title") { Text($0.title).lineLimit(1) }
                TableColumn("Artist") { Text($0.stats.artist ?? "").lineLimit(1) }
                TableColumn("Album") { Text($0.stats.album ?? "").lineLimit(1) }
                TableColumn("Rating") { it in StarsView(rating: stats.rating(it.url)) { stats.setRating(it.url, $0); refresh() } }
                    .width(86)
                TableColumn("Plays") { Text("\($0.stats.plays)").monospacedDigit() }.width(42)
                TableColumn("Last Played") { Text($0.stats.lastPlayed.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—") }.width(100)
            }
            .contextMenu(forSelectionType: SmartItem.ID.self) { ids in
                Button("Play") { play(ids) }
                Button("Add to Playlist") { add(ids) }
            } primaryAction: { ids in play(ids) }
            HStack {
                Text("\(results.count) tracks · \(Ctl.hmmss(results.reduce(0) { $0 + ($1.stats.duration ?? 0) }))")
                    .foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Refresh") { refresh() }
                Button("Add to Playlist") { _ = MainActor.assumeIsolated { store.play(playlist, append: true) } }.disabled(results.isEmpty)
                Button("Play") { _ = MainActor.assumeIsolated { store.play(playlist) } }.keyboardShortcut(.defaultAction).disabled(results.isEmpty)
            }
        }
        .padding(16)
        .onAppear(perform: refresh)
        .onChange(of: playlist) { refresh() }
    }

    private func refresh() { results = store.tracks(playlist) }

    private func urls(_ ids: Set<SmartItem.ID>) -> [URL] { results.filter { ids.contains($0.id) }.map(\.url) }
    private func play(_ ids: Set<SmartItem.ID>) { let u = urls(ids); if !u.isEmpty { Ctl.shared.replacePlaylist(u, play: true) } }
    private func add(_ ids: Set<SmartItem.ID>) { Ctl.shared.playlist.add(urls(ids)) }
}

private struct RuleRow: View {
    @Binding var rule: SmartRule
    let remove: () -> Void
    let add: () -> Void

    var body: some View {
        HStack {
            Picker("", selection: Binding(get: { rule.field }, set: { rule.field = $0; rule.fixOp() })) {
                ForEach(SmartRule.Field.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            Picker("", selection: $rule.op) {
                ForEach(SmartRule.Op.ops(for: rule.field.kind)) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 180)
            switch rule.field.kind {
            case .text: TextField("", text: $rule.text)
            case .number, .date: TextField("", value: $rule.number, format: .number.locale(HeadphonesTab.numbers)).frame(width: 80)
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            Button(action: add) { Image(systemName: "plus.circle") }.buttonStyle(.borderless)
        }
    }
}

/// Five clickable stars; clicking the current rating clears it.
struct StarsView: View {
    let rating: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                Image(systemName: n <= rating ? "star.fill" : "star")
                    .font(.system(size: 10))
                    .foregroundStyle(n <= rating ? Color.accentColor : Color.secondary.opacity(0.5))
                    .onTapGesture { set(n == rating ? 0 : n) }
            }
        }
    }
}
