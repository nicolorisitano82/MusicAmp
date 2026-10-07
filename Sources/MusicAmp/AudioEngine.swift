import AVFoundation
import Accelerate

/// Two decks (player → converter mixer → per-track gain) → deck mixer → 10-band EQ → main mixer, with a tap on
/// the main mixer feeding the visualizer. Two decks give sample-accurate gapless transitions and crossfades; each
/// deck's gain stage applies ReplayGain. Only player → converter is rewired per file (a mixer input accepts any
/// format while running), so the idle deck can load a track of another sample rate during playback.
final class AudioEngine {
    enum State { case stopped, playing, paused }

    static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    final class Deck {
        let player = AVAudioPlayerNode()
        let converter = AVAudioMixerNode()           // any file format in, bus format out
        let gain = AVAudioUnitEQ(numberOfBands: 0)   // globalGain = ReplayGain (dB), fixed bus format
        var file: AVAudioFile?
        var url: URL?
        var startFrame: AVAudioFramePosition = 0
        var token = 0
        var bitrate = 0
        var index: Int?   // playlist index, for transitions
    }

    let engine = AVAudioEngine()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let deckMixer = AVAudioMixerNode()
    private let decks = [Deck(), Deck()]
    private var cur = 0
    private var deck: Deck { decks[cur] }
    private var other: Deck { decks[1 - cur] }
    /// The player of the current deck (radio streams always use the current deck).
    var player: AVAudioPlayerNode { deck.player }
    var file: AVAudioFile? { deck.file }
    var bitrate: Int { isStream ? streamBitrate : deck.bitrate }
    private var streamBitrate = 0

    private(set) var state: State = .stopped

    // MARK: Transitions (gapless / crossfade) and ReplayGain

    /// Seconds of overlap between tracks; 0 = no crossfade.
    var crossfadeSeconds: Double = 0
    /// Start the next track exactly when the current one ends (used when crossfade is off).
    var gapless = true
    /// Next track for an automatic transition, without side effects (queue/shuffle are resolved by the caller).
    var nextProvider: (() -> (index: Int, url: URL)?)?
    /// The automatic transition happened: the track at `index` is now current.
    var onAdvance: ((Int) -> Void)?
    /// ReplayGain in dB for a file (0 when off or unknown yet).
    var gainProvider: ((URL) -> Float)?
    private var preparing = false
    private var transitionStarted = false
    private var fadeTimer: Timer?
    private var monitor: Timer?

    // MARK: Internet radio state
    struct StreamInfo {
        var name: String?
        var title: String?
        var buffering = false
        var isHLS = false
        var error: String?
        var sampleRate: Double = 0
        var channels = 0
    }
    /// Non-nil while a radio stream (ICY or HLS) is the source.
    private(set) var streamURL: URL?
    private(set) var stream = StreamInfo()
    var onStreamInfo: (() -> Void)?
    var bufferSeconds: Double = 2
    var isStream: Bool { streamURL != nil }
    private var radio: RadioStream?
    private var radioToken = 0
    private var queuedFrames = 0          // guarded by `lock`
    private var streamRate: Double = 44100
    private var waitingForBuffer = true   // guarded by `lock`
    private var reconnects = 0
    private var hls: AVPlayer?
    private var hlsOffset: Double?
    private var hlsMeta: HLSMetadataReader?
    var onFinish: (() -> Void)?
    /// Called after any transport change (load, play, pause, stop, seek, automatic advance).
    var onChange: (() -> Void)?
    /// FFT/waveform analysis is skipped when nobody is looking at the visualizer.
    var analysisEnabled = true

    private var pausedTime: Double = 0
    private var lastKnownTime: Double = 0

    // MARK: FFmpeg-decoded files (formats macOS can't read)
    /// Set while the current deck plays through ffmpeg.
    private(set) var ffProbe: FFmpeg.Probe?
    private var ff: FFmpegDecoder?
    private var ffToken = 0          // guarded by `lock` when read off the main thread
    private var ffStart: Double = 0
    private var ffQueued = 0         // guarded by `lock`
    private var ffEOF = false        // guarded by `lock`
    private let ffRoom = DispatchSemaphore(value: 0)
    private var ffRadio: FFmpegDecoder?

    private let lock = NSLock()
    private var spectrum = [Float](repeating: 0, count: 75)
    private var wave = [Float](repeating: 0, count: 76)
    private let fftSize = 1024
    private let fftSetup: FFTSetup
    private let window: [Float]

