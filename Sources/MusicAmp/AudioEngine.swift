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
    var onFinish: (() -> Void)?

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
    var sampleRate: Double { file?.fileFormat.sampleRate ?? 0 }
    var channels: Int { Int(file?.fileFormat.channelCount ?? 0) }

    var currentTime: Double {
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
        stop()
        let f = try AVAudioFile(forReading: url)
        file = f
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(eq)
        engine.connect(player, to: eq, format: f.processingFormat)
        engine.connect(eq, to: engine.mainMixerNode, format: f.processingFormat)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        bitrate = duration > 0 ? Int((Double(size) * 8 / duration / 1000).rounded()) : 0
    }

    func unload() {
        stop()
        file = nil
        bitrate = 0
    }

    func play() {
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
    }

    func pause() {
        switch state {
        case .playing:
            pausedTime = currentTime
            player.pause()
            state = .paused
        case .paused:
            play()
        case .stopped:
            break
        }
    }

    func stop() {
        token &+= 1
        player.stop()
        state = .stopped
        startFrame = 0
        pausedTime = 0
        lastKnownTime = 0
    }

    func seek(to time: Double) {
        guard let f = file, state != .stopped else { return }
        let t = max(0, min(duration, time))
        schedule(from: AVAudioFramePosition(t * f.processingFormat.sampleRate))
        lastKnownTime = t
        if state == .playing {
            startEngine()
            player.play()
        } else {
            pausedTime = t
        }
    }

    func setVolume(_ v: Double) {
        let x = Float(max(0, min(100, v)) / 100)
        engine.mainMixerNode.outputVolume = x * x
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

    private func analyze(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData else { return }
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
            spec[i] = max(0, min(1, (db + 62) / 56))
        }

        lock.lock()
        spectrum = spec
        wave = w
        lock.unlock()
    }
}
