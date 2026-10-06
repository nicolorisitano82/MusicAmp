import AppKit
import SwiftUI

extension Ctl {
    func binding<T>(_ kp: ReferenceWritableKeyPath<Ctl, T>) -> Binding<T> {
        Binding(get: { self[keyPath: kp] }, set: { self[keyPath: kp] = $0 })
    }

    /// Binding for settings whose change needs a side effect (window resize, level, ...).
    func toggleBinding(_ kp: KeyPath<Ctl, Bool>, _ toggle: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { self[keyPath: kp] }, set: { if $0 != self[keyPath: kp] { toggle() } })
    }

    @objc func showPreferences() {
        if prefsWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(ctl: self)))
            w.title = "Preferenze MusicAmp"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindowRef = w
        }
        prefsWindowRef?.level = alwaysOnTop ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        prefsWindowRef?.makeKeyAndOrderFront(nil)
    }

    /// Renders the main window of `skin` for the preview in the Skin tab.
    func previewImage(_ skin: Skin) -> NSImage? {
        let v = MainView(frame: .zero)
        v.previewSkin = skin
        guard let r = Renderer(width: 275, height: 116, skin: skin) else { return nil }
        v.render(r)
        guard let img = r.image() else { return nil }
        return NSImage(cgImage: img, size: NSSize(width: 275, height: 116))
    }
}

struct PreferencesView: View {
    @ObservedObject var ctl: Ctl

    var body: some View {
        TabView {
            GeneralTab(ctl: ctl).tabItem { Label("Generale", systemImage: "gearshape") }
            AudioTab(ctl: ctl).tabItem { Label("Audio", systemImage: "hifispeaker") }
            VisTab(ctl: ctl).tabItem { Label("Visualizzazione", systemImage: "waveform") }
            PlaylistTab(ctl: ctl).tabItem { Label("Playlist", systemImage: "list.bullet") }
            SkinTab(ctl: ctl).tabItem { Label("Skin", systemImage: "paintpalette") }
        }
        .padding(20)
        .frame(width: 600, height: 440)
    }
}

private struct GeneralTab: View {
    @ObservedObject var ctl: Ctl

