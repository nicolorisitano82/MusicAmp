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

    @objc func showPreferences() { openPreferences(tab: nil) }

    func openPreferences(tab: PrefsTab?) {
        if let tab { prefsTab = tab }
        if prefsWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(ctl: self)))
            w.title = L("MusicAmp Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindowRef = w
        }
        prefsWindowRef?.level = alwaysOnTop ? .floating : .normal
        NSApp.activate(ignoringOtherApps: true)
        prefsWindowRef?.makeKeyAndOrderFront(nil)
        // A TabView that is still building its tabs can land on the wrong one: select again once it is on screen.
        if let tab { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.prefsTab = .general; self.prefsTab = tab } }
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

enum PrefsTab: Hashable { case general, audio, headphones, vis, playlist, timer, shortcuts, skins }

struct PreferencesView: View {
    @ObservedObject var ctl: Ctl

    var body: some View {
        TabView(selection: ctl.binding(\.prefsTab)) {
            GeneralTab(ctl: ctl).tabItem { Label("General", systemImage: "gearshape") }.tag(PrefsTab.general)
            AudioTab(ctl: ctl).tabItem { Label("Audio", systemImage: "hifispeaker") }.tag(PrefsTab.audio)
            HeadphonesTab(ctl: ctl, catalog: .shared).tabItem { Label("Headphones", systemImage: "headphones") }.tag(PrefsTab.headphones)
            VisTab(ctl: ctl).tabItem { Label("Visualization", systemImage: "waveform") }.tag(PrefsTab.vis)
            PlaylistTab(ctl: ctl).tabItem { Label("Playlist", systemImage: "list.bullet") }.tag(PrefsTab.playlist)
            TimerTab(ctl: ctl).tabItem { Label("Timer", systemImage: "alarm") }.tag(PrefsTab.timer)
            ShortcutsTab(keys: .shared).tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(PrefsTab.shortcuts)
            SkinTab(ctl: ctl).tabItem { Label("Skins", systemImage: "paintpalette") }.tag(PrefsTab.skins)
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }
}

private struct GeneralTab: View {
    @ObservedObject var ctl: Ctl
    @State private var langChanged = false

