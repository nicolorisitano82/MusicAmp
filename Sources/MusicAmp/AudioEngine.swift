import AVFoundation
import Accelerate

/// player -> 10-band EQ -> main mixer, with a tap on the mixer feeding the visualizer.
final class AudioEngine {
    enum State { case stopped, playing, paused }

    static let frequencies: [Float] = [60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000]

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)

    private(set) var state: State = .stopped
    private(set) var file: AVAudioFile?
    private(set) var bitrate = 0

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
    /// Called after any transport change (load, play, pause, stop, seek).
    var onChange: (() -> Void)?
    /// FFT/waveform analysis is skipped when nobody is looking at the visualizer.
    var analysisEnabled = true

    private var startFrame: AVAudioFramePosition = 0
    private var pausedTime: Double = 0
    private var lastKnownTime: Double = 0
    private var token = 0

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

        engine.attach(player)
        engine.attach(eq)
        for (i, b) in eq.bands.enumerated() {
            b.filterType = .parametric
            b.frequency = Self.frequencies[i]
            b.bandwidth = 1.0
            b.gain = 0
            b.bypass = false
        }
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            self?.analyze(buf)
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    var duration: Double {
        guard let f = file else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
    var sampleRate: Double { isStream ? stream.sampleRate : file?.fileFormat.sampleRate ?? 0 }
    var channels: Int { isStream ? stream.channels : Int(file?.fileFormat.channelCount ?? 0) }
    /// Something is loaded: a file or a radio stream.
    var hasSource: Bool { file != nil || isStream }

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
        guard file != nil else { return 0 }
        if state == .playing {
            if let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) {
                lastKnownTime = min(duration, Double(startFrame + pt.sampleTime) / pt.sampleRate)
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
    func use(_ f: AVAudioFile, url: URL) {
        stop()
        endStream()
        file = f
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(eq)
        engine.connect(player, to: eq, format: f.processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: f.processingFormat)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        bitrate = duration > 0 ? Int((Double(size) * 8 / duration / 1000).rounded()) : 0
        onChange?()
    }

    func unload() {
        stop()
        endStream()
        file = nil
        bitrate = 0
        onChange?()
    }

    func play() {
        if let u = streamURL {
            // Live radio: Play (or resume after pause) reconnects to the live point.
            if state != .playing || hls == nil { playStream(u) }
            return
        }
        guard file != nil else { return }
        switch state {
        case .paused:
            startEngine()
            player.play()
            state = .playing
        case .playing:
            seek(to: 0)
        case .stopped:
            startEngine()
            schedule(from: 0)
            player.play()
            state = .playing
        }
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
            player.pause()
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
        token &+= 1
        player.stop()
        if engine.isRunning { engine.pause() }
        state = .stopped
        startFrame = 0
        pausedTime = 0
        lastKnownTime = 0
        onChange?()
    }

    func seek(to time: Double) {
        guard !isStream, let f = file, state != .stopped else { return }
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

    func setBalance(_ b: Double) { player.pan = Float(max(-100, min(100, b)) / 100) }

    func setEQ(on: Bool, preamp: Double, bands: [Double]) {
        eq.bypass = !on
        eq.globalGain = Float(preamp)
        for (i, g) in bands.prefix(10).enumerated() { eq.bands[i].gain = Float(g) }
    }

    func visData() -> ([Float], [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (spectrum, wave)
    }

    // MARK: Private

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        try? engine.start()
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        token &+= 1
        let t = token
        player.stop()
        startFrame = max(0, min(frame, f.length))
        let remaining = f.length - startFrame
        guard remaining > 0 else {
            DispatchQueue.main.async { [weak self] in self?.finished(t) }
            return
        }
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: AVAudioFrameCount(remaining), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { self?.finished(t) }
        }
    }

    private func finished(_ t: Int) {
        guard t == token, state == .playing else { return }
        stop()
        onFinish?()
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

    // MARK: Internet radio

    /// Starts a radio stream: ICY/HTTP MP3 or AAC through our engine (EQ + visualizer), HLS through AVPlayer.
    func playStream(_ url: URL, name: String? = nil) {
        stop()
        file = nil
        bitrate = 0
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
                if let br = h.bitrate { self.bitrate = br }
                self.onStreamInfo?()
            }
        }
        r.onFormat = { [weak self] fmt in
            // Synchronous: the engine must speak this format before the first buffer is scheduled.
            DispatchQueue.main.sync {
                guard let self, self.radioToken == tok else { return }
                self.player.stop()
                self.engine.stop()
                self.engine.disconnectNodeOutput(self.player)
                self.engine.disconnectNodeOutput(self.eq)
                self.engine.connect(self.player, to: self.eq, format: fmt)
                self.engine.connect(self.eq, to: self.engine.mainMixerNode, format: fmt)
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
