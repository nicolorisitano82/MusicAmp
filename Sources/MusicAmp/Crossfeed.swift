import AVFoundation
import AudioToolbox

/// Headphone crossfeed, after the Bauer stereophonic-to-binaural idea (as in bs2b, Roon and foobar2000): each ear
/// also hears the other channel's lows (below the cut frequency), ~0.3 ms later, as it would from speakers. Hard-
/// panned old stereo records stop sounding "inside one ear". Mono content keeps its level; highs are untouched.
///   out_L = L − g·LP(L) + g·LP(R delayed), with g = c / (1 + c), c = 10^(−feed/20)
/// so a centred low tone is unchanged and a hard-left one reaches the right ear `feed` dB lower.
final class CrossfeedAU: AUAudioUnit {
    enum Preset: Int, CaseIterable, Identifiable {
        case off, light, medium, strong
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .light: return "Light (700 Hz, 9.5 dB)"
            case .medium: return "Medium (700 Hz, 6 dB)"
            case .strong: return "Strong (650 Hz, 4.5 dB)"
            }
        }
        /// (cut frequency Hz, feed level dB)
        var parameters: (Double, Double)? {
            switch self {
            case .off: return nil
            case .light: return (700, 9.5)
            case .medium: return (700, 6)
            case .strong: return (650, 4.5)
            }
        }
    }

    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                componentSubType: fourCC("xfed"), componentManufacturer: fourCC("MAmp"),
                                                componentFlags: 0, componentFlagsMask: 0)
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(CrossfeedAU.self, as: desc, name: "MusicAmp: Crossfeed", version: 1)
    }

    private static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    static let maxDelay = 64

    struct State {
        var preset = 0
        var cut: Double = 700, feed: Double = 6     // for recomputing at another sample rate
        var on = false
        var g: Float = 0                             // c / (1 + c)
        var a: Float = 0                             // one-pole low-pass coefficient
        var delay = 13                               // samples (~0.3 ms)
        var lpL: Float = 0, lpR: Float = 0           // low-pass states (direct)
        var xL: Float = 0, xR: Float = 0             // low-pass states (crossed, before the delay)
        var pos = 0
    }

    let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
    /// Delay lines (left lows, then right lows), allocated once: nothing is allocated on the render thread.
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: CrossfeedAU.maxDelay * 2)
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var inputBuffer: AVAudioPCMBuffer?

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        state.initialize(to: State())
        ring.initialize(repeating: 0, count: CrossfeedAU.maxDelay * 2)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: fmt)
        outputBus = try AUAudioUnitBus(format: fmt)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    deinit { state.deallocate(); ring.deallocate() }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    /// Main thread. Coefficients are swapped while the render thread may run: a glitch-free enough change of a
    /// few floats for a setting changed by hand.
    func setPreset(_ p: Preset) {
        state.pointee.preset = p.rawValue
        if let (cut, feed) = p.parameters {
            state.pointee.cut = cut
            state.pointee.feed = feed
            configure(sampleRate: outputBus.format.sampleRate)
            state.pointee.on = true
        } else {
            state.pointee.on = false
        }
    }

    private func configure(sampleRate sr: Double) {
        let c = pow(10, -state.pointee.feed / 20)
        state.pointee.g = Float(c / (1 + c))
        state.pointee.a = Float(1 - exp(-2 * Double.pi * state.pointee.cut / max(8000, sr)))
        state.pointee.delay = max(1, min(CrossfeedAU.maxDelay - 1, Int((0.0003 * sr).rounded())))
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputBus.format, frameCapacity: maximumFramesToRender)
        configure(sampleRate: outputBus.format.sampleRate)
        let s = state.pointee
        state.pointee = State()
        state.pointee.preset = s.preset; state.pointee.cut = s.cut; state.pointee.feed = s.feed; state.pointee.on = s.on
        ring.update(repeating: 0, count: CrossfeedAU.maxDelay * 2)
        configure(sampleRate: outputBus.format.sampleRate)
    }

    override func deallocateRenderResources() {
        inputBuffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let st = state
        let ringL = ring, ringR = ring + CrossfeedAU.maxDelay
        let buffer = { [unowned self] in self.inputBuffer }
        return { _, timestamp, frames, _, outData, _, pullInput in
            guard let pull = pullInput, let inBuf = buffer() else { return kAudioUnitErr_NoConnection }
            let inList = inBuf.mutableAudioBufferList
            let inp = UnsafeMutableAudioBufferListPointer(inList)
            for i in 0..<inp.count { inp[i].mDataByteSize = frames * 4 }
            var pf = AudioUnitRenderActionFlags()
            let err = pull(&pf, timestamp, frames, 0, inList)
            guard err == noErr else { return err }
            let out = UnsafeMutableAudioBufferListPointer(outData)
            for i in 0..<min(out.count, inp.count) {
                if out[i].mData == nil { out[i].mData = inp[i].mData }
                out[i].mDataByteSize = inp[i].mDataByteSize
            }
            let n = Int(frames)
            guard inp.count >= 2, out.count >= 2,
                  let l = inp[0].mData?.assumingMemoryBound(to: Float.self), let r = inp[1].mData?.assumingMemoryBound(to: Float.self),
                  let ol = out[0].mData?.assumingMemoryBound(to: Float.self), let or = out[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            guard st.pointee.on else {
                if ol != l { ol.update(from: l, count: n) }
                if or != r { or.update(from: r, count: n) }
                return noErr
            }
            let g = st.pointee.g, a = st.pointee.a, delay = st.pointee.delay, size = CrossfeedAU.maxDelay
            var lpL = st.pointee.lpL, lpR = st.pointee.lpR, pos = st.pointee.pos
            for i in 0..<n {
                let L = l[i], R = r[i]
                lpL += a * (L - lpL)
                lpR += a * (R - lpR)
                // The crossed lows arrive `delay` samples later.
                ringL[pos] = lpL
                ringR[pos] = lpR
                let back = (pos - delay + size) % size
                let dL = ringL[back], dR = ringR[back]
                ol[i] = L - g * lpL + g * dR
                or[i] = R - g * lpR + g * dL
                pos = (pos + 1) % size
            }
            st.pointee.lpL = lpL; st.pointee.lpR = lpR; st.pointee.pos = pos
            return noErr
        }
    }
}