    var body: some View {
        Form {
            Section("Windows") {
                Toggle("Always on Top", isOn: ctl.toggleBinding(\.alwaysOnTop) { ctl.toggleAlwaysOnTop() })
                Toggle("Double Size", isOn: ctl.toggleBinding(\.doubleSize) { ctl.toggleDoubleSize() })
                Toggle("Show Equalizer", isOn: ctl.toggleBinding(\.eqVisible) { ctl.toggleEQ() })
                Toggle("Show Playlist", isOn: ctl.toggleBinding(\.plVisible) { ctl.togglePL() })
                Toggle("Snap windows to edges", isOn: ctl.binding(\.snapEnabled))
                HStack {
                    Text("Snap distance")
                    Slider(value: ctl.binding(\.snapDistance), in: 4...30, step: 1)
                    Text("\(Int(ctl.snapDistance)) px").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .disabled(!ctl.snapEnabled)
            }
            Section("Display") {
                Toggle("Show remaining time", isOn: ctl.binding(\.timeRemaining))
                Toggle("Scroll title", isOn: ctl.binding(\.marqueeScroll))
            }
            Section("Language") {
                Picker("Language", selection: Binding(get: { AppLanguage.current }, set: { UserDefaults.standard.set($0, forKey: AppLanguage.key); langChanged = true })) {
                    ForEach(AppLanguage.choices, id: \.0) { Text(LocalizedStringKey($0.1)).tag($0.0) }
                }
                if langChanged {
                    HStack {
                        Text("MusicAmp will use the new language after a restart.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                }
            }
            Section("Startup") {
                Toggle("Resume playback at launch", isOn: ctl.binding(\.resumeOnLaunch))
            }
            Section("Menu Bar, Dock and Notifications") {
                Toggle("Mini player in the menu bar", isOn: ctl.binding(\.menuBarEnabled))
                Toggle("Cover and waveform in the Dock icon", isOn: ctl.binding(\.dockIconLive))
                Toggle("Close button keeps the music playing in the Dock", isOn: ctl.binding(\.closeToDock))
                Text("Closed, MusicAmp lives in its Dock icon: click it to play or pause, right-click for the controls and Show Player. Quit with ⌘Q.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify on track change", isOn: ctl.binding(\.notifyTrackChange))
                Toggle("Only when MusicAmp is in the background", isOn: ctl.binding(\.notifyOnlyInBackground))
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
            Section("Output") {
                Picker("Device", selection: Binding(get: { ctl.outputDeviceUID }, set: { ctl.selectOutput($0) })) {
                    Text("System Default").tag(String?.none)
                    ForEach(devices) { d in Text(d.name).tag(Optional(d.uid)) }
                }
                Button("Refresh List") { devices = AudioDevice.outputDevices() }
                LabeledContent("AirPlay and system outputs") {
                    RoutePicker().frame(width: 28, height: 22)
                }
                LabeledContent("Several AirPlay speakers, Chromecast, Sonos") {
                    HStack(spacing: 6) {
                        BetaBadge()
                        Button("Speakers…") { ctl.showSpeakers() }
                    }
                }
                Text("With \"System Default\", MusicAmp follows the output chosen here, in Control Center or in Sound settings, even if it's an AirPlay speaker.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bit-perfect: switch the output to each track's sample rate", isOn: ctl.binding(\.bitPerfect))
                BitPerfectStatus(ctl: ctl)
            }
            Section("Transitions") {
                Toggle("Gapless: no pause between tracks", isOn: ctl.binding(\.gapless))
                Toggle("Crossfade between tracks", isOn: ctl.binding(\.crossfadeOn))
                HStack {
                    Text("Fade duration")
                    Slider(value: ctl.binding(\.crossfadeSeconds), in: 1...12, step: 1)
                    Text("\(Int(ctl.crossfadeSeconds)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
                .disabled(!ctl.crossfadeOn)
                Toggle("Smart transitions", isOn: ctl.binding(\.smartTransitions))
                Text("Between albums, skips the silence at the end of a track and at the start of the next. Inside an album, tracks always join gaplessly: no crossfade, no trimming.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Transitions apply when advancing automatically to the next track; Next and Previous switch immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Podcasts and Audiobooks") {
                Toggle("Voice Boost: clearer, evener speech", isOn: ctl.binding(\.voiceBoost))
                Toggle("Shorten silences", isOn: ctl.binding(\.shortenSilences))
                Text("Voice Boost cuts rumble, adds presence and evens out loud and quiet voices. Shorten Silences plays pauses 4× faster, keeping a short natural gap; it needs the episode downloaded. Music is never affected.")
                    .font(.caption).foregroundStyle(.secondary)
                if ctl.audio.timeSaved >= 60 {
                    LabeledContent("Time saved so far", value: Ctl.hmmss(ctl.audio.timeSaved))
                }
            }
            Section("Karaoke") {
                Toggle("Remove vocals (⌥⌘V)", isOn: Binding(get: { ctl.vocalRemoval > 0 }, set: { ctl.vocalRemoval = $0 ? ctl.vocalStrength : 0 }))
                HStack {
                    Text("Strength")
                    Slider(value: ctl.binding(\.vocalStrength), in: 0.3...1)
                    Text("\(Int(ctl.vocalStrength * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("Cancels what is mixed in the centre, where lead vocals usually are; bass stays. Works best on studio stereo mixes, not on mono or live recordings. Not remembered after quitting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("ReplayGain (Volume Leveling)") {
                Picker("Mode", selection: ctl.binding(\.rgMode)) {
                    Text("Off").tag(0)
                    Text("Track").tag(1)
                    Text("Album").tag(2)
                }
                .pickerStyle(.segmented)
                Stepper("Preamp: \(String(format: "%+.0f", ctl.rgPreamp)) dB", value: ctl.binding(\.rgPreamp), in: -12...12, step: 1)
                    .disabled(ctl.rgMode == 0)
                Toggle("Analyze untagged tracks (EBU R128)", isOn: ctl.binding(\.rgAnalyze))
                    .disabled(ctl.rgMode == 0)
                Toggle("Prevent clipping (limit to peak)", isOn: ctl.binding(\.rgPreventClip))
                    .disabled(ctl.rgMode == 0)
            }
            Section("Extra Formats (FFmpeg)") {
                Toggle("Use FFmpeg for Ogg, Opus, APE, WavPack, Musepack, DSD…", isOn: ctl.binding(\.ffmpegEnabled))
                if let path = FFmpeg.ffmpegPath {
                    if path.hasPrefix(Bundle.main.bundlePath) {
                        LabeledContent("Version", value: "FFmpeg \(FFmpeg.version ?? "") bundled with the app (LGPL)")
                        if let src = Bundle.main.url(forResource: "SOURCE", withExtension: "txt", subdirectory: "FFmpeg") {
                            Button("FFmpeg License and Sources…") { NSWorkspace.shared.open(src.deletingLastPathComponent()) }
                        }
                    } else {
                        LabeledContent("Found", value: "\(path) \(FFmpeg.version.map { "(\($0))" } ?? "")")
                    }
                } else {
                    Text("FFmpeg not found. To enable it: brew install ffmpeg").foregroundStyle(.secondary)
                }
                Text("Extra formats go through the equalizer, visualizer and ReplayGain; gapless and crossfade work only between native formats.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Radio") {
                Stepper("Buffer before playback: \(Int(ctl.radioBuffer)) s", value: ctl.binding(\.radioBuffer), in: 1...10, step: 1)
                Text("More buffer avoids dropouts on slow networks, but the radio starts a little later. HLS streams (.m3u8) use the system buffer and bypass the equalizer and visualizer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Toggle("Shuffle", isOn: ctl.binding(\.shuffle))
                Toggle("Repeat playlist", isOn: ctl.binding(\.repeatOn))
            }
            Section("Equalizer") {
                Toggle("Equalizer on", isOn: ctl.binding(\.eqOn))
                Button("Reset EQ (Flat)") { ctl.resetEQ() }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDevice.outputDevices() }
    }
}

private struct VisTab: View {
    @ObservedObject var ctl: Ctl
    private let speeds = ["Very slow", "Slow", "Medium", "Fast", "Very fast"]

    var body: some View {
        Form {
            Picker("Mode", selection: ctl.binding(\.visMode)) {
                Text("Spectrum analyzer").tag(0)
                Text("Oscilloscope").tag(1)
                Text("Off").tag(2)
            }
            LiveVideoSettings()
            Section("Seek Bar") {
                Toggle("Waveform in the position bar", isOn: ctl.binding(\.waveSeekBar))
                Text("Drawn inside the skin's bar in its oscilloscope colour (viscolor.txt); the skin's graphics stay unchanged. Local files only; radio keeps the classic bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Analyzer") {
                Picker("Bands", selection: ctl.binding(\.visThinBands)) {
                    Text("Thick").tag(false)
                    Text("Thin").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Show peaks", isOn: ctl.binding(\.visPeaksOn))
                Picker("Analyzer falloff", selection: ctl.binding(\.visFalloff)) {
                    ForEach(0..<5) { Text(speeds[$0]).tag($0) }
                }
                Picker("Peak falloff", selection: ctl.binding(\.peakFalloff)) {
                    ForEach(0..<5) { Text(speeds[$0]).tag($0) }
                }
                .disabled(!ctl.visPeaksOn)
            }
            .disabled(ctl.visMode != 0)
            Section("Oscilloscope") {
                Picker("Style", selection: ctl.binding(\.oscStyle)) {
                    Text("Dots").tag(0)
                    Text("Lines").tag(1)
                    Text("Solid").tag(2)
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
            Section("Appearance") {
                Stepper("Font size: \(ctl.plFontSize) pt", value: ctl.binding(\.plFontSize), in: 7...16)
                Toggle("Use the skin's font (pledit.txt)", isOn: ctl.binding(\.plUseSkinFont))
                Toggle("Find missing fonts online (Google Fonts)", isOn: ctl.binding(\.autoDownloadFonts))
                Toggle("Show track numbers", isOn: ctl.binding(\.plShowNumbers))
                Toggle("Group by Artist and Album (tree)", isOn: ctl.binding(\.plTree))
                Toggle("Show ratings", isOn: ctl.binding(\.plShowRatings))
                Toggle("Save ratings in MP3 and FLAC tags (seen by other players)", isOn: ctl.binding(\.ratingsInTags))
                Toggle("Playlist windowshade mode", isOn: ctl.toggleBinding(\.plShade) { ctl.togglePLShade() })
            }
            SkinFontSection(ctl: ctl, fonts: FontResolver.shared)
            Section("Contents") {
                LabeledContent("Tracks", value: "\(ctl.playlist.tracks.count)")
                LabeledContent("Total duration", value: Ctl.hmmss(ctl.playlist.totalDuration))
                HStack {
                    Button("Remove Missing Files") { ctl.removeMissing() }
                    Button("Remove Duplicates") { ctl.removeDuplicates() }
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
                    Text("Default Skin").tag(Self.defaultURL)
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
                    .help("Load Skin…")
                    Button {
                        if let u = selection, u != Self.defaultURL {
                            try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                            if u.path == ctl.skinPath { ctl.applySkin(nil) }
                            reload()
                        }
                    } label: { Image(systemName: "trash") }
                    .help("Move to Trash")
                    .disabled(selection == nil || selection == Self.defaultURL)
                    Spacer()
                    Button { ctl.openSkinsFolder() } label: { Image(systemName: "folder") }
                        .help("Open Skins Folder")
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
                    HStack(spacing: 6) {
                        Text(u == Self.defaultURL ? "Default" : u.lastPathComponent).font(.headline)
                        if let s = cache[u], s.isRetina {
                            Text("Retina").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                                .help("\(s.images2x.count) bitmap @2x")
                        }
                    }
                    Text(isCurrent(u) ? "Current skin" : "").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Use Retina (@2x) skin graphics when available", isOn: $ctl.retinaSkins)
                HStack {
                    Button("Apply") { apply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection == nil || selection.map(isCurrent) == true)
                    Button("Download Skins…") { ctl.openSkinMuseum() }
                }
                Spacer()
            }
        }
        .onAppear {
            reload()
            selection = ctl.skinPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultURL
        }
        .onChange(of: selection) { loadPreview() }
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
        case .installed?: return "Installed on this Mac"
        case .bundled?: return "Bundled with the skin"
        case .downloaded(let f)?:
            return f.caseInsensitiveCompare(requested) == .orderedSame ? "Downloaded from Google Fonts" : "Replaced with \(f) (Google Fonts)"
        case .substituted(let f)?: return "Replaced with \(f) (installed)"
        case .searching?: return "Searching online…"
        case .missing?: return ctl.autoDownloadFonts ? "Not found online, using Arial" : "Missing, using Arial"
        case nil: return "—"
        }
    }

    var body: some View {
        Section("Skin Font") {
            LabeledContent("Requested by pledit.txt", value: requested)
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    if fonts.status(for: requested) == .searching { ProgressView().controlSize(.small) }
                    Text(statusText)
                }
            }
            LabeledContent("Preview") {
                Text("1. Artist - Song Title  3:45")
                    .font(Font(fonts.font(requested, size: CGFloat(max(12, ctl.plFontSize))) as CTFont))
            }
            HStack {
                Button("Search Again") { fonts.retry(requested) }
                    .disabled(fonts.status(for: requested) == .installed || fonts.status(for: requested) == .bundled)
                Spacer()
                Button("Open Fonts Folder") { NSWorkspace.shared.open(fonts.fontsDir) }
                Button("Clear Cache (\(cached))") {
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
        .onChange(of: fonts.statuses) { cached = fonts.cachedFontCount }
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var keys: HotKeys
    @State private var recording: HotKeyAction?
    @State private var monitor: Any?

    var body: some View {
        Form {
            Section {
                Toggle("Enable global shortcuts (they work even when MusicAmp is in the background)", isOn: $keys.enabled)
            }
            Section("Global") {
                ForEach(HotKeyAction.allCases) { a in
                    LabeledContent(a.title) {
                        HStack(spacing: 6) {
                            if keys.failed.contains(a) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    .help("Shortcut already used by another app")
                            }
                            Button(recording == a ? "Press Keys…" : (keys.bindings[a]?.display ?? "None")) { record(a) }
                                .frame(minWidth: 110)
                                .accessibilityLabel("\(a.title): \(keys.bindings[a]?.display ?? "no shortcut"). Press to record a new one")
                            Button { keys.set(a, nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).disabled(keys.bindings[a] == nil)
                                .accessibilityLabel("Remove shortcut \(a.title)")
                        }
                    }
                }
                HStack {
                    Text("Requires at least one of ⌘ ⌃ ⌥. Esc cancels recording.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { keys.resetDefaults() }
                }
            }
            .disabled(!keys.enabled)
            Section("In MusicAmp Windows (Like Winamp)") {
                Text("Z previous · X play · C pause · V stop · B next · L open file · ⇧L add folder · S shuffle · R repeat · J jump to file · ← → back/forward 5 s · ↑ ↓ volume")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
    }

    private func record(_ a: HotKeyAction) {
        stopRecording()
        recording = a
        keys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stopRecording(); return nil }   // Esc
            let f = e.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !f.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return nil }
            keys.set(a, HotKey(keyCode: UInt32(e.keyCode), modifiers: f.rawValue, display: HotKey.symbols(f) + HotKey.keyName(e)))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if recording != nil { keys.resume() }
        recording = nil
    }
}


/// Live status of the output path for Settings → Audio: device rate and what (if anything) breaks bit-perfection.
private struct BitPerfectStatus: View {
    @ObservedObject var ctl: Ctl
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let a = ctl.audio
            let issues = a.bitPerfectIssues
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: issues.isEmpty && a.hasSource ? "checkmark.seal.fill" : "info.circle")
                        .foregroundStyle(issues.isEmpty && a.hasSource ? Color.green : Color.secondary)
                    Text("Output \(AudioEngine.khz(a.deviceRate))" + (a.hasSource && !a.isStream ? (issues.isEmpty ? " · bit-perfect" : " · not bit-perfect") : ""))
                }
                if a.hasSource, !a.isStream, !issues.isEmpty {
                    Text(issues.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Text("Bit-perfect also needs volume at 100%, both equalizers and ReplayGain off, normal speed and centered balance. Tracks at different rates can't join gaplessly. The device rate is restored when you turn this off or quit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
