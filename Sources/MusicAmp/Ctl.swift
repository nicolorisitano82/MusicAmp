import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// App controller: playback, settings, window docking and menus.
final class Ctl: NSObject, NSMenuItemValidation, NSMenuDelegate, ObservableObject {
    static let shared = Ctl()

    var skin: Skin = Skin.fallback { didSet { notify() } }
    private(set) var skinPath: String?
    let audio = AudioEngine()
    let playlist = Playlist()

    let mainView = MainView(frame: .zero)
    let eqView = EqView(frame: .zero)
    let plView = PlaylistView(frame: .zero)
    private(set) var mainWindow: SkinWindow!
    private(set) var eqWindow: SkinWindow!
    private(set) var plWindow: SkinWindow!

    // Settings (didSet notify() keeps the SwiftUI preferences panel in sync with clicks on the skin)
    var doubleSize = false { didSet { notify() } }
    /// Use the @2x bitmaps of Retina skins when the screen (or double size) has the pixels for them.
    var retinaSkins = true { didSet { notify(); windows.forEach { $0.contentView?.needsDisplay = true } } }
    var alwaysOnTop = false { didSet { notify() } }
    var shuffle = false { didSet { notify(); if shuffle != oldValue { invalidateTransition() } } }
    var repeatOn = false { didSet { notify(); if repeatOn != oldValue { invalidateTransition() } } }
    // Transitions and loudness
    var gapless = true { didSet { applyTransitionSettings(); notify() } }
    var crossfadeOn = false { didSet { applyTransitionSettings(); notify() } }
    var crossfadeSeconds: Double = 5 { didSet { applyTransitionSettings(); notify() } }
    var rgMode = 1 { didSet { applyTransitionSettings(); notify() } }   // 0 off, 1 track, 2 album
    var rgPreamp: Double = 0 { didSet { applyTransitionSettings(); notify() } }
    var rgAnalyze = true { didSet { applyTransitionSettings(); notify() } }
    var rgPreventClip = true { didSet { applyTransitionSettings(); notify() } }
    var timeRemaining = false { didSet { notify() } }
    var visMode = 0 { didSet { notify() } }   // 0 spectrum, 1 oscilloscope, 2 off
    var volume: Double = 75 { didSet { audio.setVolume(volume) } }
    var balance: Double = 0 { didSet { audio.setBalance(balance) } }
    var eqOn = true { didSet { applyEQ() } }
    var eqAuto = false { didSet { if eqAuto, !oldValue { applyAutoEQ(announce: true) } } }
    var preamp: Double = 0 { didSet { applyEQ(); rememberAutoEQ() } }
    var bands = [Double](repeating: 0, count: 10) { didSet { applyEQ(); rememberAutoEQ() } }
    var mainShade = false
    var eqShade = false
    var plShade = false
    var eqVisible = true { didSet { notify() } }
    var plVisible = true { didSet { notify() } }
    var plW = 0
    var plH = 2

    // Preferences panel
    var snapEnabled = true { didSet { notify() } }
    var snapDistance: Double = 10 { didSet { notify() } }
    var marqueeScroll = true { didSet { notify() } }
    var resumeOnLaunch = false { didSet { notify() } }
    var outputDeviceUID: String? { didSet { notify() } }
    var visThinBands = false { didSet { notify() } }
    var visPeaksOn = true { didSet { notify() } }
    var visFalloff = 2 { didSet { notify() } }      // 0 slowest ... 4 fastest
    var peakFalloff = 2 { didSet { notify() } }
    var oscStyle = 1 { didSet { notify() } }        // 0 dots, 1 lines, 2 solid
    var plFontSize = 9 { didSet { notify() } }
    var plShowNumbers = true { didSet { notify() } }
    /// Playlist grouped artist → album → track instead of the flat list.
    var plTree = false { didSet { notify(); plView.needsDisplay = true } }
    var plUseSkinFont = true { didSet { notify() } }
    var ffmpegEnabled = true { didSet { FFmpeg.enabled = ffmpegEnabled; notify() } }
    /// Seconds of radio audio buffered before playback starts (and after an underrun).
    var radioBuffer: Double = 2 { didSet { audio.bufferSeconds = radioBuffer; notify() } }
    var menuBarEnabled = true { didSet { menuBar?.setEnabled(menuBarEnabled); notify() } }
    var notifyTrackChange = true { didSet { notify() } }
    var notifyOnlyInBackground = true { didSet { notify() } }
    var autoDownloadFonts = true { didSet { FontResolver.shared.autoDownload = autoDownloadFonts; notify() } }

    // Transient UI state
    var marqueeOverride: String?
    /// The title is being dragged by hand: auto-scroll waits.
    var marqueeDragging = false
    /// "It really whips the llama's ass" title bar, toggled with ⌃⇧ + "nullsoft" as in Winamp.
    var easterEgg = false
    private var eggKeys = ""
    var marqueeOffset: CGFloat = 0
    private(set) var tickCount = 0
    private(set) var visBars = [Float](repeating: 0, count: 75)
    private(set) var visPeaks = [Float](repeating: 0, count: 75)
    private var peakFall = [Float](repeating: 0, count: 75)
    private(set) var visWave = [Float](repeating: 0, count: 76)
    private var timer: Timer?
    var prefsWindowRef: NSWindow?
    var libraryWindowRef: NSWindow?
    var radioWindowRef: NSWindow?
    var podcastWindowRef: NSWindow?
    var lyricsWindowRef: NSWindow?
    var karaokeWindowRef: NSWindow?
    var milkdropWindowRef: NSWindow?
    var milkdropController: MilkdropController?
    private var menuBar: MenuBarController?
    private var notifier: TrackNotifier?
    /// True once output was routed to an explicit device; from then on the default must be re-applied by hand.
    private var outputPinned = false
    var infoWindows: [SkinWindow] = []
    var jumpPanelRef: NSPanel?
    var jumpModelRef: JumpModel?
    var jumpKeyMonitor: Any?
    /// Debug snapshots: draw visualizers as if playing.
    var snapshotMode = false

    func debugFillVis() {
        for i in 0..<75 {
            visBars[i] = Float(0.35 + 0.6 * abs(sin(Double(i) / 9)))
            visPeaks[i] = min(1, visBars[i] + 0.12)
        }
    }
    private var nowPlaying: NowPlaying?

    private func notify() { objectWillChange.send() }

    var scale: CGFloat { doubleSize ? 2 : 1 }
    var windows: [SkinWindow] { [mainWindow, eqWindow, plWindow].compactMap { $0 } }
    var visibleWindows: [SkinWindow] { windows.filter(\.isVisible) }
    /// Windows that dock and snap together: the skin windows plus the lyrics panel (not in full screen).
    var dockWindows: [NSWindow] {
        var w: [NSWindow] = visibleWindows
        if let l = lyricsWindowRef, l.isVisible, !l.styleMask.contains(.fullScreen) { w.append(l) }
        return w
    }

    /// Custom presets (bands 60 Hz…16 kHz in dB, then preamp). Preamp compensates the largest boost to avoid clipping.
    static let artistPresets: [(String, [Double], Double)] = [
        // Taylor Swift: vocal-forward across country-pop, Antonoff synth-pop (sub-bass) and folklore-style acoustic.
        // Light sub, scoop the 310–600 Hz box, presence at 3 kHz for lyrics, air above 12 kHz for breathy vocals.
        ("TS", [3.2, 1.2, -1.6, -1.2, 0.4, 2.4, 2.0, 2.4, 2.8, 2.0], -3.0),
        // Olivia Rodrigo: pop-punk drums/guitars and belted vocals plus piano ballads.
        // Kick/snare punch, cut guitar mud at 310 Hz, crunch at 1 kHz, restrained 3 kHz (no harsh belts), bright cymbals.
        ("OR", [4.0, 2.4, -2.4, -1.2, 1.2, 1.6, 0.8, 2.4, 3.2, 2.0], -4.0),
    ]

