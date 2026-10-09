import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Speakers beyond this Mac: Chromecast, Sonos and UPnP/DLNA renderers play MusicAmp's live stream (LiveStream),
/// several at once; AirPlay 2 to several speakers together goes through a system player (AVPlayer) that plays
/// the same stream and offers the multi-speaker AirPlay picker. Everything MusicAmp plays is sent after the EQs
/// and crossfeed, from the playlist, radio, podcasts or the Music/Spotify bridge.
@MainActor
final class Outputs: ObservableObject {
    static let shared = Outputs()

    enum Status: Equatable { case connecting, playing, failed(String) }

    /// Sound sent to Chromecast and UPnP renderers. Sonos and the karaoke video always use AAC 320.
    enum Quality: String, CaseIterable, Identifiable {
        case lossless, high
        var id: String { rawValue }
        var label: String { self == .lossless ? "Lossless (FLAC)" : "High (AAC 320 kb/s)" }
    }

    @Published private(set) var active: [String: Status] = [:]   // speaker id → status
    @Published private(set) var airPlayOn = false
    @Published private(set) var listeners = 0
    /// Silences this Mac's speakers while something is casting (the volume slider then sets the stream's level).
    @Published var muteMac = UserDefaults.standard.object(forKey: "outputs.muteMac") as? Bool ?? true {
        didSet { UserDefaults.standard.set(muteMac, forKey: "outputs.muteMac"); applyVolume() }
    }