    var body: some View {
        Form {
            Section("Finestre") {
                Toggle("Sempre in primo piano", isOn: ctl.toggleBinding(\.alwaysOnTop) { ctl.toggleAlwaysOnTop() })
                Toggle("Doppia dimensione", isOn: ctl.toggleBinding(\.doubleSize) { ctl.toggleDoubleSize() })
                Toggle("Mostra equalizzatore", isOn: ctl.toggleBinding(\.eqVisible) { ctl.toggleEQ() })
                Toggle("Mostra playlist", isOn: ctl.toggleBinding(\.plVisible) { ctl.togglePL() })
                Toggle("Aggancia finestre ai bordi", isOn: ctl.binding(\.snapEnabled))
                HStack {
                    Text("Distanza di aggancio")
                    Slider(value: ctl.binding(\.snapDistance), in: 4...30, step: 1)
                    Text("\(Int(ctl.snapDistance)) px").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .disabled(!ctl.snapEnabled)
            }
            Section("Display") {
                Toggle("Mostra tempo rimanente", isOn: ctl.binding(\.timeRemaining))
                Toggle("Scorrimento titolo", isOn: ctl.binding(\.marqueeScroll))
            }
            Section("Avvio") {
                Toggle("Riprendi la riproduzione all'avvio", isOn: ctl.binding(\.resumeOnLaunch))
            }
            Section("Barra dei menu e notifiche") {
                Toggle("Mini controller nella barra dei menu", isOn: ctl.binding(\.menuBarEnabled))
                Toggle("Notifica al cambio brano", isOn: ctl.binding(\.notifyTrackChange))
                Toggle("Solo quando MusicAmp è in secondo piano", isOn: ctl.binding(\.notifyOnlyInBackground))
                    .disabled(!ctl.notifyTrackChange)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AudioTab: View {
    @ObservedObject var ctl: Ctl
    @State private var devices: [AudioDevice] = []

    var body: some View {
        Form {
            Section("Uscita") {
                Picker("Dispositivo", selection: Binding(get: { ctl.outputDeviceUID }, set: { ctl.selectOutput($0) })) {
                    Text("Predefinito di sistema").tag(String?.none)
                    ForEach(devices) { d in Text(d.name).tag(Optional(d.uid)) }
                }
                Button("Aggiorna elenco") { devices = AudioDevice.outputDevices() }
                LabeledContent("AirPlay e uscite di sistema") {
                    RoutePicker().frame(width: 28, height: 22)
                }
                Text("Con \"Predefinito di sistema\" MusicAmp segue l'uscita scelta qui, nel Centro di controllo o nelle Impostazioni Suono, anche se è un altoparlante AirPlay.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Riproduzione") {
                Toggle("Shuffle", isOn: ctl.binding(\.shuffle))
                Toggle("Ripeti playlist", isOn: ctl.binding(\.repeatOn))
            }
            Section("Equalizzatore") {
                Toggle("Equalizzatore attivo", isOn: ctl.binding(\.eqOn))
                Button("Reimposta EQ (flat)") { ctl.resetEQ() }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevice.outputDevices() }
    }
}

private struct VisTab: View {
    @ObservedObject var ctl: Ctl
    private let speeds = ["Molto lenta", "Lenta", "Media", "Veloce", "Molto veloce"]

    var body: some View {
        Form {
            Picker("Modalità", selection: ctl.binding(\.visMode)) {
                Text("Analizzatore di spettro").tag(0)
                Text("Oscilloscopio").tag(1)
                Text("Disattivata").tag(2)
            }
            Section("Analizzatore") {
                Picker("Bande", selection: ctl.binding(\.visThinBands)) {
                    Text("Spesse").tag(false)
                    Text("Sottili").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Mostra picchi", isOn: ctl.binding(\.visPeaksOn))
                Picker("Caduta analizzatore", selection: ctl.binding(\.visFalloff)) {
                    ForEach(0..<5) { Text(speeds[$0]).tag($0) }
                }
                Picker("Caduta picchi", selection: ctl.binding(\.peakFalloff)) {
                    ForEach(0..<5) { Text(speeds[$0]).tag($0) }
                }
                .disabled(!ctl.visPeaksOn)
            }
            .disabled(ctl.visMode != 0)
            Section("Oscilloscopio") {
                Picker("Stile", selection: ctl.binding(\.oscStyle)) {
                    Text("Punti").tag(0)
                    Text("Linee").tag(1)
                    Text("Pieno").tag(2)
                }
                .pickerStyle(.segmented)
            }
            .disabled(ctl.visMode != 1)
        }
        .formStyle(.grouped)
    }
}

private struct PlaylistTab: View {
    @ObservedObject var ctl: Ctl

    var body: some View {
        Form {
            Section("Aspetto") {
                Stepper("Dimensione font: \(ctl.plFontSize) pt", value: ctl.binding(\.plFontSize), in: 7...16)
                Toggle("Usa il font indicato dalla skin (pledit.txt)", isOn: ctl.binding(\.plUseSkinFont))
                Toggle("Cerca online i font mancanti (Google Fonts)", isOn: ctl.binding(\.autoDownloadFonts))
                Toggle("Mostra numerazione", isOn: ctl.binding(\.plShowNumbers))
                Toggle("Playlist ridotta (shade)", isOn: ctl.toggleBinding(\.plShade) { ctl.togglePLShade() })
            }
            SkinFontSection(ctl: ctl, fonts: FontResolver.shared)
            Section("Contenuto") {
                LabeledContent("Brani", value: "\(ctl.playlist.tracks.count)")
                LabeledContent("Durata totale", value: Ctl.hmmss(ctl.playlist.totalDuration))
                HStack {
                    Button("Rimuovi file mancanti") { ctl.removeMissing() }
                    Button("Rimuovi duplicati") { ctl.removeDuplicates() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SkinTab: View {
    @ObservedObject var ctl: Ctl
    @State private var skins: [URL] = []
    @State private var selection: URL?
    @State private var preview: NSImage?
    @State private var error: String?
    @State private var cache: [URL: Skin] = [:]

    private static let defaultURL = URL(fileURLWithPath: "/__musicamp_default__")

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: $selection) {
                    Text("Skin predefinita").tag(Self.defaultURL)
                    ForEach(skins, id: \.self) { u in
                        Text(u.deletingPathExtension().lastPathComponent).tag(u)
                    }
                }
                .frame(width: 210)
                HStack {
                    Button {
                        ctl.chooseSkin()
                        reload()
                    } label: { Image(systemName: "plus") }
                    .help("Carica skin…")
                    Button {
                        if let u = selection, u != Self.defaultURL {
                            try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                            if u.path == ctl.skinPath { ctl.applySkin(nil) }
                            reload()
                        }
                    } label: { Image(systemName: "trash") }
                    .help("Sposta nel Cestino")
                    .disabled(selection == nil || selection == Self.defaultURL)
                    Spacer()
                    Button { ctl.openSkinsFolder() } label: { Image(systemName: "folder") }
                        .help("Apri cartella skin")
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25))
                    if let preview {
                        Image(nsImage: preview).interpolation(.none).resizable().frame(width: 275 * 1.2, height: 116 * 1.2)
                    } else if let error {
                        Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
                .frame(width: 340, height: 150)
                if let u = selection {
                    Text(u == Self.defaultURL ? "Predefinita" : u.lastPathComponent).font(.headline)
                    Text(isCurrent(u) ? "Skin attiva" : "").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Applica") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || selection.map(isCurrent) == true)
                    Button("Scarica skin…") { ctl.openSkinMuseum() }
                }
                Spacer()
            }
        }
        .onAppear {
            reload()
            selection = ctl.skinPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
        }
        .onChange(of: selection) { _ in loadPreview() }
    }

    private func isCurrent(_ u: URL) -> Bool { u == Self.defaultURL ? ctl.skinPath == nil : u.path == ctl.skinPath }

    private func reload() { skins = ctl.installedSkins() }

    private func loadPreview() {
        error = nil
        guard let u = selection else { preview = nil; return }
        if u == Self.defaultURL { preview = ctl.previewImage(Skin.fallback); return }
        do {
            let s = try cache[u] ?? Skin.load(from: u)
            cache[u] = s
            preview = ctl.previewImage(s)
        } catch {
            preview = nil
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        guard let u = selection else { return }
        ctl.applySkin(u == Self.defaultURL ? nil : u)
    }
}

private struct SkinFontSection: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var fonts: FontResolver
    @State private var cached = 0

    private var requested: String { ctl.skin.playlist.font }

    private var statusText: String {
        switch fonts.status(for: requested) {
        case .installed?: return "Installato sul Mac"
        case .bundled?: return "Incluso nella skin"
        case .downloaded(let f)?:
            return f.caseInsensitiveCompare(requested) == .orderedSame ? "Scaricato da Google Fonts" : "Sostituito con \(f) (Google Fonts)"
        case .substituted(let f)?: return "Sostituito con \(f) (installato)"
        case .searching?: return "Ricerca online in corso…"
        case .missing?: return ctl.autoDownloadFonts ? "Non trovato online, uso Arial" : "Mancante, uso Arial"
        case nil: return "—"
        }
    }

    var body: some View {
        Section("Font della skin") {
            LabeledContent("Richiesto da pledit.txt", value: requested)
            LabeledContent("Stato") {
                HStack(spacing: 6) {
                    if fonts.status(for: requested) == .searching { ProgressView().controlSize(.small) }
                    Text(statusText)
                }
            }
            LabeledContent("Anteprima") {
                Text("1. Artist - Song Title  3:45")
                    .font(Font(fonts.font(requested, size: CGFloat(max(12, ctl.plFontSize))) as CTFont))
            }
            HStack {
                Button("Cerca di nuovo") { fonts.retry(requested) }
                    .disabled(fonts.status(for: requested) == .installed || fonts.status(for: requested) == .bundled)
                Spacer()
                Button("Apri cartella font") { NSWorkspace.shared.open(fonts.fontsDir) }
                Button("Svuota cache (\(cached))") {
                    fonts.clearCache()
                    cached = fonts.cachedFontCount
                }
                .disabled(cached == 0)
            }
        }
        .onAppear {
            _ = fonts.family(for: requested)
            cached = fonts.cachedFontCount
        }
        .onChange(of: fonts.statuses) { _ in cached = fonts.cachedFontCount }
    }
}
