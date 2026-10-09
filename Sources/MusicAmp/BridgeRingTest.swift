import AudioToolbox
import Foundation

/// Part of `--test-schedule`: the bridge ring under realistic timing. A "capture" thread writes 480-frame
/// blocks with up to ±6 ms of jitter, a "render" thread reads 512-frame blocks on a steady clock, at 48 kHz,
/// for 3 s. The signal is a ramp, so every lost, repeated or inserted sample shows.
enum BridgeRingTest {
    static func run(check: (Bool, String) -> Void) {
        let rate = 48000.0
        let ring = AudioRing(capacity: 96000, prime: 3072)
        let start = Date()
        let duration = 3.0
        let writer = Thread {
            var n = 0
            var block = 0
            var data = [Float](repeating: 0, count: 960)
            while Date().timeIntervalSince(start) < duration + 0.2 {
                for i in 0..<480 { data[i * 2] = Float(n + i); data[i * 2 + 1] = -Float(n + i) }
                n += 480
                data.withUnsafeMutableBytes { raw in
                    var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(960 * 4), mData: raw.baseAddress))
                    withUnsafeMutablePointer(to: &abl) { ring.write(UnsafeMutableAudioBufferListPointer($0), channels: 2, interleaved: true) }
                }
                block += 1
                let due = start.addingTimeInterval(Double(block * 480) / rate + Double.random(in: -0.006...0.006))
                Thread.sleep(forTimeInterval: max(0, due.timeIntervalSinceNow))
            }
        }
        writer.start()
        var out: [Float] = []
        var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
        var block = 0
        while Date().timeIntervalSince(start) < duration {
            ring.read(into: &l, &r, frames: 512)
            out += l
            block += 1
            Thread.sleep(forTimeInterval: max(0, start.addingTimeInterval(Double(block * 512) / rate).timeIntervalSinceNow))
        }
        // From the first sample played: each next sample is the previous + 1.
        guard let first = out.firstIndex(where: { $0 != 0 }) else { check(false, "bridge ring under jitter: nothing played"); return }
        var breaks = 0
        for i in (first + 1)..<out.count where out[i] != out[i - 1] + 1 { breaks += 1 }
        let s = ring.stats
        check(breaks == 0 && s.underruns == 0 && s.dropped == 0,
              String(format: "bridge ring under jitter: %d breaks, %d dry spells, %d dropped, starts after %.0f ms", breaks, s.underruns, s.dropped, Double(first) / rate * 1000))
    }
}