    /// Winamp's built-in presets, values as stored in the original winamp.q1 (dB, preamp 0).
    static let presets: [(String, [Double])] = [
        ("Classical", [0, 0, 0, 0, 0, 0, -4.9, -4.9, -4.9, -6.4]),
        ("Club", [0, 0, 1.9, 3.5, 3.5, 3.5, 1.9, 0, 0, 0]),
        ("Dance", [5.8, 4.3, 1.2, -0.4, -0.4, -4.1, -4.9, -4.9, -0.4, -0.4]),
        ("Full Bass", [5.8, 5.8, 5.8, 3.5, 0.8, -3, -5.6, -6.8, -7.1, -7.1]),
        ("Full Bass & Treble", [4.3, 3.5, 0, -4.9, -3.4, 0.8, 5, 6.6, 7.4, 7.4]),
        ("Full Treble", [-6.4, -6.4, -6.4, -3, 1.5, 6.6, 9.7, 9.7, 9.7, 10.5]),
        ("Laptop speakers/headphones", [2.7, 6.6, 3.1, -2.6, -1.9, 0.8, 2.7, 5.8, 7.7, 8.9]),
        ("Large hall", [6.2, 6.2, 3.5, 3.5, 0, -3.4, -3.4, -3.4, 0, 0]),
        ("Live", [-3.4, 0, 2.3, 3.1, 3.5, 3.5, 2.3, 1.5, 1.5, 1.2]),
        ("Party", [4.3, 4.3, 0, 0, 0, 0, 0, 0, 4.3, 4.3]),
        ("Pop", [-1.5, 2.7, 4.3, 4.6, 3.1, -1.1, -1.9, -1.9, -1.5, -1.5]),
        ("Reggae", [0, 0, -0.8, -4.1, 0, 3.9, 3.9, 0, 0, 0]),
        ("Rock", [4.6, 2.7, -3.8, -5.2, -2.6, 2.3, 5.4, 6.6, 6.6, 6.6]),
        ("Ska", [-1.9, -3.4, -3, -0.8, 2.3, 3.5, 5.4, 5.8, 6.6, 5.8]),
        ("Soft", [2.7, 0.8, -1.1, -1.9, -1.1, 2.3, 5, 5.8, 6.6, 7.4]),
        ("Soft Rock", [2.3, 2.3, 1.2, -0.8, -3, -3.8, -2.6, -0.8, 1.5, 5.4]),
        ("Techno", [4.6, 3.5, 0, -3.8, -3.4, 0, 4.6, 5.8, 5.8, 5.4]),
    ]

    // MARK: Startup