    init() {
        fftSetup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&w, 1024, Int32(vDSP_HANN_NORM))
        window = w

        engine.attach(deckMixer)
        engine.attach(eq)
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric
            b.frequency = Self.frequencies[i]
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        let hw = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let bus = AVAudioFormat(standardFormatWithSampleRate: hw > 0 ? hw : 44100, channels: 2)
        for (i, d) in decks.enumerated() {
            engine.attach(d.player)
            engine.attach(d.converter)
            engine.attach(d.gain)
            d.gain.globalGain = 0
            engine.connect(d.player, to: d.converter, format: nil)
            engine.connect(d.converter, to: d.gain, format: bus)
            engine.connect(d.gain, to: deckMixer, fromBus: 0, toBus: i, format: bus)
        }
        engine.connect(deckMixer, to: eq, format: bus)
        engine.connect(eq, to: engine.mainMixerNode, format: bus)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.analyze(buf)
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    /// Wires a deck's player for a file/stream format: only player → converter changes, which a mixer
    /// input accepts while the engine runs.
    private func connect(_ i: Int, _ fmt: AVAudioFormat) {
        let d = decks[i]
        engine.disconnectNodeOutput(d.player)
        engine.connect(d.player, to: d.converter, format: fmt)
    }

    var duration: Double {
        if let p = ffProbe { return p.duration }
        guard let f = file else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
    var sampleRate: Double { isStream ? stream.sampleRate : ffProbe?.sampleRate ?? file?.fileFormat.sampleRate ?? 0 }
    var channels: Int { isStream ? stream.channels : ffProbe?.channels ?? Int(file?.fileFormat.channelCount ?? 0) }
    /// Something is loaded: a file (native or through ffmpeg) or a radio stream.
    var hasSource: Bool { file != nil || isStream || ffProbe != nil }

    var currentTime: Double {
        if isStream {
            // Elapsed listening time, as Winamp shows for streams.
            if let h = hls {
                // Live HLS reports the playlist position: show time since this listen started instead.
                let t = h.currentTime().seconds
                guard t.isFinite, t > 0 else { return 0 }
                if hlsOffset == nil { hlsOffset = t }
                return max(0, t - (hlsOffset ?? t))
            }
            if state == .playing, let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) {
                lastKnownTime = max(lastKnownTime, Double(pt.sampleTime) / pt.sampleRate)
            }
            return lastKnownTime
        }
        if ffProbe != nil {
            if state == .playing, let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt), pt.sampleTime >= 0 {
                lastKnownTime = min(duration > 0 ? duration : .infinity, ffStart + Double(pt.sampleTime) / pt.sampleRate)
            }
            return state == .playing ? lastKnownTime : pausedTime
        }
        guard file != nil else { return 0 }
        if state == .playing {
            if let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt), pt.sampleTime >= 0 {
                lastKnownTime = min(duration, Double(deck.startFrame + pt.sampleTime) / pt.sampleRate)
            }
            return lastKnownTime
        }
        return pausedTime
    }

    func load(_ url: URL) throws {
        use(try AVAudioFile(forReading: url), url: url)
    }

    /// Opening a file can block (TCC consent for the Music folder, slow disks): callers open it off the main
    /// thread with `AVAudioFile(forReading:)` and hand it over here, on the main thread.
    func use(_ f: AVAudioFile, url: URL, index: Int? = nil) {
        stop()
        endStream()
        ffProbe = nil
        let d = deck
        d.file = f
        d.url = url
        d.index = index
        engine.stop()
        connect(cur, f.processingFormat)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        d.bitrate = duration > 0 ? Int((Double(size) * 8 / duration / 1000).rounded()) : 0
        applyGain(d)
        onChange?()
    }

    func unload() {
        stop()
        endStream()
        ffProbe = nil
        deck.file = nil
        deck.url = nil
        deck.bitrate = 0
        onChange?()
    }

    func play() {
        if let u = streamURL {
            // Live radio: Play (or resume after pause) reconnects to the live point.
            if state != .playing || hls == nil { playStream(u) }
            return
        }
        if ffProbe != nil {
            switch state {
            case .paused:
                startEngine()
                player.play()
                state = .playing
            case .playing:
                seek(to: 0)
            case .stopped:
                state = .playing
                startFF(at: 0, play: true)
            }
            onChange?()
            return
        }
        guard file != nil else { return }
        switch state {
        case .paused:
            startEngine()
            player.play()
            if transitionStarted { other.player.play() }
            state = .playing
            fadeTimer.map { _ in resumeFade() }
        case .playing:
            seek(to: 0)
        case .stopped:
            startEngine()
            schedule(from: 0)
            player.play()
            state = .playing
        }
        startMonitor()
        onChange?()
    }

    func pause() {
        if isStream {
            if state == .playing {
                stopStreamTransport()
                state = .paused
                onChange?()
            } else if state == .paused {
                play()
            }
            return
        }
        switch state {
        case .playing:
            pausedTime = currentTime
            decks.forEach { $0.player.pause() }
            fadeTimer?.invalidate()
            // Release the audio hardware while idle; play() restarts the engine.
            engine.pause()
            state = .paused
            onChange?()
        case .paused:
            play()
        case .stopped:
            break
        }
    }

    func stop() {
        stopStreamTransport()
        stopFF()
        cancelTransition(force: true)
        deck.token &+= 1
        player.stop()
        player.volume = 1
        if engine.isRunning { engine.pause() }
        state = .stopped
        deck.startFrame = 0
        pausedTime = 0
        lastKnownTime = 0
        onChange?()
    }

    func seek(to time: Double) {
        if ffProbe != nil, state != .stopped {
            let t = max(0, min(duration > 0 ? duration : 0, time))
            let playing = state == .playing
            startFF(at: t, play: playing)
            if !playing { pausedTime = t }
            onChange?()
            return
        }
        guard !isStream, let f = file, state != .stopped else { return }
        cancelTransition(force: true)
        let t = max(0, min(duration, time))
        schedule(from: AVAudioFramePosition(t * f.processingFormat.sampleRate))
        lastKnownTime = t
        if state == .playing {
            startEngine()
            player.play()
        } else {
            pausedTime = t
        }
        onChange?()
    }

    func setVolume(_ v: Double) {
        let x = Float(max(0, min(100, v)) / 100)
        engine.mainMixerNode.outputVolume = x * x
        hls?.volume = x * x
    }

    func setBalance(_ b: Double) {
        let pan = Float(max(-100, min(100, b)) / 100)
        decks.forEach { $0.player.pan = pan }
    }

    func setEQ(on: Bool, preamp: Double, bands: [Double]) {
        eq.bypass = !on
        eq.globalGain = Float(preamp)
        for (i, g) in bands.prefix(10).enumerated() { eq.bands[i].gain = Float(g) }
    }

    func visData() -> ([Float], [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (spectrum, wave)
    }

    /// ReplayGain changed (mode, preamp, or analysis finished for `url`): re-apply to the decks playing it.
    func refreshGain(for url: URL? = nil) {
        for d in decks where url == nil || d.url == url { applyGain(d) }
    }

    private func applyGain(_ d: Deck) {
        d.gain.globalGain = d.url.flatMap { gainProvider?($0) } ?? 0
    }

    // MARK: Private

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        let d = deck, idx = cur
        d.token &+= 1
        let t = d.token
        d.player.stop()
        d.startFrame = max(0, min(frame, f.length))
        let remaining = f.length - d.startFrame
        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in self?.finished(idx, t) }
            return
        }
        d.player.scheduleSegment(f, startingFrame: d.startFrame, frameCount: AVAudioFrameCount(remaining), at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finished(idx, t) }
        }
    }

    /// A deck played to the end. With a prepared gapless deck the other one is already running: just swap.
    private func finished(_ idx: Int, _ t: Int) {
        guard decks[idx].token == t, state == .playing else { return }
        if idx != cur {
            // Old deck after a crossfade: the fade timer stops it; nothing else to do.
            return
        }
        if transitionStarted || (other.file != nil && other.index != nil && preparedReady) {
            swapToOther()
            return
        }
        stop()
        onFinish?()
    }

    // MARK: Gapless / crossfade

    private var preparedReady = false

    /// 4 Hz while a file plays: prepares the next track a few seconds before the end, starts crossfades.
    private func startMonitor() {
        guard monitor == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tickTransition() }
        RunLoop.main.add(t, forMode: .common)
        monitor = t
    }

    private func tickTransition() {
        guard state == .playing, !isStream, let f = file else { return }
        let remaining = duration - currentTime
        let lead = crossfadeSeconds > 0 ? crossfadeSeconds : 0
        guard gapless || lead > 0 else { return }
        if !preparing, !preparedReady, !transitionStarted, remaining < lead + 6, remaining > 0.3 {
            prepareNext(after: f)
        }
    }

    private func prepareNext(after current: AVAudioFile) {
        guard let next = nextProvider?(), next.url.isFileURL else { return }
        preparing = true
        let tokenAtStart = deck.token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let f = try? AVAudioFile(forReading: next.url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                guard let f, self.state == .playing, self.deck.token == tokenAtStart, !self.isStream else { return }
                self.armOther(f, url: next.url, index: next.index)
            }
        }
    }

    /// Loads the next file on the idle deck and schedules its start: at the exact end (gapless) or
    /// `crossfadeSeconds` earlier (crossfade).
    private func armOther(_ f: AVAudioFile, url: URL, index: Int) {
        let o = other, oi = 1 - cur
        o.player.stop()
        o.file = f
        o.url = url
        o.index = index
        o.startFrame = 0
        o.token &+= 1
        let t = o.token
        connect(oi, f.processingFormat)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let dur = Double(f.length) / f.processingFormat.sampleRate
        o.bitrate = dur > 0 ? Int((Double(size) * 8 / dur / 1000).rounded()) : 0
        applyGain(o)
        o.player.scheduleSegment(f, startingFrame: 0, frameCount: AVAudioFrameCount(f.length), at: nil,
                                 completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finished(oi, t) }
        }
        guard let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt), let cf = file else { return }
        let played = deck.startFrame + pt.sampleTime
        let remaining = max(0, Double(cf.length - played) / pt.sampleRate)
        let fade = min(crossfadeSeconds, remaining, dur / 2)
        let startIn = max(0, remaining - fade)
        let startHost = nt.hostTime + AVAudioTime.hostTime(forSeconds: startIn)
        o.player.volume = fade > 0 ? 0 : 1
        o.player.prepare(withFrameCount: 8192)
        o.player.play(at: AVAudioTime(hostTime: startHost))
        preparedReady = true
        if fade > 0 {
            // Begin the fade when the incoming deck starts.
            fadeStartHost = startHost
            fadeLength = fade
            resumeFade()
        }
    }

    private var fadeStartHost: UInt64 = 0
    private var fadeLength: Double = 0

    /// Equal-power crossfade driven by host time (stays in sync after pause/resume).
    private func resumeFade() {
        fadeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = mach_absolute_time()
            guard now >= self.fadeStartHost else { return }
            if !self.transitionStarted {
                self.transitionStarted = true
                self.swapToOther()   // the incoming track becomes current when it becomes audible
            }
            let p = min(1, AVAudioTime.seconds(forHostTime: now - self.fadeStartHost) / max(0.01, self.fadeLength))
            let incoming = self.deck, outgoing = self.other
            incoming.player.volume = Float(sin(p * .pi / 2))
            outgoing.player.volume = Float(cos(p * .pi / 2))
            if p >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                outgoing.token &+= 1
                outgoing.player.stop()
                outgoing.player.volume = 1
                outgoing.file = nil
                outgoing.url = nil
                self.transitionStarted = false
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    /// The other deck is now the current one.
    private func swapToOther() {
        cur = 1 - cur
        preparedReady = false
        lastKnownTime = 0
        pausedTime = 0
        if fadeTimer == nil {
            // Gapless: the old deck is done.
            other.token &+= 1
            other.player.stop()
            other.file = nil
            other.url = nil
        }
        if let i = deck.index { onAdvance?(i) }
        onChange?()
    }

    /// Drops a prepared-but-not-started next track (queue, shuffle or playlist changed). `force` also aborts a
    /// crossfade in progress (manual stop, seek, new track).
    func cancelTransition(force: Bool = false) {
        if transitionStarted && !force { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        if transitionStarted {
            // Abort mid-fade: keep the incoming (current) deck, silence the outgoing one.
            other.token &+= 1
            other.player.stop()
            other.player.volume = 1
            deck.player.volume = 1
            other.file = nil
            transitionStarted = false
        } else if preparedReady || other.file != nil {
            other.token &+= 1
            other.player.stop()
            other.player.volume = 1
            other.file = nil
            other.url = nil
            other.index = nil
        }
        preparedReady = false
        preparing = false
    }

    private func configurationChanged() {
        // Output device changed: the engine stopped itself. Resume where we were.
        if isStream, hls == nil, state == .playing {
            startEngine()
            player.play()
            return
        }
        guard file != nil else { return }
        let t = lastKnownTime
        switch state {
        case .playing:
            startEngine()
            seek(to: t)
        case .paused, .stopped:
            break
        }
    }

    // MARK: FFmpeg

    /// Loads a file that only ffmpeg can decode (Ogg, Opus, APE, WavPack…). Same transport as a native file.
    func useFFmpeg(url: URL, probe: FFmpeg.Probe, index: Int? = nil) {
        stop()
        endStream()
        let d = deck
        d.file = nil
        d.url = url
        d.index = index
        ffProbe = probe
        engine.stop()
        connect(cur, AVAudioFormat(standardFormatWithSampleRate: probe.sampleRate, channels: AVAudioChannelCount(probe.channels))!)
        d.bitrate = probe.bitrate
        applyGain(d)
        onChange?()
    }

    private func stopFF() {
        lock.lock()
        ffToken &+= 1
        ffQueued = 0
        ffEOF = false
        lock.unlock()
        ff?.cancel()
        ff = nil
        ffRoom.signal()
    }

    /// (Re)starts ffmpeg at `t` seconds; keeps at most ~8 s decoded ahead of playback.
    private func startFF(at t: Double, play: Bool) {
        guard let p = ffProbe, let url = deck.url else { return }
        stopFF()
        player.stop()
        lock.lock(); let tok = ffToken; lock.unlock()
        ffStart = t
        lastKnownTime = t
        let dec = FFmpegDecoder(url: url, start: t, sampleRate: p.sampleRate, channels: p.channels)
        let maxQueued = Int(p.sampleRate * 8)
        let valid = { [weak self] () -> Bool in
            guard let self else { return false }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.ffToken == tok
        }
        dec.waitForRoom = { [weak self] in
            while let self, valid() {
                self.lock.lock(); let q = self.ffQueued; self.lock.unlock()
                if q < maxQueued { return }
                _ = self.ffRoom.wait(timeout: .now() + 0.2)
            }
        }
        var first = true
        dec.onBuffer = { [weak self] buf in
            guard let self, valid() else { return }
            let n = Int(buf.frameLength)
            self.lock.lock(); self.ffQueued += n; self.lock.unlock()
            self.player.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.ffQueued = max(0, self.ffQueued - n)
                let done = self.ffEOF && self.ffQueued == 0 && self.ffToken == tok
                self.lock.unlock()
                self.ffRoom.signal()
                if done { DispatchQueue.main.async { self.finishedFF(tok) } }
            }
            if first {
                first = false
                if play {
                    DispatchQueue.main.async {
                        guard valid(), self.state == .playing else { return }
                        self.startEngine()
                        self.player.play()
                    }
                }
            }
        }
        dec.onEnd = { [weak self] err in
            guard let self else { return }
            self.lock.lock()
            self.ffEOF = true
            let done = self.ffQueued == 0 && self.ffToken == tok
            self.lock.unlock()
            if done { DispatchQueue.main.async { self.finishedFF(tok) } }
        }
        ff = dec
        dec.start()
    }

    private func finishedFF(_ tok: Int) {
        lock.lock(); let ok = ffToken == tok; lock.unlock()
        guard ok, state == .playing else { return }
        stop()
        onFinish?()
    }

    /// Live radio in a format AudioFileStream can't parse, decoded by ffmpeg at 48 kHz stereo.
    private func startFFRadio(_ url: URL) {
        radioToken &+= 1
        let tok = radioToken
        radio?.cancel()
        radio = nil
        let dec = FFmpegDecoder(url: url, sampleRate: 48000, channels: 2)
        player.stop()
        engine.stop()
        connect(cur, dec.format)
        deck.gain.globalGain = 0
        streamRate = 48000
        stream.sampleRate = 48000
        stream.channels = 2
        stream.buffering = true
        lock.lock(); queuedFrames = 0; waitingForBuffer = true; lock.unlock()
        startEngine()
        dec.onBuffer = { [weak self] buf in self?.enqueue(buf, tok) }
        dec.onEnd = { [weak self] err in
            DispatchQueue.main.async {
                guard let self, self.radioToken == tok, self.state == .playing else { return }
                self.ffRadio = nil
                self.streamFailed(err ?? StreamError.ended, retry: { self.startFFRadio(url) })
            }
        }
        ffRadio = dec
        onStreamInfo?()
        dec.start()
    }

    // MARK: Internet radio

    /// Starts a radio stream: ICY/HTTP MP3 or AAC through our engine (EQ + visualizer), HLS through AVPlayer.
    func playStream(_ url: URL, name: String? = nil) {
        stop()
        ffProbe = nil
        deck.file = nil
        deck.url = nil
        streamBitrate = 0
        let isNew = streamURL != url
        streamURL = url
        if isNew { stream = StreamInfo(name: name) }
        stream.error = nil
        reconnects = 0
        lastKnownTime = 0
        state = .playing
        if url.pathExtension.lowercased() == "m3u8" { startHLS(url) } else { startRadio(url) }
        onChange?()
    }

    /// Leaves stream mode entirely (a file or nothing is loaded next).
    func endStream() {
        stopStreamTransport()
        streamURL = nil
        stream = StreamInfo()
    }

    private func stopStreamTransport() {
        radioToken &+= 1
        radio?.cancel()
        radio = nil
        ffRadio?.cancel()
        ffRadio = nil
        hls?.pause()
        hls = nil
        hlsMeta = nil
        if isStream {
            player.stop()
            lock.lock(); queuedFrames = 0; waitingForBuffer = true; lock.unlock()
            if engine.isRunning { engine.pause() }
        }
    }

    private func startRadio(_ url: URL) {
        radioToken &+= 1
        let tok = radioToken
        let r = RadioStream(url: url)
        r.onHeaders = { [weak self] h in
            DispatchQueue.main.async {
                guard let self, self.radioToken == tok else { return }
                if let n = h.name, !n.isEmpty, self.stream.name == nil { self.stream.name = n }
                if let br = h.bitrate { self.streamBitrate = br }
                self.onStreamInfo?()
            }
        }
        r.onFormat = { [weak self] fmt in
            // Synchronous: the engine must speak this format before the first buffer is scheduled.
            DispatchQueue.main.sync {
                guard let self, self.radioToken == tok else { return }
                self.player.stop()
                self.engine.stop()
                self.connect(self.cur, fmt)
                self.deck.gain.globalGain = 0
                self.streamRate = fmt.sampleRate
                self.stream.sampleRate = fmt.sampleRate
                self.stream.channels = Int(fmt.channelCount)
                self.lock.lock(); self.queuedFrames = 0; self.waitingForBuffer = true; self.lock.unlock()
                self.stream.buffering = true
                self.startEngine()
                self.onStreamInfo?()
            }
        }
        r.onBuffer = { [weak self] buf in self?.enqueue(buf, tok) }
        r.onTitle = { [weak self] t in
            DispatchQueue.main.async {
                guard let self, self.radioToken == tok else { return }
                self.stream.title = t
                self.onStreamInfo?()
            }
        }
        r.onRedirect = { [weak self] u, isHLS in
            DispatchQueue.main.async {
                guard let self, self.radioToken == tok else { return }
                self.radio = nil
                if isHLS { self.startHLS(u) } else { self.startRadio(u) }
            }
        }
        r.onEnd = { [weak self] err in
            DispatchQueue.main.async {
                guard let self, self.radioToken == tok, self.state == .playing else { return }
                self.streamFailed(err, retry: { self.startRadio(url) })
            }
        }
        radio = r
        stream.buffering = true
        r.start()
    }

    /// Network hiccup or server restart: reconnect up to 5 times (1, 2, 4, 8, 16 s), then give up.
    private func streamFailed(_ err: Error?, retry: @escaping () -> Void) {
        if case StreamError.unsupported = err ?? StreamError.ended, FFmpeg.available, ffRadio == nil, let u = streamURL {
            // Ogg Vorbis / Opus / FLAC radio: decode with ffmpeg, same buffering path.
            startFFRadio(u)
            return
        }
        if case StreamError.unsupported = err ?? StreamError.ended {
            stream.error = err?.localizedDescription
            stop()
            onStreamInfo?()
            return
        }
        guard reconnects < 5 else {
            stream.buffering = false
            stream.error = err?.localizedDescription ?? StreamError.ended.localizedDescription
            stop()
            onStreamInfo?()
            return
        }
        let delay = pow(2, Double(reconnects))
        reconnects += 1
        stream.buffering = true
        stream.error = "Riconnessione (\(reconnects)/5)…"
        onStreamInfo?()
        let tok = radioToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.radioToken == tok, self.state == .playing else { return }
            retry()
        }
    }

    /// Schedules decoded audio; plays once `bufferSeconds` are queued, pauses on underrun until refilled.
    private func enqueue(_ buf: AVAudioPCMBuffer, _ tok: Int) {
        let frames = Int(buf.frameLength)
        lock.lock()
        let valid = radioToken == tok
        if valid { queuedFrames += frames }
        let queued = queuedFrames, waiting = waitingForBuffer
        lock.unlock()
        guard valid else { return }
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frames)
            let empty = self.queuedFrames == 0 && !self.waitingForBuffer && self.radioToken == tok
            if empty { self.waitingForBuffer = true }
            self.lock.unlock()
            if empty {
                DispatchQueue.main.async {
                    guard self.radioToken == tok, self.state == .playing else { return }
                    self.player.pause()
                    self.stream.buffering = true
                    self.onStreamInfo?()
                }
            }
        }
        if waiting, Double(queued) >= bufferSeconds * streamRate {
            lock.lock(); waitingForBuffer = false; lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.radioToken == tok, self.state == .playing else { return }
                self.startEngine()
                self.player.play()
                self.reconnects = 0
                self.stream.buffering = false
                self.stream.error = nil
                self.onStreamInfo?()
            }
        }
    }

    /// HLS (.m3u8): AVPlayer plays it; EQ and visualizer are not available on this path.
    private func startHLS(_ url: URL) {
        radioToken &+= 1
        radio?.cancel()
        radio = nil
        player.stop()
        if engine.isRunning { engine.pause() }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        let x = engine.mainMixerNode.outputVolume
        p.volume = x
        hlsMeta = HLSMetadataReader(item: item) { [weak self] title in
            self?.stream.title = title
            self?.onStreamInfo?()
        }
        hls = p
        hlsOffset = nil
        stream.isHLS = true
        stream.buffering = false
        p.play()
        onStreamInfo?()
    }

    private func analyze(_ buf: AVAudioPCMBuffer) {
        guard analysisEnabled, let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        guard n > 0 else { return }
        let chans = max(1, Int(buf.format.channelCount))
        let count = min(n, fftSize)
        var mono = [Float](repeating: 0, count: fftSize)
        for i in 0..<count {
            var s: Float = 0
            for c in 0..<chans { s += ch[c][i] }
            mono[i] = s / Float(chans)
        }
        var w = [Float](repeating: 0, count: 76)
        for i in 0..<76 { w[i] = mono[min(count - 1, i * count / 76)] }

        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(mono, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, 10, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // 75 log-spaced columns, ~40 Hz .. ~16 kHz.
        let rate = Float(buf.format.sampleRate)
        let binHz = rate / Float(fftSize)
        let lo = max(1, 40 / binHz), hi = min(Float(half - 1), 16000 / binHz)
        var spec = [Float](repeating: 0, count: 75)
        for i in 0..<75 {
            let a = Int(lo * powf(hi / lo, Float(i) / 75))
            let b = max(a, Int(lo * powf(hi / lo, Float(i + 1) / 75)))
            var m: Float = 0
            for k in a...min(b, half - 1) { m = max(m, mags[k]) }
            let db = 20 * log10f(max(m / Float(half), 1e-9)) + Float(i) * 0.2
            spec[i] = max(0, min(1, (db + 70) / 52))
        }

        lock.lock()
        spectrum = spec
        wave = w
        lock.unlock()
    }
}

/// Timed metadata (ID3 / EXT-X-DATERANGE titles) from an HLS radio.
final class HLSMetadataReader: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    private let output = AVPlayerItemMetadataOutput(identifiers: nil)
    private let onTitle: (String) -> Void

    init(item: AVPlayerItem, onTitle: @escaping (String) -> Void) {
        self.onTitle = onTitle
        super.init()
        output.setDelegate(self, queue: .main)
        item.add(output)
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        for item in groups.flatMap(\.items) {
            let key = (item.commonKey?.rawValue ?? (item.key as? String) ?? "").lowercased()
            guard key.contains("title") || key == "tit2" || key.contains("streamtitle") else { continue }
            Task { @MainActor in
                if let s = try? await item.load(.stringValue), !s.isEmpty { self.onTitle(s) }
            }
            return
        }
    }
}