    @Published var quality = Quality(rawValue: UserDefaults.standard.string(forKey: "outputs.quality") ?? "") ?? .lossless {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "outputs.quality")
            // Speakers playing the audio stream switch to the other one.
            for s in SpeakerDiscovery.shared.speakers where isOn(s) && !(s.kind == .chromecast && showsLyrics(s)) && s.kind != .sonos {
                reconnect(s)
            }
        }
    }
    /// Device volume when it was last anchored to the slider (speaker id → (device level 0…1, slider 0…100)).
    private var volumeAnchor: [String: (level: Double, slider: Double)] = [:]
    private var lastSent: [String: Double] = [:]
    /// UPnP renderers stopped (not paused) by a pause: resuming loads the stream again.
    private var upnpStopped = Set<String>()

    /// Chromecasts that show the karaoke on screen (speaker ids), remembered.
    @Published private(set) var tvLyrics = Set(UserDefaults.standard.stringArray(forKey: "outputs.tvLyrics") ?? [])
    private var casts: [String: CastSession] = [:]
    private var upnp: [String: NetSpeaker] = [:]
    let airPlayer = AVPlayer()

    var casting: Bool { !active.isEmpty || airPlayOn }

    // MARK: Stream

    private func ensureStream() -> URL? {
        defer { LiveStream.shared.hlsPaused = Ctl.shared.transport.state != .playing; lastPlaying = Ctl.shared.transport.state == .playing }
        let live = LiveStream.shared
        if !live.running {
            do { try live.start(engine: Ctl.shared.audio) } catch { return nil }
            live.onClientsChanged = { [weak self] n in self?.listeners = n }
        }
        updateCover()
        applyVolume()
        return live.url
    }

    private func stopStreamIfIdle() {
        guard !casting else { return }
        LiveStream.shared.stop()
        listeners = 0
        applyVolume()
    }

    /// Volume: the stream always goes at full level (no lost resolution); the slider moves the speakers' own
    /// volume, relative to where each one was (a TV at 8% doesn't jump to 75%), and AirPlay's player volume.
    /// This Mac is muted while casting if chosen.
    func applyVolume() {
        let v = max(0, min(100, Ctl.shared.volume))
        let x = Float(v / 100)
        LiveStream.shared.gain = 1
        airPlayer.volume = x * x
        Ctl.shared.audio.engine.mainMixerNode.outputVolume = casting && muteMac ? 0 : x * x
        for (id, a) in volumeAnchor where active[id] != nil {
            let target = max(0, min(1, a.slider > 0.5 ? a.level * v / a.slider : a.level))
            guard abs((lastSent[id] ?? -1) - target) > 0.004 else { continue }
            lastSent[id] = target
            if let c = casts[id] { c.setVolume(target) } else if let u = upnp[id] { UPnPRenderer.setVolume(u, Int((target * 100).rounded())) }
        }
    }

    /// A speaker reported its volume: changed on the speaker (remote, app) → that becomes the new reference.
    private func deviceVolume(_ id: String, _ level: Double) {
        if let sent = lastSent[id], abs(sent - level) < 0.006 { return }   // our own change coming back
        volumeAnchor[id] = (level, max(0, min(100, Ctl.shared.volume)))
        lastSent[id] = level
    }

    /// The current track's cover for Chromecast's screen.
    func updateCover() {
        guard LiveStream.shared.running else { return }
        LiveStream.shared.coverJPEG = currentCoverJPEG()
    }

    private func currentCoverJPEG() -> Data? {
        let img: NSImage?
        if let e = Ctl.shared.external { img = e.artwork } else { img = Ctl.shared.playlist.currentTrack.flatMap { Artwork.cached($0.url) } }
        return img?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) }
    }

    private var lastPlaying: Bool?

    /// MusicAmp paused or resumed: the HLS streams stop instead of filling with silence, and Chromecasts and
    /// AirPlay pause too, so they resume exactly where they were.
    func playbackChanged() {
        let playing = Ctl.shared.transport.state == .playing
        LiveStream.shared.hlsPaused = !playing
        guard casting, playing != lastPlaying else { lastPlaying = playing; return }
        lastPlaying = playing
        for c in casts.values { c.setPlaying(playing) }
        for (id, u) in upnp {
            if playing {
                if upnpStopped.remove(id) != nil { reconnect(SpeakerDiscovery.shared.speakers.first { $0.id == id } ?? u) } else { UPnPRenderer.resume(u) { _ in } }
            } else {
                UPnPRenderer.pause(u) { stopped in DispatchQueue.main.async { if stopped { self.upnpStopped.insert(id) } } }
            }
        }
        if airPlayOn, airPlayer.currentItem != nil { playing ? airPlayer.play() : airPlayer.pause() }
    }

    /// Another track (or its cover arrived): cover for Chromecast, title/artist/cover for the AirPlay screens.
    func trackChanged() {
        guard casting else { return }
        updateCover()
        if airPlayOn { updateAirPlayMetadata() }
        // The cover of a local file loads in the background: try again once it's there.
        if Ctl.shared.external == nil, let t = Ctl.shared.playlist.currentTrack, Artwork.cached(t.url) == nil {
            Task { @MainActor in
                if await Artwork.load(t.url) != nil, Ctl.shared.playlist.currentTrack === t { self.updateCover(); if self.airPlayOn { self.updateAirPlayMetadata() } }
            }
        }
    }

    /// What AirPlay receivers with a screen (Apple TV, TVs) show: title, artist, album and cover, written into the
    /// AirPlay stream as timed metadata (AVPlayer forwards the stream's metadata, not the app's Now Playing).
    private func updateAirPlayMetadata() {
        let (title, artist) = nowPlaying
        let album = Ctl.shared.external?.album ?? Ctl.shared.playlist.currentTrack?.album ?? ""
        let cover = currentCoverJPEG()
        LiveStream.shared.hlsStream("audio")?.setMetadata(LiveHLS.Metadata(title: title, artist: artist, album: album, cover: cover))
        OutputsLog.add("airplay metadata: \(title) – \(artist), cover \(cover == nil ? "no" : "yes")")
    }

    private var nowPlaying: (String, String) {
        let c = Ctl.shared
        if let e = c.external, !e.title.isEmpty { return (e.title, e.artist) }
        if let t = c.playlist.currentTrack { return (t.songTitle ?? t.title, t.artist ?? "") }
        return ("MusicAmp", "")
    }

    // MARK: Network speakers

    func isOn(_ s: NetSpeaker) -> Bool { active[s.id] != nil }

    func toggle(_ s: NetSpeaker) { isOn(s) ? disconnect(s) : connect(s) }

    func connect(_ s: NetSpeaker) {
        guard let aac = ensureStream() else { active[s.id] = .failed("Can't start the stream (no local network?)."); return }
        // Lossless where the speaker can take it; Sonos plays radio-style streams as AAC.
        let lossless = quality == .lossless && s.kind != .sonos
        let url = lossless ? (LiveStream.shared.url(.flac) ?? aac) : aac
        active[s.id] = .connecting
        applyVolume()
        let (title, artist) = nowPlaying
        switch s.kind {
        case .chromecast:
            let video = showsLyrics(s)
            let stream = video ? LiveStream.shared.hlsURL(TVKaraoke.name, master: true) : url
            let c = CastSession(speaker: s, stream: stream ?? url, title: title, artist: artist, cover: LiveStream.shared.coverURL)
            c.video = video
            if !video, lossless { c.audioType = "audio/flac"; c.fallback = (aac, "audio/aac") }
            c.onVolume = { [weak self] level in self?.deviceVolume(s.id, level) }
            c.onState = { [weak self] err, playing in
                guard let self, self.active[s.id] != nil else { return }
                if let err { self.active[s.id] = .failed(err) } else if playing { self.active[s.id] = .playing }
            }
            casts[s.id] = c
            updateTV()
            if video { whenReady(TVKaraoke.name) { [weak self] in if self?.casts[s.id] === c { c.start() } } } else { c.start() }
        case .upnp, .sonos:
            upnp[s.id] = s
            let name = artist.isEmpty ? title : "\(artist) – \(title)"
            UPnPRenderer.getVolume(s) { v in DispatchQueue.main.async { if let v { self.deviceVolume(s.id, Double(v) / 100) } } }
            UPnPRenderer.play(s, stream: url, title: name, contentType: lossless ? "audio/flac" : "audio/aac") { err in
                // A renderer that refuses FLAC gets AAC.
                if err != nil, lossless {
                    OutputsLog.add("upnp \(s.name): FLAC refused, falling back to AAC")
                    UPnPRenderer.play(s, stream: aac, title: name) { err2 in
                        DispatchQueue.main.async { if self.active[s.id] != nil { self.active[s.id] = err2.map { .failed($0) } ?? .playing } }
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard self.active[s.id] != nil else { return }
                    self.active[s.id] = err.map { .failed($0) } ?? .playing
                }
            }
        }
    }

    func showsLyrics(_ s: NetSpeaker) -> Bool { tvLyrics.contains(s.id) }

    /// Disconnects and connects again (another stream or quality).
    private func reconnect(_ s: NetSpeaker) {
        casts.removeValue(forKey: s.id)?.stop()
        upnp.removeValue(forKey: s.id)
        upnpStopped.remove(s.id)
        active[s.id] = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if self.active[s.id] != nil { self.connect(s) } }
    }

    /// Lyrics on the TV on/off; a Chromecast already playing reconnects with the other stream.
    func setLyrics(_ s: NetSpeaker, _ on: Bool) {
        if on { tvLyrics.insert(s.id) } else { tvLyrics.remove(s.id) }
        UserDefaults.standard.set(Array(tvLyrics), forKey: "outputs.tvLyrics")
        if isOn(s) {
            casts.removeValue(forKey: s.id)?.stop()
            active[s.id] = nil
            updateTV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.connect(s) }
        }
    }

    /// The karaoke video runs while a Chromecast shows it.
    private func updateTV() {
        let needed = casts.keys.contains { tvLyrics.contains($0) }
        if needed, !TVKaraoke.shared.active { TVKaraoke.shared.start(stream: LiveStream.shared) }
        if !needed, TVKaraoke.shared.active { TVKaraoke.shared.stop(stream: LiveStream.shared) }
    }

    /// Calls `then` once the HLS stream `name` has a few segments (receivers want a playlist that isn't empty).
    private func whenReady(_ name: String, _ then: @escaping () -> Void, tries: Int = 0) {
        if (LiveStream.shared.hlsStream(name)?.segmentCount ?? 0) >= 4 || tries > 60 { then(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.whenReady(name, then, tries: tries + 1) }
    }

    func disconnect(_ s: NetSpeaker) {
        casts.removeValue(forKey: s.id)?.stop()
        defer { updateTV() }
        if let u = upnp.removeValue(forKey: s.id) { UPnPRenderer.stop(u) }
        active[s.id] = nil
        volumeAnchor[s.id] = nil
        lastSent[s.id] = nil
        upnpStopped.remove(s.id)
        stopStreamIfIdle()
    }

    func disconnectAll() {
        for s in SpeakerDiscovery.shared.speakers where isOn(s) { disconnect(s) }
        casts.values.forEach { $0.stop() }; casts = [:]
        updateTV()
        upnp.values.forEach(UPnPRenderer.stop); upnp = [:]
        active = [:]
        setAirPlay(false)
    }

    // MARK: AirPlay (several speakers)

    /// Plays the stream with a system player whose route picker can send it to several AirPlay 2 speakers at once.
    func setAirPlay(_ on: Bool) {
        if on {
            // HLS at the network address: a receiver that fetches the stream itself (an AirPlay TV) can reach it,
            // and AVPlayer buffers HLS for AirPlay as it does for any live radio.
            guard ensureStream() != nil else { return }
            let live = LiveStream.shared
            if live.hlsStream("audio") == nil { live.addHLS(LiveHLS(name: "audio", metadata: true)) }
            updateAirPlayMetadata()
            guard let url = live.hlsURL("audio") else { return }
            airPlayOn = true
            // Audio mode, not URL hand-off: the Mac plays the stream and sends AirPlay audio plus MusicAmp's Now
            // Playing (title, cover). Handed the URL, a TV plays the stream itself and shows no cover; audio mode
            // is also the one where AirPlay 2 keeps several speakers in sync.
            airPlayer.allowsExternalPlayback = false
            airPlayer.automaticallyWaitsToMinimizeStalling = true
            whenReady("audio") { [weak self] in
                guard let self, self.airPlayOn else { return }
                self.airPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
                self.airPlayer.play()
            }
        } else {
            airPlayer.pause()
            airPlayer.replaceCurrentItem(with: nil)
            LiveStream.shared.removeHLS("audio")
            airPlayOn = false
            stopStreamIfIdle()
        }
        applyVolume()
    }
}

