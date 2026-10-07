import AVFoundation
import MediaToolbox

/// Routes a streamed podcast episode through our engine: AVPlayer keeps doing what it is good at (network,
/// decoding, seeking, speed with clear speech) and an audio processing tap hands every rendered block to
/// the engine (EQ, balance, output device, visualizer, Milkdrop), leaving AVPlayer's own output silent.
/// Until the engine has taken the stream (`bridged`), AVPlayer stays audible, so nothing is ever lost.
/// The tap sees audio after the time-pitch stage, at real-time pace, so the engine plays it as it comes.
final class RemoteAudioTap {
    /// The tap's PCM format (Float32, non-interleaved), reported once before the first block.
    var onFormat: ((AVAudioFormat) -> Void)?
    /// A rendered block; called on AVPlayer's render thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Set by the engine once it plays the blocks: from then on AVPlayer's output is muted.
    var bridged = false
    private var format: AVAudioFormat?

    /// Attaches the tap to the item's audio track (asynchronously, once the track is known).
    func attach(to item: AVPlayerItem) {
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            var cb = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
                init: { _, client, storage in storage.pointee = client },
                finalize: { tap in
                    Unmanaged<RemoteAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                },
                prepare: { tap, _, asbd in
                    let me = Unmanaged<RemoteAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    var d = asbd.pointee
                    guard let f = AVAudioFormat(streamDescription: &d) else { return }
                    me.format = f
                    me.onFormat?(f)
                },
                unprepare: { _ in },
                process: { tap, frames, _, buffers, framesOut, flagsOut in
                    let me = Unmanaged<RemoteAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                    let n = AVAudioFrameCount(framesOut.pointee)
                    let abl = UnsafeMutableAudioBufferListPointer(buffers)
                    if let f = me.format, n > 0, let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: n), let dst = out.floatChannelData {
                        out.frameLength = n
                        for (c, b) in abl.enumerated() where c < Int(f.channelCount) {
                            if let src = b.mData { memcpy(dst[c], src, Int(n) * MemoryLayout<Float>.size) }
                        }
                        me.onBuffer?(out)
                    }
                    if me.bridged {
                        for b in abl { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
                    }
                })
            var tap: MTAudioProcessingTap?
            guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
                  let tap else {
                Unmanaged.passUnretained(self).release()   // the retain given to clientInfo
                return
            }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }
}
