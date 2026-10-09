import AppKit
import AVFoundation

/// What the skin's transport shows and drives: MusicAmp's own engine, or an external player (bridge).
protocol Transport: AnyObject {
    var state: AudioEngine.State { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var hasSource: Bool { get }
    var bitrate: Int { get }
    var sampleRate: Double { get }
    var channels: Int { get }
    var stream: AudioEngine.StreamInfo { get }
    func seek(to time: Double)
}

extension AudioEngine: Transport {}

/// Bridge with the Music app or Spotify: MusicAmp drives the app with AppleScript (play/pause, next, previous,
/// position, the current track and its cover) and captures its audio (process tap) into its own engine, so the
/// skin, the equalizers, the visualizers and the outputs work with Apple Music and Spotify too.
/// The audio stays protected by the app: MusicAmp only receives the sound it would play.
final class ExternalPlayer: ObservableObject, Transport {
    enum App: String, CaseIterable, Identifiable {
        case music, spotify
        var id: String { rawValue }
        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var name: String { self == .music ? "Music" : "Spotify" }
        var scriptName: String { self == .music ? "Music" : "Spotify" }
        var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
        var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }
    }

    let app: App
    @Published private(set) var playing = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: NSImage?
    @Published private(set) var error: String?
    /// Audio comes through MusicAmp (the capture runs).
    @Published private(set) var captured = false
    private var position: Double = 0
    private var positionAt = Date()
    private(set) var duration: Double = 0
    private var trackKey = ""
    private var timer: Timer?
    private let queue = DispatchQueue(label: "musicamp.bridge")
    private let tap = AppAudioTap()
    private weak var engine: AudioEngine?

    init(app: App) { self.app = app }

    // MARK: Transport

    var state: AudioEngine.State { title.isEmpty ? .stopped : (playing ? .playing : .paused) }
    var currentTime: Double { playing ? min(duration, position + Date().timeIntervalSince(positionAt)) : position }
    var hasSource: Bool { !title.isEmpty }
    var bitrate: Int { 0 }
    var sampleRate: Double { tap.format?.sampleRate ?? 0 }
    var channels: Int { captured ? 2 : 0 }
    var stream: AudioEngine.StreamInfo { AudioEngine.StreamInfo() }

    func seek(to time: Double) {
        position = max(0, min(duration, time)); positionAt = Date()
        run("set player position to \(position)")
    }

    // MARK: Start / stop

    /// Launches the app if needed, starts polling and the audio capture.
    func start(engine: AudioEngine) {
        self.engine = engine
        if !app.running, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        // The app needs a moment to start before its audio can be tapped.
        DispatchQueue.main.asyncAfter(deadline: .now() + (app.running ? 0 : 3)) { [weak self] in self?.startCapture() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tap.stop()
        engine?.stopBridge()
        captured = false
    }

    func startCapture() {
        guard let engine, !captured else { return }
        do {
            try tap.start(bundleID: app.bundleID)
            if let f = tap.format { engine.startBridge(ring: tap.ring, sampleRate: f.sampleRate) }
            captured = true
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Commands

    func playPause() { run("playpause"); playing.toggle(); positionAt = Date(); MainActor.assumeIsolated { Outputs.shared.playbackChanged() } }
    func play() { run("play"); playing = true; positionAt = Date(); MainActor.assumeIsolated { Outputs.shared.playbackChanged() } }
    func pause() { run("pause"); position = currentTime; playing = false; MainActor.assumeIsolated { Outputs.shared.playbackChanged() } }
    func next() { run("next track"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() } }
    func previous() { run("previous track"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() } }

    /// Runs a command in the app (only when it's running: AppleScript would launch it otherwise).
    private func run(_ command: String) {
        let name = app.scriptName, id = app.bundleID
        queue.async {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { return }
            var err: NSDictionary?
            NSAppleScript(source: "tell application \"\(name)\" to \(command)")?.executeAndReturnError(&err)
        }
    }

    // MARK: Polling

    private var lastStats = (fill: 0, underruns: 0, dropped: 0)
    private var statsTick = 0

    /// Every 5 s, in the outputs log: how the capture keeps up (dry spells and drops are crackles).
    private func logCapture() {
        statsTick += 1
        guard captured, statsTick % 5 == 0 else { return }
        let s = tap.ring.stats
        let rate = tap.format?.sampleRate ?? 0
        let engineRate = engine?.engine.outputNode.outputFormat(forBus: 0).sampleRate ?? 0
        if engineRate > 0, engineRate < 32000 {
            OutputsLog.add("bridge \(app.name): the output runs at \(Int(engineRate)) Hz — Bluetooth headset (microphone) mode?")
        }
        OutputsLog.add("bridge \(app.name): tap \(Int(rate)) Hz, output \(Int(engineRate)) Hz, buffered \(s.fill) frames, dry +\(s.underruns - lastStats.underruns), dropped +\(s.dropped - lastStats.dropped)")
        lastStats = s
    }

    private func poll() {
        logCapture()
        let app = self.app
        queue.async { [weak self] in
            guard app.running else {
                DispatchQueue.main.async { self?.update(nil) }
                return
            }
            // Duration: seconds in Music, milliseconds in Spotify.
            let script = """
                tell application "\(app.scriptName)"
                    set s to player state as string
                    if s is "stopped" then return "stopped"
                    set t to current track
                    return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
                end tell
                """
            var err: NSDictionary?
            let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
            let message = err?[NSAppleScript.errorMessage] as? String
            DispatchQueue.main.async {
                if let message, out == nil { self?.error = message.contains("Not authorized") || message.contains("-1743")
                    ? "Allow MusicAmp to control \(app.name) in System Settings → Privacy & Security → Automation." : message }
                self?.update(out)
            }
        }
    }

    private func update(_ out: String?) {
        guard let out, out != "stopped" else {
            playing = false; title = ""; artist = ""; album = ""; duration = 0; position = 0; artwork = nil; trackKey = ""
            return
        }
        let f = out.components(separatedBy: "\n")
        guard f.count >= 6 else { return }
        let was = playing
        playing = f[0] == "playing"
        if playing != was { MainActor.assumeIsolated { Outputs.shared.playbackChanged() } }
        title = f[1]; artist = f[2]; album = f[3]
        var d = Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        if app == .spotify { d /= 1000 }
        duration = d
        position = Double(f[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        positionAt = Date()
        let key = "\(artist)|\(title)|\(album)"
        if key != trackKey {
            trackKey = key
            loadArtwork()
            Ctl.shared.externalTrackChanged()
        }
    }

    private func loadArtwork() {
        artwork = nil
        let app = self.app, key = trackKey
        queue.async { [weak self] in
            var img: NSImage?
            if app == .music {
                var err: NSDictionary?
                let d = NSAppleScript(source: "tell application \"Music\" to get raw data of artwork 1 of current track")?.executeAndReturnError(&err).data
                img = d.flatMap(NSImage.init(data:))
            } else {
                var err: NSDictionary?
                if let s = NSAppleScript(source: "tell application \"Spotify\" to get artwork url of current track")?.executeAndReturnError(&err).stringValue,
                   let u = URL(string: s), let d = try? Data(contentsOf: u) {
                    img = NSImage(data: d)
                }
            }
            DispatchQueue.main.async {
                guard self?.trackKey == key else { return }
                self?.artwork = img
                DockIcon.shared.update()
                MainActor.assumeIsolated { Outputs.shared.trackChanged() }
            }
        }
    }
}
