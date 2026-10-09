import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures another app's audio (Music, Spotify) with a Core Audio process tap and mutes it at the source, so the
/// sound plays through MusicAmp's engine instead (EQ, visualizers, crossfeed, outputs). macOS asks once for
/// permission ("System Audio Recording"). The tap feeds a private aggregate device whose input block delivers
/// the app's audio; MusicAmp copies it into a ring buffer read by the engine.
final class AppAudioTap {
    enum TapError: LocalizedError {
        case notRunning(String), process(OSStatus), tap(OSStatus), aggregate(OSStatus), io(OSStatus)
        var errorDescription: String? {
            switch self {
            case .notRunning(let a): return "\(a) isn't running."
            case .process(let s): return "Can't find the app's audio (\(s))."
            case .tap(let s): return "macOS refused to capture the app's audio (\(s)). Allow MusicAmp in System Settings → Privacy & Security → Screen & System Audio Recording."
            case .aggregate(let s): return "Can't create the capture device (\(s))."
            case .io(let s): return "Can't start the capture (\(s))."
            }
        }
    }

    private(set) var format: AVAudioFormat?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// ~2 s of room, ~70 ms of margin between the capture's and the engine's I/O cycles.
    let ring = AudioRing(capacity: 96000, prime: 3072)

    deinit { stop() }

    /// Starts capturing every process of `bundleID` (the app and its helpers).
    func start(bundleID: String) throws {
        stop()
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
        guard !pids.isEmpty else { throw TapError.notRunning(bundleID) }
        // Process objects of the app and its child helpers (Spotify renders audio in a helper process).
        var objects: [AudioObjectID] = []
        for pid in pids + AppAudioTap.children(of: pids) {
            var p = pid
            var obj = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                  mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let s = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj)
            if s == noErr, obj != kAudioObjectUnknown { objects.append(obj) }
        }
        guard !objects.isEmpty else { throw TapError.process(-1) }

        let desc = CATapDescription(stereoMixdownOfProcesses: objects)
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "MusicAmp bridge"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var s = AudioHardwareCreateProcessTap(desc, &tap)
        guard s == noErr else { throw TapError.tap(s) }
        tapID = tap

        // Tap format.
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        s = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard s == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else { stop(); throw TapError.tap(s) }
        format = fmt

        // A private aggregate device made of the tap alone, clocked by it. The output device is deliberately left
        // out: with Bluetooth headphones in it, opening the aggregate's input switches them to their headset
        // (microphone) mode, 16–24 kHz, which sounds awful.
        var dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MusicAmp Bridge",
            kAudioAggregateDeviceUIDKey: "com.genomeup.musicamp.bridge.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: false, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        s = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
        if s != noErr {
            // Fallback: clocked by the output device (as before), when a tap-only aggregate isn't accepted.
            let outputUID = AppAudioTap.defaultOutputUID() ?? ""
            dict[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            dict[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
            dict[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
            dict[kAudioAggregateDeviceUIDKey] = "com.genomeup.musicamp.bridge.\(UUID().uuidString)"
            s = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
            OutputsLog.add("bridge: tap-only capture device refused, clocked by the output instead (\(s))")
        }
        guard s == noErr else { stop(); throw TapError.aggregate(s) }
        aggregateID = agg

        let ring = self.ring
        let channels = Int(fmt.channelCount), interleaved = fmt.isInterleaved
        var proc: AudioDeviceIOProcID?
        s = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, input, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            ring.write(abl, channels: channels, interleaved: interleaved)
        }
        guard s == noErr, let proc else { stop(); throw TapError.io(s) }
        procID = proc
        s = AudioDeviceStart(agg, proc)
        guard s == noErr else { stop(); throw TapError.io(s) }
    }

    func stop() {
        if let p = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, p)
            AudioDeviceDestroyIOProcID(aggregateID, p)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        ring.reset()
    }

