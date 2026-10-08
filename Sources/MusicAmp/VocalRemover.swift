import AVFoundation
import AudioToolbox

/// Vocal remover for karaoke, like Winamp's classic DSP plugin: lead vocals are usually mixed in the centre, so the
/// side signal (L − R) keeps the instruments panned left and right and drops what is identical in both channels.
/// Bass and kick drum are centred too, so the centre is kept below ~120 Hz (24 dB/octave low-pass). `amount` blends with the original
/// (0 = untouched, 1 = full effect). An in-process AUAudioUnit, placed after the speed/pitch stage.
final class VocalRemoverAU: AUAudioUnit {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                componentSubType: fourCC("vrmv"), componentManufacturer: fourCC("MAmp"),
                                                componentFlags: 0, componentFlagsMask: 0)
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        AUAudioUnit.registerSubclass(VocalRemoverAU.self, as: desc, name: "MusicAmp: Vocal Remover", version: 1)
    }

    private static func fourCC(_ s: String) -> FourCharCode { s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) } }

    /// Shared with the render thread: plain values, written from the main thread (a Float store is atomic enough here).
    struct State {
        var amount: Float = 0
        // Butterworth low-pass biquad (run twice: 4th order) for the centred bass.
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var s1a: Float = 0, s1b: Float = 0, s2a: Float = 0, s2b: Float = 0
    }

    let state = UnsafeMutablePointer<State>.allocate(capacity: 1)
    private var inputBus: AUAudioUnitBus!
    private var outputBus: AUAudioUnitBus!
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var inputBuffer: AVAudioPCMBuffer?

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        state.initialize(to: State())
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        inputBus = try AUAudioUnitBus(format: fmt)
        outputBus = try AUAudioUnitBus(format: fmt)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096
    }

    deinit { state.deallocate() }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        inputBuffer = AVAudioPCMBuffer(pcmFormat: inputBus.format, frameCapacity: maximumFramesToRender)
        let sr = max(8000, outputBus.format.sampleRate)
        let w = 2 * Double.pi * 120 / sr, q = 1 / 2.0.squareRoot()
        let alpha = sin(w) / (2 * q), c = cos(w), a0 = 1 + alpha
        var s = State()
        s.amount = state.pointee.amount
        s.b0 = Float((1 - c) / 2 / a0); s.b1 = Float((1 - c) / a0); s.b2 = Float((1 - c) / 2 / a0)
        s.a1 = Float(-2 * c / a0); s.a2 = Float((1 - alpha) / a0)
        state.pointee = s
    }

    override func deallocateRenderResources() {
        inputBuffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let st = state
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
            let k = st.pointee.amount
            if k <= 0 {
                if ol != l { ol.update(from: l, count: n) }
                if or != r { or.update(from: r, count: n) }
                return noErr
            }
            let p = st.pointee
            var s1a = p.s1a, s1b = p.s1b, s2a = p.s2a, s2b = p.s2b
            for i in 0..<n {
                let L = l[i], R = r[i]
                // Side at 0.7 (not 0.5): a hard-panned instrument loses ~3 dB instead of 6, with headroom left for
                // out-of-phase reverbs that would clip at the full L − R.
                let mid = (L + R) * 0.5, side = (L - R) * 0.7
                // Two Butterworth sections (transposed direct form II): the centred bass we keep.
                let y1 = p.b0 * mid + s1a
                s1a = p.b1 * mid - p.a1 * y1 + s1b
                s1b = p.b2 * mid - p.a2 * y1
                let bass = p.b0 * y1 + s2a
                s2a = p.b1 * y1 - p.a1 * bass + s2b
                s2b = p.b2 * y1 - p.a2 * bass
                ol[i] = L + k * ((side + bass) - L)
                or[i] = R + k * ((bass - side) - R)
            }
            st.pointee.s1a = s1a; st.pointee.s1b = s1b; st.pointee.s2a = s2a; st.pointee.s2b = s2b
            return noErr
        }
    }
}