    func start() {
        loadSettings()
        audio.onFinish = { [weak self] in
            self?.finishedListening()
            self?.next(auto: true)
        }
        audio.onChange = { [weak self] in self?.transportChanged() }
        audio.onStreamInfo = { [weak self] in self?.streamInfoChanged() }
        audio.nextProvider = { [weak self] in self?.peekNext() }
        audio.onAdvance = { [weak self] i in self?.didAdvance(to: i) }
        audio.gainProvider = { ReplayGain.shared.gain(for: $0) }
        ReplayGain.shared.onUpdate = { [weak self] u in self?.audio.refreshGain(for: u) }
        applyTransitionSettings()
        nowPlaying = NowPlaying(ctl: self)
        playlist.onCurrentMetadata = { [weak self] in self?.nowPlaying?.update() }
        loadAutoEQ()
        mainWindow = SkinWindow(view: mainView)
        eqWindow = SkinWindow(view: eqView)
        plWindow = SkinWindow(view: plView)
        mainWindow.title = "MusicAmp"
        eqWindow.title = "Equalizzatore"
        plWindow.title = "Playlist"
        if let p = skinPath, let s = try? Skin.load(from: URL(fileURLWithPath: p)) { skin = s } else { skinPath = nil }
        layoutInitial()
        applyLevel()
        applyEQ()
        audio.setVolume(volume)
        audio.setBalance(balance)
        if outputDeviceUID != nil { selectOutput(outputDeviceUID) }
        AudioDevice.observeDefaultOutput { [weak self] in
            // Control Center / AirPlay picker changed the system output: follow it unless a device is pinned.
            guard let self, self.outputDeviceUID == nil, self.outputPinned else { return }
            self.audio.setOutputDevice(uid: nil)
        }
        menuBar = MenuBarController(ctl: self)
        menuBar?.setEnabled(menuBarEnabled)
        notifier = TrackNotifier(ctl: self)
        HotKeys.shared.onAction = { [weak self] in self?.globalHotKey($0) }
        HotKeys.shared.apply()
        restorePlaylist()

        mainWindow.makeKeyAndOrderFront(nil)
        if eqVisible { eqWindow.orderFront(nil) }
        if plVisible { plWindow.orderFront(nil) }
        updateWindowGroups()
        if ProcessInfo.processInfo.environment["MUSICAMP_TEST_GROUPS"] != nil { debugGroupSequence() }

        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                guard let self, let w = n.object as? NSWindow, self.windows.contains(where: { $0 === w }) else { return }
                w.contentView?.needsDisplay = true
                self.wake()
            }
        }
        setTimerInterval(Self.activeInterval)
        nowPlaying?.update()
    }

    // MARK: Render pacing
    // Fast (30 fps) only while the visualizer animates; ~9 Hz for marquee/clock/blink; 2 Hz when idle.
    // Each tick redraws only the windows whose rendered state changed (SkinView.renderSignature).

    static let fastInterval: TimeInterval = 1.0 / 30
    static let activeInterval: TimeInterval = 0.11
    static let idleInterval: TimeInterval = 0.5

    private var timerInterval: TimeInterval = 0
    private var lastMarqueeStep = Date.distantPast
    private var lastSave = Date()
    private var lastPositionSave = Date()
    private var lastTrack: Track?

    /// Paused time display blinks at 1 Hz like Winamp.
    var blinkOn: Bool { Int(Date().timeIntervalSinceReferenceDate * 2) % 2 == 0 }

    private func isShowing(_ w: NSWindow?) -> Bool {
        guard let w, w.isVisible else { return false }
        return w.occlusionState.contains(.visible)
    }

    /// Playlist hosts the visualizer while the main window is shaded and the playlist is wide enough.
    var plVisDisplayed: Bool { mainShade && plW >= 3 && !plShade }

    private var visShown: Bool { visMode != 2 && (isShowing(mainWindow) || (plVisDisplayed && isShowing(plWindow))) }

    private var marqueeScrolls: Bool {
        marqueeScroll && marqueeOverride == nil && !marqueeDragging && !mainShade && isShowing(mainWindow) && marqueeText.count * 5 > 154
    }

    private func setTimerInterval(_ i: TimeInterval) {
        guard i != timerInterval else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: i, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = i * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        timerInterval = i
    }

    /// Something changed outside the views (transport, settings): tick soon at active pace.
    func wake() {
        if timerInterval > Self.activeInterval { setTimerInterval(Self.activeInterval) }
    }

    private func transportChanged() {
        if playlist.currentTrack !== lastTrack {
            lastTrack = playlist.currentTrack
            applyAutoEQ(announce: true)
            refreshLyrics()
        }
        nowPlaying?.update()
        notifier?.transportChanged()
        menuBar?.update()
        notify()
        mainView.needsDisplay = true
        plView.needsDisplay = true
        wake()
    }

    private func globalHotKey(_ a: HotKeyAction) {
        switch a {
        case .playPause: if audio.state == .playing { pause() } else { play() }
        case .stop: stop()
        case .next: next()
        case .previous: previous()
        case .volumeUp:
            volume = min(100, volume + 5)
            flashMarquee("VOLUME: \(Int(volume.rounded()))%", seconds: 1)
        case .volumeDown:
            volume = max(0, volume - 5)
            flashMarquee("VOLUME: \(Int(volume.rounded()))%", seconds: 1)
        case .seekForward: seek(by: 5)
        case .seekBack: seek(by: -5)
        case .showHide:
            if NSApp.isActive, mainWindow.isVisible {
                NSApp.hide(nil)
            } else {
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
        mainView.needsDisplay = true
    }

    // MARK: Speed, pitch, resume (podcasts and audiobooks)

    /// Speed for music; each podcast keeps its own (default `podcastSpeed`); radio always plays at 1×.
    var musicSpeed: Double = 1 { didSet { applySpeed(); notify() } }
    var podcastSpeed: Double = 1 { didSet { applySpeed(); notify() } }
    /// Pitch shift for music, in semitones.
    var pitchSemitones: Double = 0 { didSet { applySpeed(); notify() } }

    var currentEpisode: (PodcastFeed, PodcastEpisode)? {
        playlist.currentTrack.flatMap { $0.isEpisode ? PodcastStore.shared.lookup($0.url) : nil }
    }

    func applySpeed() {
        guard let t = playlist.currentTrack else { audio.rate = musicSpeed; audio.pitchCents = pitchSemitones * 100; return }
        if t.isStream {
            audio.rate = 1
            audio.pitchCents = 0
        } else if let (f, _) = currentEpisode {
            audio.rate = f.speed ?? podcastSpeed
            audio.pitchCents = 0
        } else {
            audio.rate = musicSpeed
            audio.pitchCents = pitchSemitones * 100
        }
    }

    func setSpeed(_ v: Double) {
        let v = (max(0.5, min(3, v)) * 100).rounded() / 100
        if let (f, _) = currentEpisode {
            PodcastStore.shared.setSpeed(f.feedURL, v)
        } else if playlist.currentTrack?.isStream == true {
            flashMarquee("LA RADIO VA A 1X")
            return
        } else {
            musicSpeed = v
        }
        applySpeed()
        flashMarquee(String(format: "VELOCITA %.2gX", v), seconds: 1.5)
        notify()
    }

    @objc func setSpeedItem(_ s: NSMenuItem) { setSpeed(Double(s.tag) / 100) }
    @objc func faster() { setSpeed(audio.rate + 0.25) }
    @objc func slower() { setSpeed(audio.rate - 0.25) }
    @objc func pitchUp() { pitchSemitones = min(12, pitchSemitones + 1); flashPitch() }
    @objc func pitchDown() { pitchSemitones = max(-12, pitchSemitones - 1); flashPitch() }
    @objc func pitchReset() { pitchSemitones = 0; flashPitch() }
    private func flashPitch() { flashMarquee(pitchSemitones == 0 ? "INTONAZIONE ORIGINALE" : String(format: "INTONAZIONE %+.0f SEMITONI", pitchSemitones), seconds: 1.5) }
    @objc func skipBack15() { seek(by: -15) }
    @objc func skipForward30() { seek(by: 30) }

    /// Where to resume: the episode's saved position, or an audiobook/long file's.
    private func resumePoint(for t: Track) -> Double? {
        if t.isEpisode, let (f, e) = PodcastStore.shared.lookup(t.url) {
            let s = PodcastStore.shared.state(f, e)
            return !s.played && s.position > 5 ? s.position : nil
        }
        guard t.url.isFileURL, let p = PlaybackPositions.shared.position(t.url), p > 5 else { return nil }
        return p
    }

    /// Saves the listening position of the current long file / episode (every 5 s while playing, and on pause).
    func savePosition() {
        guard let t = playlist.currentTrack, audio.hasSource, !t.isStream else { return }
        let pos = audio.currentTime, d = audio.duration
        if t.isEpisode, let (f, e) = PodcastStore.shared.lookup(t.url) {
            PodcastStore.shared.update(f, e) { s in
                s.position = pos
                if d > 0, pos > d - 30 { s.played = true; s.position = 0 }
            }
        } else if t.url.isFileURL, PlaybackPositions.remembers(t.url, duration: d) {
            PlaybackPositions.shared.set(t.url, d > 0 && pos > d - 10 ? nil : pos)
        }
    }

    /// Reached the end: episodes become "played", audiobooks start over next time.
    private func finishedListening() {
        guard let t = playlist.currentTrack else { return }
        if t.isEpisode, let (f, e) = PodcastStore.shared.lookup(t.url) {
            PodcastStore.shared.update(f, e) { $0.played = true; $0.position = 0 }
        } else if t.url.isFileURL {
            PlaybackPositions.shared.set(t.url, nil)
        }
    }

    /// Adds an episode to the playlist (downloaded file if present) and plays it.
    func playEpisode(_ feed: PodcastFeed, _ ep: PodcastEpisode, play: Bool = true) {
        guard let url = PodcastStore.shared.playableURL(feed, ep) else { return }
        let i: Int
        if let existing = playlist.tracks.firstIndex(where: { $0.url == url || $0.url.absoluteString == ep.enclosure }) {
            i = existing
            playlist.tracks[i] = makeEpisodeTrack(url, feed, ep)
        } else {
            playlist.tracks.append(makeEpisodeTrack(url, feed, ep))
            i = playlist.tracks.count - 1
        }
        if play { playIndex(i) } else { plView.ensureVisible(i) }
    }

    private func makeEpisodeTrack(_ url: URL, _ feed: PodcastFeed, _ ep: PodcastEpisode) -> Track {
        let t = Track(url: url, title: "\(feed.title) - \(ep.title)")
        t.artist = feed.title
        t.songTitle = ep.title
        t.album = feed.title
        t.duration = ep.duration
        return t
    }

    func speedMenu() -> NSMenu {
        let m = NSMenu(title: "Velocità")
        for v in [50, 75, 100, 125, 150, 175, 200, 250, 300] {
            item(m, String(format: "%.2g×", Double(v) / 100), #selector(setSpeedItem(_:)), tag: v)
        }
        m.addItem(.separator())
        item(m, "Più veloce", #selector(faster), "]")
        item(m, "Più lenta", #selector(slower), "[")
        m.addItem(.separator())
        item(m, "Intonazione +1 semitono", #selector(pitchUp), "]", [.command, .option])
        item(m, "Intonazione −1 semitono", #selector(pitchDown), "[", [.command, .option])
        item(m, "Intonazione originale", #selector(pitchReset))
        return m
    }

    // MARK: Gapless / crossfade / ReplayGain

    /// Shuffle pick announced ahead of time, so the transition and the playlist agree.
    private var pendingShuffle: Int?

    /// The track an automatic advance would play, without consuming the queue (nil = stop at the end).
    func peekNext() -> (index: Int, url: URL)? {
        let n = playlist.tracks.count
        guard n > 0, let cur = playlist.current else { return nil }
        var i: Int?
        if let q = playlist.queue.first, let qi = playlist.tracks.firstIndex(where: { $0 === q }) {
            i = qi
        } else if shuffle, n > 1 {
            if pendingShuffle == nil {
                var r: Int
                repeat { r = Int.random(in: 0..<n) } while r == cur
                pendingShuffle = r
            }
            i = pendingShuffle
        } else if cur + 1 < n {
            i = cur + 1
        } else if repeatOn {
            i = 0
        }
        guard let idx = i, playlist.tracks.indices.contains(idx), !playlist.tracks[idx].isStream else { return nil }
        return (idx, playlist.tracks[idx].url)
    }

    /// The engine moved to the prepared track on its own (gapless or crossfade).
    private func didAdvance(to index: Int) {
        guard playlist.tracks.indices.contains(index) else { return }
        let t = playlist.tracks[index]
        if let q = playlist.queue.first, q === t { playlist.queue.removeFirst() }
        pendingShuffle = nil
        playlist.currentTrack = t
        marqueeOffset = 0
        plView.ensureVisible(index)
    }

    /// Queue, shuffle or repeat changed: a prepared next track may no longer be the right one.
    func invalidateTransition() {
        pendingShuffle = nil
        audio.cancelTransition()
    }

    func applyTransitionSettings() {
        audio.crossfadeSeconds = crossfadeOn ? crossfadeSeconds : 0
        audio.gapless = gapless
        let rg = ReplayGain.shared
        rg.mode = ReplayGain.Mode(rawValue: rgMode) ?? .track
        rg.preamp = rgPreamp
        rg.analyzeUntagged = rgAnalyze
        rg.preventClipping = rgPreventClip
        audio.refreshGain()
    }

    func selectOutput(_ uid: String?) {
        outputDeviceUID = uid
        outputPinned = true
        audio.setOutputDevice(uid: uid)
    }

    private func tick() {
        tickCount += 1
        let now = Date()
        let playing = audio.state == .playing
        let showVis = visShown
        audio.analysisEnabled = playing && (showVis || audio.milkdropEnabled)
        var animating = false
        if showVis {
            animating = updateVis(playing: playing) || playing
        } else if visBars.contains(where: { $0 > 0 }) || visPeaks.contains(where: { $0 > 0 }) {
            visBars = [Float](repeating: 0, count: 75)
            visPeaks = [Float](repeating: 0, count: 75)
        }
        let scrolling = marqueeScrolls
        if scrolling, now.timeIntervalSince(lastMarqueeStep) >= 0.22 {
            marqueeOffset += 5
            lastMarqueeStep = now
        }

        if animating {
            if isShowing(mainWindow) { mainView.needsDisplay = true }
            if plVisDisplayed, isShowing(plWindow) { plView.needsDisplay = true }
        }
        for w in allSkinWindows where isShowing(w) { (w.contentView as? SkinView)?.refreshIfChanged() }

        if playing, now.timeIntervalSince(lastPositionSave) > 5 {
            lastPositionSave = now
            savePosition()
        }
        if now.timeIntervalSince(lastSave) > 30 {
            saveSettings()
            lastSave = now
        }
        let busy = playing || audio.state == .paused || scrolling || marqueeOverride != nil
        setTimerInterval(animating ? Self.fastInterval : (busy ? Self.activeInterval : Self.idleInterval))
    }

    /// Advances bars/peaks; returns true while anything is still moving.
    private func updateVis(playing: Bool) -> Bool {
        let (spec, wave) = audio.visData()
        let decay: [Float] = [0.012, 0.025, 0.045, 0.07, 0.1]
        let gravity: [Float] = [0.0004, 0.0008, 0.0015, 0.003, 0.006]
        let dec = decay[max(0, min(4, visFalloff))], grav = gravity[max(0, min(4, peakFalloff))]
        for i in 0..<75 {
            visBars[i] = max(playing ? spec[i] : 0, visBars[i] - dec)
            if visBars[i] >= visPeaks[i] {
                visPeaks[i] = visBars[i]
                peakFall[i] = 0
            } else {
                peakFall[i] += grav
                visPeaks[i] = max(0, visPeaks[i] - peakFall[i])
            }
        }
        visWave = playing ? wave : [Float](repeating: 0, count: 76)
        return visBars.contains { $0 > 0 } || visPeaks.contains { $0 > 0 }
    }

    func barValue(_ b: Int) -> Float {
        var m: Float = 0
        for i in (b * 4)..<min(75, b * 4 + 4) { m = max(m, visBars[i]) }
        return m
    }

    func barPeak(_ b: Int) -> Float {
        var m: Float = 0
        for i in (b * 4)..<min(75, b * 4 + 4) { m = max(m, visPeaks[i]) }
        return m
    }

    func redraw() {
        for w in allSkinWindows where w.isVisible { w.contentView?.needsDisplay = true }
        wake()
    }

    /// Main/EQ/playlist plus any skinned secondary (gen.bmp) windows.
    var allSkinWindows: [SkinWindow] { NSApp.windows.compactMap { $0 as? SkinWindow } }

    // MARK: Text helpers

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func hmmss(_ t: Double) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : mmss(t)
    }

    var marqueeText: String {
        guard let i = playlist.current else { return "MusicAmp" }
        let t = playlist.tracks[i]
        if t.isStream {
            if audio.isStream, audio.state == .playing, audio.stream.buffering {
                return "\(audio.stream.error ?? "Buffering…") \(t.title)"
            }
            return t.streamTitle.map { "\(i + 1). \($0) — \(t.title)" } ?? "\(i + 1). \(t.title)"
        }
        var s = "\(i + 1). \(t.title)"
        if let d = t.duration ?? (audio.duration > 0 ? audio.duration : nil) { s += " (\(Ctl.mmss(d)))" }
        return s
    }

    // MARK: Playback

    /// Selects track `i` and opens it off the main thread (opening may wait on a privacy prompt or a slow disk),
    /// then starts it when `start`. `then` runs on the main thread once the file is ready.
    func playIndex(_ i: Int, start: Bool = true, then: (() -> Void)? = nil) {
        guard playlist.tracks.indices.contains(i) else { return }
        pendingShuffle = nil
        let t = playlist.tracks[i]
        playlist.currentTrack = t
        marqueeOffset = 0
        plView.ensureVisible(i)
        loadToken &+= 1
        let resume = resumePoint(for: t)
        if !t.url.isFileURL && !t.isStream {
            // Podcast episode not downloaded: stream it with AVPlayer (seekable), from where you left off.
            if start { audio.playRemote(t.url, at: resume ?? 0, index: i) } else { audio.unload() }
            applySpeed()
            then?()
            return
        }
        if t.isStream {
            t.streamTitle = nil
            if start {
                audio.bufferSeconds = radioBuffer
                audio.playStream(t.url, name: t.title == (t.url.host ?? t.url.absoluteString) ? nil : t.title)
            } else {
                audio.unload()
            }
            then?()
            return
        }
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Native first (AVAudioFile); formats macOS can't read go through ffmpeg when installed.
            let ext = t.url.pathExtension.lowercased()
            let native = FFmpeg.extensions.contains(ext) ? nil : try? AVAudioFile(forReading: t.url)
            let probe = native == nil && FFmpeg.available ? FFmpeg.probe(t.url) : nil
            DispatchQueue.main.async {
                guard let self, self.loadToken == token else { return }   // another track was chosen meanwhile
                if let f = native {
                    self.audio.use(f, url: t.url, index: i)
                } else if let p = probe {
                    self.audio.useFFmpeg(url: t.url, probe: p, index: i)
                } else {
                    self.audio.unload()
                    let needsFFmpeg = FFmpeg.extensions.contains(ext) && FFmpeg.ffmpegPath == nil
                    self.flashMarquee(needsFFmpeg ? "SERVE FFMPEG: BREW INSTALL FFMPEG" : "IMPOSSIBILE APRIRE IL FILE", seconds: 3)
                    NSSound.beep()
                    return
                }
                if start {
                    self.audio.play()
                    if let r = resume, r < self.audio.duration - 10 { self.audio.seek(to: r) }
                }
                self.applySpeed()
                then?()
            }
        }
    }

    private var loadToken = 0

    @objc func play() {
        if !audio.hasSource || playlist.current == nil {
            if playlist.tracks.isEmpty { openFiles(); return }
            playIndex(playlist.current ?? playlist.selection.min() ?? 0)
            return
        }
        audio.play()
    }

    @objc func pause() {
        audio.pause()
        savePosition()
    }
    @objc func stop() { audio.stop() }

    @objc func next() { next(auto: false) }

    func next(auto: Bool) {
        let n = playlist.tracks.count
        guard n > 0 else { return }
        let wasPlaying = auto || audio.state != .stopped
        if let q = playlist.popQueue() {
            playIndex(q, start: wasPlaying)
            return
        }
        var i: Int
        if shuffle, n > 1 {
            // Reuse the pick already announced to the engine for a gapless/crossfade transition.
            if let p = pendingShuffle, p < n, p != playlist.current { i = p } else {
                repeat { i = Int.random(in: 0..<n) } while i == playlist.current
            }
        } else {
            i = (playlist.current ?? -1) + 1
            if i >= n {
                if auto, !repeatOn { audio.stop(); return }
                i = 0
            }
        }
        playIndex(i, start: wasPlaying)
    }

    @objc func previous() {
        let n = playlist.tracks.count
        guard n > 0 else { return }
        let wasPlaying = audio.state != .stopped
        var i = (playlist.current ?? 0) - 1
        if i < 0 { i = n - 1 }
        playIndex(i, start: wasPlaying)
    }

    func seek(by delta: Double) { audio.seek(to: audio.currentTime + delta) }

    func applyEQ() { audio.setEQ(on: eqOn, preamp: preamp, bands: bands) }

    // MARK: Files

    private func chooseAudio(directories: Bool = false, _ done: ([URL]) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = !directories
        if !directories { p.allowedContentTypes = [.audio, .m3uPlaylist, .folder] }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK { done(p.urls) }
    }

    @objc func openFiles() {
        chooseAudio { replacePlaylist($0, play: true) }
    }

    @objc func addFiles() { chooseAudio { playlist.add($0) } }
    @objc func addFolder() { chooseAudio(directories: true) { playlist.add($0) } }

    /// ADD URL in the playlist: appends a stream (or remote playlist) without starting it.
    @objc func addURL() { askURL(play: false) }

    /// File > Open URL (⌘U): adds the stream and plays it.
    @objc func openURL() { askURL(play: true) }

    private func askURL(play: Bool) {
        let a = NSAlert()
        a.messageText = play ? "Apri URL" : "Aggiungi URL"
        a.informativeText = "Indirizzo di una radio (stream MP3/AAC, HLS .m3u8) o di una playlist .pls/.m3u:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "https://…"
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { field.stringValue = s }
        a.accessoryView = field
        a.addButton(withTitle: play ? "Riproduci" : "Aggiungi")
        a.addButton(withTitle: "Annulla")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: text), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
            flashMarquee("URL NON VALIDO")
            return
        }
        addStream(u, title: nil, play: play)
    }

    /// Appends a radio stream to the playlist (reusing an existing entry for the same URL) and optionally plays it.
    func addStream(_ url: URL, title: String?, play: Bool) {
        let i: Int
        if let existing = playlist.tracks.firstIndex(where: { $0.url == url }) {
            i = existing
            if let title { playlist.tracks[i].title = title; playlist.touch() }
        } else {
            playlist.tracks.append(Track(url: url, title: title))
            i = playlist.tracks.count - 1
        }
        if play { playIndex(i) } else { plView.ensureVisible(i) }
    }

    /// Radio status from the engine: station name, live title, buffering and errors.
    private func streamInfoChanged() {
        guard audio.isStream, let t = playlist.currentTrack, t.isStream else { return }
        let info = audio.stream
        if let n = info.name, t.title == (t.url.host ?? t.url.absoluteString) { t.title = n }
        if t.streamTitle != info.title {
            t.streamTitle = info.title
            marqueeOffset = 0
            refreshLyrics()   // the radio moved on to another song
        }
        playlist.touch()
        if let e = info.error, audio.state == .stopped { flashMarquee(e.uppercased(), seconds: 3) }
        nowPlaying?.update()
        menuBar?.update()
        notify()
        mainView.needsDisplay = true
        plView.needsDisplay = true
        wake()
    }

    func replacePlaylist(_ urls: [URL], play: Bool) {
        audio.unload()
        playlist.clear()
        playlist.add(urls)
        plView.scrollRow = 0
        if play, !playlist.tracks.isEmpty { playIndex(0) }
    }

    @objc func clearPlaylist() {
        playlist.clear()
        plView.scrollRow = 0
    }

    func handleDrop(_ urls: [URL], toPlaylist: Bool) {
        if let s = urls.first(where: { ["wsz", "zip"].contains($0.pathExtension.lowercased()) }) {
            installAndApplySkin(s)
            return
        }
        if toPlaylist { playlist.add(urls) } else { replacePlaylist(urls, play: true) }
    }

    @objc func loadPlaylistFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.m3uPlaylist, UTType(filenameExtension: "m3u8"), UTType(filenameExtension: "pls")].compactMap { $0 }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { replacePlaylist([u], play: false) }
    }

    @objc func savePlaylistFile() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.m3uPlaylist]
        p.nameFieldStringValue = "Playlist.m3u"
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url {
            do { try playlist.writeM3U(to: u) } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc func fileInfo() { showFileInfo(playlist.current) }

    func showFileInfo(_ index: Int?) {
        guard let i = index, playlist.tracks.indices.contains(i) else { NSSound.beep(); return }
        showInfoWindow(i)
    }

    // MARK: Skins

    var skinsDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Skins", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @objc func chooseSkin() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "wsz"), .zip].compactMap { $0 }
        p.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { installAndApplySkin(u) }
    }

    /// Copies the skin into ~/Library/Application Support/MusicAmp/Skins (so it shows in the menu) and applies it.
    func installAndApplySkin(_ url: URL) {
        var target = url
        let dir = skinsDir
        if !url.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path) {
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.copyItem(at: url, to: dst) }
            if FileManager.default.fileExists(atPath: dst.path) { target = dst }
        }
        applySkin(target)
    }

    func applySkin(_ url: URL?) {
        if let url {
            do {
                skin = try Skin.load(from: url)
                skinPath = url.path
            } catch {
                let a = NSAlert(error: error)
                a.messageText = "Impossibile caricare \(url.lastPathComponent)"
                a.runModal()
                return
            }
        } else {
            skin = Skin.fallback
            skinPath = nil
        }
        for w in windows { w.invalidateCursorRects(for: w.contentView!) }
        redraw()
        saveSettings()
    }

    @objc func selectSkinItem(_ sender: NSMenuItem) { applySkin(sender.representedObject as? URL) }
    @objc func openSkinsFolder() { NSWorkspace.shared.open(skinsDir) }
    @objc func openSkinMuseum() { NSWorkspace.shared.open(URL(string: "https://skins.webamp.org")!) }

    func installedSkins() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: skinsDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wsz", "zip"].contains($0.pathExtension.lowercased()) || $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func populateSkinsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        item(menu, "Carica skin…", #selector(chooseSkin), "k")
        let def = item(menu, "Skin predefinita", #selector(selectSkinItem(_:)))
        def.representedObject = nil
        menu.addItem(.separator())
        let files = installedSkins()
        for f in files {
            let it = item(menu, f.deletingPathExtension().lastPathComponent, #selector(selectSkinItem(_:)))
            it.representedObject = f
        }
        if !files.isEmpty { menu.addItem(.separator()) }
        item(menu, "Apri cartella skin", #selector(openSkinsFolder))
        item(menu, "Scarica skin (Winamp Skin Museum)…", #selector(openSkinMuseum))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Skin" { populateSkinsMenu(menu) }
    }

    // MARK: Windows

    private func size(of v: SkinView) -> CGSize {
        CGSize(width: v.logicalSize.width * scale, height: v.logicalSize.height * scale)
    }

    private func place(_ w: NSWindow, _ v: SkinView, topLeft: CGPoint) {
        let s = size(of: v)
        w.setFrame(CGRect(x: topLeft.x, y: topLeft.y - s.height, width: s.width, height: s.height), display: true)
    }

    private func layoutInitial() {
        let d = UserDefaults.standard
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        func saved(_ k: String) -> CGPoint? {
            guard let a = d.array(forKey: k) as? [Double], a.count == 2 else { return nil }
            let p = CGPoint(x: a[0], y: a[1])
            return NSScreen.screens.contains { $0.frame.insetBy(dx: -10, dy: -10).contains(p) } ? p : nil
        }
        let m = saved("pos.main") ?? CGPoint(x: (screen.midX - size(of: mainView).width / 2).rounded(), y: screen.maxY - 60)
        place(mainWindow, mainView, topLeft: m)
        place(eqWindow, eqView, topLeft: saved("pos.eq") ?? CGPoint(x: m.x, y: mainWindow.frame.minY))
        place(plWindow, plView, topLeft: saved("pos.pl") ?? CGPoint(x: m.x, y: eqWindow.frame.minY))
    }

    /// Resizes a window keeping its top-left; windows docked below it follow when `moveDocked`.
    func refit(_ w: NSWindow, _ v: SkinView, moveDocked: Bool) {
        let old = w.frame
        let s = size(of: v)
        guard old.size != s else { v.needsDisplay = true; return }
        // Children follow their parent's origin on their own: detach so docked windows move exactly once.
        detachGroups()
        defer { updateWindowGroups() }
        let below = moveDocked ? windowsBelow(w) : []
        let nf = CGRect(x: old.minX, y: old.maxY - s.height, width: s.width, height: s.height)
        w.setFrame(nf, display: true)
        let dy = nf.minY - old.minY
        for b in below { b.setFrameOrigin(NSPoint(x: b.frame.minX, y: b.frame.minY + dy)) }
        w.invalidateCursorRects(for: v)
        v.needsDisplay = true
    }

    private func windowsBelow(_ w: NSWindow) -> [NSWindow] {
        var res: [NSWindow] = []
        var queue: [NSWindow] = [w]
        while let cur = queue.popLast() {
            for o in dockWindows where o !== w && !res.contains(o) {
                let a = cur.frame, b = o.frame
                if abs(b.maxY - a.minY) <= 1, b.minX < a.maxX, b.maxX > a.minX {
                    res.append(o)
                    queue.append(o)
                }
            }
        }
        return res
    }

    private func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let xo = a.minX < b.maxX && a.maxX > b.minX
        let yo = a.minY < b.maxY && a.maxY > b.minY
        return (xo && (abs(a.minY - b.maxY) <= 1 || abs(a.maxY - b.minY) <= 1))
            || (yo && (abs(a.minX - b.maxX) <= 1 || abs(a.maxX - b.minX) <= 1))
    }

    private func connected(from w: NSWindow) -> [NSWindow] {
        var res: [NSWindow] = [w]
        var queue: [NSWindow] = [w]
        while let c = queue.popLast() {
            for o in dockWindows where !res.contains(o) && touches(c.frame, o.frame) {
                res.append(o)
                queue.append(o)
            }
        }
        return res
    }

    // MARK: Window groups (Mission Control)
    // Docked windows become child windows of one root (main if present, else EQ, else playlist), so Mission
    // Control/Exposé shows them as a single window and they move together; undocked windows stay separate.

    func detachGroups() {
        for w in windows { for c in w.childWindows ?? [] where c is SkinWindow || c === lyricsWindowRef { w.removeChildWindow(c) } }
        if let l = lyricsWindowRef { for c in l.childWindows ?? [] { l.removeChildWindow(c) } }
    }

    func updateWindowGroups() {
        guard mainWindow != nil else { return }
        detachGroups()
        var remaining = dockWindows
        while let first = remaining.first {
            let group = connected(from: first)
            remaining.removeAll { w in group.contains { $0 === w } }
            let root: NSWindow = group.first { $0 === mainWindow } ?? group.first { $0 === eqWindow } ?? first
            for w in group where w !== root { root.addChildWindow(w, ordered: .above) }
        }
        if ProcessInfo.processInfo.environment["MUSICAMP_DEBUG_GROUPS"] != nil {
            let line = dockWindows.map { w in "\(w.title)\((w.childWindows ?? []).map(\.title))" }.joined(separator: " ")
            NSLog("groups: %@", line)
        }
    }

    /// Debug (MUSICAMP_TEST_GROUPS): runs the drag/dock code paths on the real windows and logs the groups.
    func debugGroupSequence() {
        let pl = plWindow!, eq = eqWindow!, main = mainWindow!
        let home = (main.frame.origin, eq.frame.origin, pl.frame.origin)
        func step(_ name: String, _ after: Double, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                body()
                let line = self.windows.map { w in "\(w.title)\((w.childWindows ?? []).map(\.title))" }.joined(separator: " ")
                NSLog("step %@ -> %@ | pl at %@", name, line, NSStringFromPoint(pl.frame.origin))
            }
        }
        step("1 stacca playlist", 0.5) { self.beginDrag(pl); pl.setFrameOrigin(NSPoint(x: pl.frame.minX + 400, y: pl.frame.minY)); self.endDrag() }
        step("2 riaggancia playlist", 1.0) { self.beginDrag(pl); pl.setFrameOrigin(NSPoint(x: eq.frame.minX, y: eq.frame.minY - pl.frame.height)); self.endDrag() }
        step("3 stacca EQ+playlist sotto", 1.5) {
            self.beginDrag(eq); eq.setFrameOrigin(NSPoint(x: eq.frame.minX + 400, y: eq.frame.minY)); self.endDrag()
            self.beginDrag(pl); pl.setFrameOrigin(NSPoint(x: eq.frame.minX, y: eq.frame.minY - pl.frame.height)); self.endDrag()
        }
        step("4 sposta principale (EQ+PL restano)", 2.0) {
            self.beginDrag(main); main.setFrameOrigin(NSPoint(x: main.frame.minX, y: main.frame.minY - 30)); self.endDrag()
        }
        step("5 ripristina", 2.5) {
            self.detachGroups()
            main.setFrameOrigin(home.0); eq.setFrameOrigin(home.1); pl.setFrameOrigin(home.2)
            self.updateWindowGroups()
        }
    }

    // Window dragging with docking (main drags its docked group) and 10 px edge snapping.
    private var dragWindow: NSWindow?
    private var dragGroup: [NSWindow] = []
    private var dragOrigins: [NSWindow: NSPoint] = [:]
    private var dragMouse = NSPoint.zero

    func beginDrag(_ w: NSWindow) {
        dragWindow = w
        dragMouse = NSEvent.mouseLocation
        dragGroup = w === mainWindow ? connected(from: w) : [w]
        if w !== mainWindow {
            // EQ/playlist leave their group when dragged (Winamp): detach them and their own children.
            w.parent?.removeChildWindow(w)
            for c in w.childWindows ?? [] { w.removeChildWindow(c) }
        }
        dragOrigins = Dictionary(uniqueKeysWithValues: dragGroup.map { ($0, $0.frame.origin) })
    }

    func continueDrag() {
        guard dragWindow != nil else { return }
        let m = NSEvent.mouseLocation
        var dx = m.x - dragMouse.x, dy = m.y - dragMouse.y
        let moved = dragGroup.compactMap { g in dragOrigins[g].map { CGRect(origin: CGPoint(x: $0.x + dx, y: $0.y + dy), size: g.frame.size) } }
        guard let first = moved.first else { return }
        let union = moved.dropFirst().reduce(first) { $0.union($1) }
        let others = dockWindows.filter { w in !dragGroup.contains { $0 === w } }.map(\.frame)
        let screen = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let s = snapEnabled ? snapDelta(union, others, screen) : .zero
        dx += s.x
        dy += s.y
        for g in dragGroup {
            if let o = dragOrigins[g] { g.setFrameOrigin(NSPoint(x: o.x + dx, y: o.y + dy)) }
        }
    }

    func endDrag() {
        dragWindow = nil
        dragGroup = []
        dragOrigins = [:]
        updateWindowGroups()   // dropped against another window = docked again
    }

    private func snapDelta(_ f: CGRect, _ targets: [CGRect], _ screen: CGRect) -> CGPoint {
        let T = CGFloat(snapDistance)
        var bx: CGFloat?, by: CGFloat?
        func consider(_ d: CGFloat, _ best: inout CGFloat?) {
            if abs(d) <= T, best == nil || abs(d) < abs(best!) { best = d }
        }
        for t in targets {
            if f.minY <= t.maxY + T, f.maxY >= t.minY - T {
                consider(t.maxX - f.minX, &bx); consider(t.minX - f.maxX, &bx)
                consider(t.minX - f.minX, &bx); consider(t.maxX - f.maxX, &bx)
            }
            if f.minX <= t.maxX + T, f.maxX >= t.minX - T {
                consider(t.maxY - f.minY, &by); consider(t.minY - f.maxY, &by)
                consider(t.minY - f.minY, &by); consider(t.maxY - f.maxY, &by)
            }
        }
        if !screen.isEmpty {
            consider(screen.minX - f.minX, &bx); consider(screen.maxX - f.maxX, &bx)
            consider(screen.minY - f.minY, &by); consider(screen.maxY - f.maxY, &by)
        }
        return CGPoint(x: bx ?? 0, y: by ?? 0)
    }

    @objc func toggleEQ() {
        eqVisible.toggle()
        detachGroups()   // a hidden child would come back with its parent
        if eqVisible { eqWindow.orderFront(nil) } else { eqWindow.orderOut(nil) }
        updateWindowGroups()
    }

    @objc func togglePL() {
        plVisible.toggle()
        detachGroups()
        if plVisible { plWindow.orderFront(nil) } else { plWindow.orderOut(nil) }
        updateWindowGroups()
    }

    @objc func toggleMainShade() {
        mainShade.toggle()
        refit(mainWindow, mainView, moveDocked: true)
    }

    @objc func togglePLShade() {
        plShade.toggle()
        refit(plWindow, plView, moveDocked: true)
    }

    @objc func toggleEQShade() {
        eqShade.toggle()
        refit(eqWindow, eqView, moveDocked: true)
    }

    @objc func toggleDoubleSize() {
        let old = scale
        doubleSize.toggle()
        let new = scale
        let anchor = CGPoint(x: mainWindow.frame.minX, y: mainWindow.frame.maxY)
        detachGroups()
        defer { updateWindowGroups() }
        for w in windows {
            guard let v = w.contentView as? SkinView else { continue }
            let tl = CGPoint(x: w.frame.minX, y: w.frame.maxY)
            place(w, v, topLeft: CGPoint(x: anchor.x + (tl.x - anchor.x) * new / old, y: anchor.y + (tl.y - anchor.y) * new / old))
            w.invalidateCursorRects(for: v)
        }
    }

    @objc func toggleAlwaysOnTop() {
        alwaysOnTop.toggle()
        applyLevel()
    }

    private func applyLevel() {
        for w in windows { w.level = alwaysOnTop ? .floating : .normal }
    }

    func setPlaylistSize(_ w: Int, _ h: Int) {
        plW = w
        plH = h
        refit(plWindow, plView, moveDocked: false)
        plView.clampScroll()
    }

    // MARK: Keyboard (Winamp shortcuts)

    func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) { return false }
        if e.modifierFlags.contains(.control), e.modifierFlags.contains(.shift) {
            eggKeys = String((eggKeys + (e.charactersIgnoringModifiers ?? "").lowercased()).suffix(8))
            if eggKeys == "nullsoft" {
                eggKeys = ""
                easterEgg.toggle()
                // Some skins repeat the normal title in the easter-egg rows: the display always says it.
                flashMarquee(easterEgg ? "IT REALLY WHIPS THE LLAMA'S ASS!" : "NULLSOFT", seconds: 3)
                mainView.needsDisplay = true
            }
            return true
        }
        switch e.keyCode {
        case 123: seek(by: -5); return true
        case 124: seek(by: 5); return true
        case 126: volume = min(100, volume + 2); return true
        case 125: volume = max(0, volume - 2); return true
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "z": previous()
        case "x": play()
        case "c": pause()
        case "v": stop()
        case "b": next()
        case "l": if e.modifierFlags.contains(.shift) { addFolder() } else { openFiles() }
        case "s": shuffle.toggle()
        case "r": repeatOn.toggle()
        case "j": showJumpToFile()
        case "q": queueSelected()
        default: return false
        }
        return true
    }

    // MARK: Menus

    @discardableResult
    func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
              _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        it.tag = tag
        m.addItem(it)
        return it
    }

    func skinsSubmenuItem() -> NSMenuItem {
        let it = NSMenuItem(title: "Skin", action: nil, keyEquivalent: "")
        let m = NSMenu(title: "Skin")
        m.delegate = self
        it.submenu = m
        return it
    }

    func visMenu() -> NSMenu {
        let m = NSMenu(title: "Visualizzazione")
        item(m, "Analizzatore di spettro", #selector(setVisMode(_:)), tag: 0)
        item(m, "Oscilloscopio", #selector(setVisMode(_:)), tag: 1)
        item(m, "Disattivata", #selector(setVisMode(_:)), tag: 2)
        return m
    }

    func optionsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Apri file…", #selector(openFiles))
        item(m, "Info file…", #selector(fileInfo))
        m.addItem(.separator())
        m.addItem(skinsSubmenuItem())
        let vis = NSMenuItem(title: "Visualizzazione", action: nil, keyEquivalent: "")
        vis.submenu = visMenu()
        m.addItem(vis)
        m.addItem(.separator())
        item(m, "Preferenze…", #selector(showPreferences))
        item(m, "Libreria…", #selector(showLibrary))
        item(m, "Radio…", #selector(showRadio))
        item(m, "Podcast…", #selector(showPodcasts))
        item(m, "Testi…", #selector(showLyrics))
        item(m, "Karaoke a schermo intero", #selector(showKaraoke))
        item(m, "Milkdrop", #selector(showMilkdrop))
        item(m, "Apri URL…", #selector(openURL))
        m.addItem(.separator())
        item(m, "Equalizzatore", #selector(toggleEQ))
        item(m, "Playlist", #selector(togglePL))
        item(m, "Modalità ridotta", #selector(toggleMainShade))
        item(m, "Playlist ridotta", #selector(togglePLShade))
        item(m, "Doppia dimensione", #selector(toggleDoubleSize))
        item(m, "Sempre in primo piano", #selector(toggleAlwaysOnTop))
        item(m, "Tempo rimanente", #selector(toggleTimeRemaining))
        m.addItem(.separator())
        item(m, "Shuffle", #selector(toggleShuffle))
        item(m, "Ripeti", #selector(toggleRepeat))
        m.addItem(.separator())
        let q = NSMenuItem(title: "Esci", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        m.addItem(q)
        return m
    }

    func presetsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Flat (reset)", #selector(resetEQ))
        m.addItem(.separator())
        item(m, "AUTO: rimuovi preset di questo brano", #selector(forgetAutoEQ))
        m.addItem(.separator())
        for (i, p) in Ctl.artistPresets.enumerated() { item(m, p.0, #selector(applyArtistPreset(_:)), tag: i) }
        m.addItem(.separator())
        for (i, p) in Ctl.presets.enumerated() { item(m, p.0, #selector(applyPreset(_:)), tag: i) }
        let mine = userPresets
        if !mine.isEmpty {
            m.addItem(.separator())
            m.addItem(withTitle: "I tuoi preset", action: nil, keyEquivalent: "").isEnabled = false
            for (i, p) in mine.enumerated() { item(m, p.name, #selector(applyUserPreset(_:)), tag: i) }
        }
        m.addItem(.separator())
        item(m, "Salva preset corrente…", #selector(saveUserPreset))
        item(m, "Carica preset Winamp (.eqf, .q1)…", #selector(loadEQFile))
        item(m, "Salva come file .eqf…", #selector(saveEQFile))
        item(m, "Esporta tutti in .q1…", #selector(exportEQLibrary))
        if !mine.isEmpty {
            let del = NSMenuItem(title: "Elimina preset", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (i, p) in mine.enumerated() { item(sub, p.name, #selector(deleteUserPreset(_:)), tag: i) }
            del.submenu = sub
            m.addItem(del)
        }
        return m
    }

    func sortMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Ordina per titolo", #selector(sortByTitle))
        item(m, "Ordina per nome file", #selector(sortByFilename))
        item(m, "Ordina per percorso", #selector(sortByPath))
        m.addItem(.separator())
        item(m, "Inverti ordine", #selector(reverseList))
        item(m, "Ordine casuale", #selector(randomizeList))
        return m
    }

    func removeMiscMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Rimuovi file mancanti", #selector(removeMissing))
        item(m, "Rimuovi duplicati", #selector(removeDuplicates))
        return m
    }

    func miscOptionsMenu() -> NSMenu {
        let m = NSMenu()
        item(m, "Mostra nel Finder", #selector(revealSelected))
        item(m, "Vai al file… (J)", #selector(showJumpToFile))
        item(m, "Accoda / togli dalla coda (Q)", #selector(queueSelected))
        item(m, "Svuota coda", #selector(clearQueue))
        item(m, "Vai al brano in riproduzione (J)", #selector(jumpToCurrent))
        m.addItem(.separator())
        item(m, "Raggruppa per artista e album", #selector(togglePlTree))
        return m
    }

    @objc func setVisMode(_ s: NSMenuItem) { visMode = s.tag }
    @objc func toggleTimeRemaining() { timeRemaining.toggle() }
    @objc func togglePlTree() { plTree.toggle(); plView.clampScroll() }
    @objc func toggleShuffle() { shuffle.toggle() }
    @objc func toggleRepeat() { repeatOn.toggle() }
    @objc func resetEQ() { bands = Array(repeating: 0, count: 10); preamp = 0 }
    @objc func applyPreset(_ s: NSMenuItem) { bands = Ctl.presets[s.tag].1 }

    @objc func applyArtistPreset(_ s: NSMenuItem) {
        let p = Ctl.artistPresets[s.tag]
        bands = p.1
        preamp = p.2
        eqOn = true
    }
    @objc func sortByTitle() { playlist.sort { $0.title } }
    @objc func sortByFilename() { playlist.sort { $0.url.lastPathComponent } }
    @objc func sortByPath() { playlist.sort { $0.url.path } }
    @objc func reverseList() { playlist.reverse() }
    @objc func randomizeList() { playlist.shuffle() }
    /// Q: toggles the selected playlist rows in the play queue.
    @objc func queueSelected() {
        guard !playlist.selection.isEmpty else { NSSound.beep(); return }
        playlist.toggleQueue(playlist.selection)
        invalidateTransition()
        flashMarquee(playlist.queue.isEmpty ? "CODA VUOTA" : "IN CODA: \(playlist.queue.count)", seconds: 1.2)
    }

    @objc func clearQueue() { playlist.queue = []; invalidateTransition() }

    @objc func jumpToCurrent() { if let i = playlist.current { plView.ensureVisible(i); playlist.selection = [i] } }

    @objc func removeMissing() {
        let missing = Set(playlist.tracks.indices.filter { !FileManager.default.fileExists(atPath: playlist.tracks[$0].url.path) })
        playlist.remove(missing)
        plView.clampScroll()
    }

    @objc func removeDuplicates() {
        var seen = Set<String>()
        let dup = Set(playlist.tracks.indices.filter { !seen.insert(playlist.tracks[$0].url.path).inserted })
        playlist.remove(dup)
        plView.clampScroll()
    }

    @objc func revealSelected() {
        let urls = playlist.selection.sorted().map { playlist.tracks[$0].url }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    func validateMenuItem(_ it: NSMenuItem) -> Bool {
        func on(_ b: Bool) { it.state = b ? .on : .off }
        switch it.action {
        case #selector(toggleEQ): on(eqVisible)
        case #selector(togglePL): on(plVisible)
        case #selector(toggleMainShade): on(mainShade)
        case #selector(togglePLShade): on(plShade)
        case #selector(toggleEQShade): on(eqShade)
        case #selector(toggleDoubleSize): on(doubleSize)
        case #selector(togglePlTree): on(plTree)
        case #selector(toggleAlwaysOnTop): on(alwaysOnTop)
        case #selector(toggleTimeRemaining): on(timeRemaining)
        case #selector(toggleShuffle): on(shuffle)
        case #selector(toggleRepeat): on(repeatOn)
        case #selector(setVisMode(_:)): on(it.tag == visMode)
        case #selector(selectSkinItem(_:)): on((it.representedObject as? URL)?.path == skinPath)
        case #selector(savePlaylistFile): return !playlist.tracks.isEmpty
        case #selector(fileInfo): return playlist.current != nil
        case #selector(clearQueue): return !playlist.queue.isEmpty
        case #selector(queueSelected): return !playlist.selection.isEmpty
        case #selector(setSpeedItem(_:)): on(Int((audio.rate * 100).rounded()) == it.tag)
        case #selector(forgetAutoEQ): return playlist.currentTrack.map { autoEQ[Self.autoKey($0)] != nil } ?? false
        default: break
        }
        return true
    }

    // MARK: EQ AUTO
    // Like Winamp's auto-load presets: with AUTO on, EQ changes are remembered for the playing file
    // (keyed by file name) and restored whenever that file is loaded again.

    private var autoEQ: [String: [Double]] = [:]
    private var applyingAutoEQ = false
    private var autoEQSave: DispatchWorkItem?

    private var autoEQURL: URL { skinsDir.deletingLastPathComponent().appendingPathComponent("eq-auto.json") }
    private static func autoKey(_ t: Track) -> String { t.url.lastPathComponent.lowercased() }

    private func loadAutoEQ() {
        guard let d = try? Data(contentsOf: autoEQURL),
              let m = try? JSONDecoder().decode([String: [Double]].self, from: d) else { return }
        autoEQ = m.filter { $0.value.count == 11 }
    }

    private func rememberAutoEQ() {
        guard eqAuto, !applyingAutoEQ, let t = playlist.currentTrack else { return }
        autoEQ[Self.autoKey(t)] = bands + [preamp]
        autoEQSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let d = try? JSONEncoder().encode(self.autoEQ) else { return }
            try? d.write(to: self.autoEQURL, options: .atomic)
        }
        autoEQSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func applyAutoEQ(announce: Bool) {
        guard eqAuto, let t = playlist.currentTrack, let v = autoEQ[Self.autoKey(t)] else { return }
        applyingAutoEQ = true
        bands = Array(v[0..<10])
        preamp = v[10]
        applyingAutoEQ = false
        eqView.needsDisplay = true
        if announce { flashMarquee("EQ AUTO: PRESET DEL BRANO") }
    }

    @objc func forgetAutoEQ() {
        guard let t = playlist.currentTrack else { return }
        autoEQ[Self.autoKey(t)] = nil
        if let d = try? JSONEncoder().encode(autoEQ) { try? d.write(to: autoEQURL, options: .atomic) }
        flashMarquee("EQ AUTO: PRESET RIMOSSO")
    }

    func flashMarquee(_ text: String, seconds: Double = 2) {
        marqueeOverride = text
        wake()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.marqueeOverride == text { self?.marqueeOverride = nil }
        }
    }

    // MARK: Persistence

    private func loadSettings() {
        let d = UserDefaults.standard
        func dbl(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
        func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
        volume = dbl("volume", 75)
        balance = dbl("balance", 0)
        eqOn = bool("eqOn", true)
        eqAuto = bool("eqAuto", false)
        preamp = dbl("preamp", 0)
        if let b = d.array(forKey: "bands") as? [Double], b.count == 10 { bands = b }
        doubleSize = bool("doubleSize", false)
        retinaSkins = bool("retinaSkins", true)
        alwaysOnTop = bool("alwaysOnTop", false)
        shuffle = bool("shuffle", false)
        repeatOn = bool("repeat", false)
        timeRemaining = bool("timeRemaining", false)
        visMode = int("visMode", 0)
        mainShade = bool("mainShade", false)
        eqShade = bool("eqShade", false)
        plShade = bool("plShade", false)
        eqVisible = bool("eqVisible", true)
        plVisible = bool("plVisible", true)
        plW = int("plW", 0)
        plH = int("plH", 2)
        skinPath = d.string(forKey: "skinPath")
        snapEnabled = bool("snapEnabled", true)
        snapDistance = dbl("snapDistance", 10)
        marqueeScroll = bool("marqueeScroll", true)
        resumeOnLaunch = bool("resumeOnLaunch", false)
        outputDeviceUID = d.string(forKey: "outputDeviceUID")
        visThinBands = bool("visThinBands", false)
        visPeaksOn = bool("visPeaksOn", true)
        visFalloff = int("visFalloff", 2)
        peakFalloff = int("peakFalloff", 2)
        oscStyle = int("oscStyle", 1)
        plFontSize = int("plFontSize", 9)
        plShowNumbers = bool("plShowNumbers", true)
        plTree = bool("plTree", false)
        plUseSkinFont = bool("plUseSkinFont", true)
        radioBuffer = dbl("radioBuffer", 2)
        musicSpeed = dbl("musicSpeed", 1)
        podcastSpeed = dbl("podcastSpeed", 1)
        pitchSemitones = dbl("pitchSemitones", 0)
        gapless = bool("gapless", true)
        ffmpegEnabled = bool("ffmpegEnabled", true)
        crossfadeOn = bool("crossfadeOn", false)
        crossfadeSeconds = dbl("crossfadeSeconds", 5)
        rgMode = int("rgMode", 1)
        rgPreamp = dbl("rgPreamp", 0)
        rgAnalyze = bool("rgAnalyze", true)
        rgPreventClip = bool("rgPreventClip", true)
        autoDownloadFonts = bool("autoDownloadFonts", true)
        menuBarEnabled = bool("menuBarEnabled", true)
        notifyTrackChange = bool("notifyTrackChange", true)
        notifyOnlyInBackground = bool("notifyOnlyInBackground", true)
    }

    func saveSettings() {
        let d = UserDefaults.standard
        let values: [String: Any] = [
            "volume": volume, "balance": balance, "eqOn": eqOn, "eqAuto": eqAuto, "preamp": preamp, "bands": bands,
            "doubleSize": doubleSize, "retinaSkins": retinaSkins, "alwaysOnTop": alwaysOnTop, "shuffle": shuffle, "repeat": repeatOn,
            "timeRemaining": timeRemaining, "visMode": visMode, "mainShade": mainShade, "eqShade": eqShade,
            "plShade": plShade, "eqVisible": eqVisible, "plVisible": plVisible, "plW": plW, "plH": plH,
            "snapEnabled": snapEnabled, "snapDistance": snapDistance, "marqueeScroll": marqueeScroll,
            "resumeOnLaunch": resumeOnLaunch, "visThinBands": visThinBands, "visPeaksOn": visPeaksOn,
            "visFalloff": visFalloff, "peakFalloff": peakFalloff, "oscStyle": oscStyle, "plFontSize": plFontSize,
            "plShowNumbers": plShowNumbers, "plTree": plTree, "plUseSkinFont": plUseSkinFont, "autoDownloadFonts": autoDownloadFonts,
            "menuBarEnabled": menuBarEnabled, "notifyTrackChange": notifyTrackChange,
            "notifyOnlyInBackground": notifyOnlyInBackground,
            "playlist": playlist.tracks.map { $0.url.isFileURL ? $0.url.path : $0.url.absoluteString },
            "streamTitles": Dictionary(playlist.tracks.filter(\.isStream).map { ($0.url.absoluteString, $0.title) },
                                       uniquingKeysWith: { a, _ in a }),
            "radioBuffer": radioBuffer, "ffmpegEnabled": ffmpegEnabled, "musicSpeed": musicSpeed,
            "podcastSpeed": podcastSpeed, "pitchSemitones": pitchSemitones, "gapless": gapless, "crossfadeOn": crossfadeOn,
            "crossfadeSeconds": crossfadeSeconds, "rgMode": rgMode, "rgPreamp": rgPreamp, "rgAnalyze": rgAnalyze,
            "rgPreventClip": rgPreventClip,
            "current": playlist.current ?? -1,
            "resumeTime": audio.currentTime, "resumePlaying": audio.state == .playing,
        ]
        for (k, v) in values { d.set(v, forKey: k) }
        for (k, v) in [("skinPath", skinPath), ("outputDeviceUID", outputDeviceUID)] {
            if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        for (k, w) in [("pos.main", mainWindow), ("pos.eq", eqWindow), ("pos.pl", plWindow)] {
            if let w { d.set([Double(w.frame.minX), Double(w.frame.maxY)], forKey: k) }
        }
    }

    private func restorePlaylist() {
        let d = UserDefaults.standard
        guard let paths = d.stringArray(forKey: "playlist") else { return }
        playlist.add(paths.compactMap { $0.hasPrefix("http") ? URL(string: $0) : URL(fileURLWithPath: $0) })
        let names = d.dictionary(forKey: "streamTitles") as? [String: String] ?? [:]
        for t in playlist.tracks where t.isStream { if let n = names[t.url.absoluteString] { t.title = n } }
        let c = d.integer(forKey: "current")
        guard playlist.tracks.indices.contains(c) else { return }
        // Only select the track: the file opens on the first Play (or now, to resume), never blocking launch.
        if resumeOnLaunch, d.bool(forKey: "resumePlaying") {
            let t = d.double(forKey: "resumeTime")
            playIndex(c, start: true) { [weak self] in self?.audio.seek(to: t) }
        } else {
            playlist.currentTrack = playlist.tracks[c]
        }
    }
}