extension Ctl {
    @MainActor @objc func showSpeakers() {
        if speakersWindowRef == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SpeakersView(outputs: .shared, discovery: .shared)))
            w.title = L("Speakers")
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("Speakers")
            speakersWindowRef = w
        }
        NSApp.activate(ignoringOtherApps: true)
        speakersWindowRef?.makeKeyAndOrderFront(nil)
        SpeakerDiscovery.shared.start()
    }
}

/// AirPlay picker bound to the casting player: it lists AirPlay 2 speakers with checkboxes (several at once).
struct PlayerRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ v: AVRoutePickerView, context: Context) { v.player = player }
}

struct SpeakersView: View {
    @ObservedObject var outputs: Outputs
    @ObservedObject var discovery: SpeakerDiscovery

    var body: some View {
        Form {
            Section {
                Toggle("AirPlay to several speakers", isOn: Binding(get: { outputs.airPlayOn }, set: { outputs.setAirPlay($0) }))
                if outputs.airPlayOn {
                    LabeledContent("Choose the speakers") { PlayerRoutePicker(player: outputs.airPlayer).frame(width: 28, height: 22) }
                }
                Text("Tick one or more AirPlay 2 speakers in the picker; they play in sync with each other. For a single speaker, the system output in Settings → Audio is enough and has less delay.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("AirPlay") }

            Section {
                if discovery.speakers.isEmpty {
                    HStack {
                        if discovery.searching { ProgressView().controlSize(.small) }
                        Text(discovery.searching ? "Searching the network…" : "No Chromecast, Sonos or UPnP speaker found.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(discovery.speakers) { s in SpeakerRow(speaker: s, outputs: outputs) }
                Button("Search Again") { discovery.start() }
            } header: { Text("Chromecast, Sonos and UPnP") }

            Section {
                Picker("Quality", selection: $outputs.quality) {
                    ForEach(Outputs.Quality.allCases) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                Text("Lossless sends exactly what MusicAmp plays (about 2 Mb/s on your network); Chromecast and most UPnP speakers play it, and a speaker that refuses it gets AAC. Sonos and the karaoke on a TV always use AAC 320 kb/s.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Mute this Mac while casting", isOn: $outputs.muteMac)
                if outputs.casting, let u = LiveStream.shared.url(outputs.quality == .lossless ? .flac : .aac) {
                    LabeledContent("Stream", value: u.absoluteString).textSelection(.enabled)
                    LabeledContent("Listeners", value: "\(outputs.listeners)")
                }
                Text("The volume slider moves each speaker's own volume, from where it was; the sound is sent at full level. Speakers play what MusicAmp plays, after the equalizers, with a few seconds of delay. Different kinds of speakers aren't in sync with each other. Any player on the network can open the stream address too.")
                    .font(.caption).foregroundStyle(.secondary)
                if outputs.casting { Button("Stop All") { outputs.disconnectAll() } }
            } header: { Text("Stream") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420)
    }
}

private struct SpeakerRow: View {
    let speaker: NetSpeaker
    @ObservedObject var outputs: Outputs

    var body: some View {
        HStack {
            Image(systemName: speaker.symbol).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                Group {
                    switch outputs.active[speaker.id] {
                    case .connecting: Text("Connecting…")
                    case .playing: Text("Playing").foregroundStyle(.green)
                    case .failed(let e): Text(e).foregroundStyle(.red)
                    case nil: Text("\(speaker.kindName) · \(speaker.model)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if speaker.kind == .chromecast {
                Toggle(isOn: Binding(get: { outputs.showsLyrics(speaker) }, set: { outputs.setLyrics(speaker, $0) })) {
                    Image(systemName: "music.mic")
                }
                .toggleStyle(.button)
                .help("Show the lyrics on the TV, karaoke style (sent as video, a few more seconds of delay)")
            }
            Toggle("", isOn: Binding(get: { outputs.isOn(speaker) }, set: { _ in outputs.toggle(speaker) })).labelsHidden().toggleStyle(.switch)
        }
    }
}
