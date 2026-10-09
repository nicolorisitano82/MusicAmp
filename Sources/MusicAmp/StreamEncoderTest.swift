import AVFoundation

/// Part of `--test-outputs`: the lossless stream (/live.flac). A listener from the start and one joining late
/// both get a FLAC stream that decodes back to the tone, sample-exact in level (lossless, 24-bit).
enum StreamEncoderTest {
    /// Reads `seconds` of `path` from the stream over HTTP.
    static func read(_ live: LiveStream, _ path: String, seconds: Double) -> Data {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = live.port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { return Data() }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let req = "GET \(path) HTTP/1.1\r\nHost: test\r\n\r\n"
        _ = req.withCString { send(fd, $0, strlen($0), 0) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { out.append(contentsOf: buf[0..<n]) } else if n == 0 { break }
        }
        return out
    }

    static func body(_ d: Data) -> (String, Data) {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return ("", Data()) }
        return (String(decoding: d[..<r.lowerBound], as: UTF8.self), Data(d[r.upperBound...]))
    }

    /// Level and frequency of a decoded file, skipping the first `skip` frames.
    static func analyse(_ file: URL, skip: Int) -> (rms: Float, hz: Double, bits: UInt32, frames: Int)? {
        // A live stream has no length in its header: read block by block until the end.
        guard let f = try? AVAudioFile(forReading: file),
              let chunk = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 8192) else { return nil }
        var samples: [Float] = []
        while (try? f.read(into: chunk)) != nil, chunk.frameLength > 0, let c = chunk.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: c, count: Int(chunk.frameLength)))
        }
        let n = samples.count
        let ch = samples
        let a = min(skip, n), z = min(n, a + 44100)
        guard z - a > 1000 else { return nil }
        var sum: Float = 0
        var crossings = 0
        for i in a..<z {
            sum += ch[i] * ch[i]
            if i > a, (ch[i - 1] < 0) != (ch[i] < 0) { crossings += 1 }
        }
        let rms = sqrt(sum / Float(z - a))
        let hz = Double(crossings) / 2 / (Double(z - a) / f.processingFormat.sampleRate)
        return (rms, hz, f.fileFormat.streamDescription.pointee.mBitsPerChannel, n)
    }

    static func run(_ live: LiveStream, format fmt: AVAudioFormat, check: (Bool, String) -> Void) {
        check(StreamEncoder.flacHeader(sampleRate: 44100, channels: 2, bitsPerSample: 24, block: 4096).count == 42, "FLAC header: fLaC + STREAMINFO (42 bytes)")
        var first = Data(), late = Data()
        let g = DispatchGroup()
        g.enter()
        Thread.detachNewThread { first = read(live, "/live.flac", seconds: 3.5); g.leave() }
        var waited = 0.0
        while live.clientCount(.flac) == 0, waited < 2 { Thread.sleep(forTimeInterval: 0.05); waited += 0.05 }
        check(live.clientCount(.flac) == 1, "FLAC listener connected")
        for k in 0..<36 {
            if k == 12 {
                g.enter()
                Thread.detachNewThread { late = read(live, "/live.flac", seconds: 2.5); g.leave() }
                Thread.sleep(forTimeInterval: 0.2)
            }
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { continue }
            b.frameLength = 4096
            let l = b.floatChannelData![0], r = b.floatChannelData![1]
            for i in 0..<4096 {
                let v = 0.5 * sin(2 * Float.pi * 1000 * Float(k * 4096 + i) / 44100)
                l[i] = v
                r[i] = v
            }
            live.feed(b)
            Thread.sleep(forTimeInterval: 0.02)
        }
        g.wait()
        for (name, data, skip) in [("from the start", first, 0), ("joining late", late, 0)] {
            let (head, flac) = body(data)
            check(head.hasPrefix("HTTP/1.1 200") && head.contains("audio/flac") && flac.prefix(4) == Data("fLaC".utf8),
                  "FLAC \(name): HTTP 200, audio/flac, starts with fLaC (\(flac.count) bytes)")
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-live-\(name.hasPrefix("from") ? "a" : "b").flac")
            try? flac.write(to: file)
            if let a = analyse(file, skip: skip) {
                check(abs(a.rms - 0.3536) < 0.002, String(format: "FLAC \(name): decodes back at level %.4f (tone 0.3536, lossless)", a.rms))
                check(abs(a.hz - 1000) < 10, String(format: "FLAC \(name): %.0f Hz (tone 1000), %.1f s", a.hz, Double(a.frames) / 44100))
            } else {
                check(false, "FLAC \(name): decodes")
            }
        }
    }
}