    static func defaultOutputUID() -> String? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &uid) == noErr, let u = uid?.takeRetainedValue() else { return nil }
        return u as String
    }

    /// Child processes (helpers) of the given ones.
    static func children(of parents: [pid_t]) -> [pid_t] {
        var out: [pid_t] = []
        for parent in parents {
            let n = proc_listchildpids(parent, nil, 0)
            guard n > 0 else { continue }
            var pids = [pid_t](repeating: 0, count: Int(n) * 2)
            let got = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            if got > 0 { out += pids.prefix(Int(got)).filter { $0 > 0 } }
        }
        return out
    }
}

/// Stereo float ring buffer between the capture thread and the engine's render thread.
/// The two run on different I/O cycles (and block sizes), so the reader keeps a margin: it starts only once
/// `prime` frames are buffered, and after running dry it waits to fill up again (silence) instead of
/// alternating samples and zeros, which crackles. A backlog far over the margin is dropped back to it once.
final class AudioRing {
    private var buf: [Float]
    private var readPos = 0, writePos = 0, count = 0
    private var lock = os_unfair_lock()
    private var priming = true
    let capacity: Int   // frames
    let prime: Int      // frames buffered before playing
    /// Times the reader ran dry, and frames dropped from a backlog (diagnostics).
    private(set) var underruns = 0
    private(set) var dropped = 0

    init(capacity: Int, prime: Int = 0) {
        self.capacity = capacity
        self.prime = min(prime, capacity / 2)
        buf = [Float](repeating: 0, count: capacity * 2)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readPos = 0; writePos = 0; count = 0; priming = true
        os_unfair_lock_unlock(&lock)
    }

    /// (frames buffered, underruns, dropped frames)
    var stats: (fill: Int, underruns: Int, dropped: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return (count, underruns, dropped)
    }

    func write(_ abl: UnsafeMutableAudioBufferListPointer, channels: Int, interleaved: Bool) {
        guard let first = abl.first, let d0 = first.mData else { return }
        let frames = interleaved ? Int(first.mDataByteSize) / (4 * max(1, channels)) : Int(first.mDataByteSize) / 4
        let p0 = d0.assumingMemoryBound(to: Float.self)
        let p1 = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : nil
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        for i in 0..<frames {
            let l: Float, r: Float
            if interleaved {
                l = p0[i * channels]; r = channels > 1 ? p0[i * channels + 1] : l
            } else {
                l = p0[i]; r = p1?[i] ?? l
            }
            buf[writePos * 2] = l; buf[writePos * 2 + 1] = r
            writePos = (writePos + 1) % capacity
            if count == capacity { readPos = (readPos + 1) % capacity; dropped += 1 } else { count += 1 }
        }
    }

    /// Fills `frames` frames into L/R.
    func read(into l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if priming {
            if count >= max(prime, 1) { priming = false } else {
                for i in 0..<frames { l[i] = 0; r[i] = 0 }
                return
            }
        }
        // Far behind (the engine stalled while the capture went on): back to the margin, once.
        let limit = max(prime * 4, frames * 8)
        if count > limit {
            let drop = count - max(prime, frames)
            readPos = (readPos + drop) % capacity; count -= drop; dropped += drop
        }
        let n = min(frames, count)
        for i in 0..<n {
            l[i] = buf[readPos * 2]; r[i] = buf[readPos * 2 + 1]
            readPos = (readPos + 1) % capacity
        }
        count -= n
        if n < frames {
            // Ran dry: fade the last samples out instead of a hard cut, then refill before playing again.
            for i in n..<frames { l[i] = 0; r[i] = 0 }
            let fade = min(n, 64)
            for k in 0..<fade {
                let g = Float(k) / Float(max(1, fade))
                l[n - fade + k] *= 1 - g; r[n - fade + k] *= 1 - g
            }
            underruns += 1
            if prime > 0 { priming = true }
        }
    }
}
