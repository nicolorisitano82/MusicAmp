import AVFoundation
import Network

/// MusicAmp's output as a live stream on the local network, after the EQs and crossfeed, like an internet radio:
/// /live.flac (lossless, 24-bit) and /live.aac (AAC 320 kb/s, ADTS) for Chromecast, Sonos and UPnP speakers;
/// /audio/ and /tv/ as HLS for AirPlay and the karaoke on a TV. Every listener joins live; the receivers'
/// buffers add a few seconds of delay.
final class LiveStream {
    static let shared = LiveStream()

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "musicamp.livestream")
    private let encoders: [StreamEncoder] = [StreamEncoder(kind: .flac), StreamEncoder(kind: .aac)]
    private var hasClients: Bool { encoders.contains { !$0.clients.isEmpty } }
    private var tapNode: AVAudioNode?
    private(set) var running = false
    /// Level applied to the stream (1: full level, the speakers' own volume follows the slider).
    var gain: Float = 1
    /// Cover of the current track, served at /cover.jpg for Chromecast.
    var coverJPEG: Data?
    private var lastInput = Date.distantPast
    private var silenceTimer: DispatchSourceTimer?
    private var inFormat: AVAudioFormat?
    /// HLS versions of the stream (/audio/ for AirPlay, /tv/ with the karaoke video for Chromecast).
    private var hls: [String: LiveHLS] = [:]
    /// MusicAmp is paused: nothing goes into the HLS streams (their receivers are paused too), so their timeline
    /// carries on exactly where it stopped.
    var hlsPaused: Bool {
        get { queue.sync { pausedHLS } }
        set { queue.async { self.pausedHLS = newValue } }
    }
    private var pausedHLS = false
    var onClientsChanged: ((Int) -> Void)?

    var url: URL? { url(.aac) }

    func url(_ kind: StreamEncoder.Kind) -> URL? {
        guard port != 0, let ip = LiveStream.localIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)/live.\(kind.rawValue)")
    }

    var coverURL: URL? {
        guard coverJPEG != nil, let u = url else { return nil }
        return u.deletingLastPathComponent().appendingPathComponent("cover.jpg")
    }

    var localURL: URL? { port == 0 ? nil : URL(string: "http://127.0.0.1:\(port)/live.aac") }

    var clientCount: Int { queue.sync { encoders.reduce(0) { $0 + $1.clients.count } } }
    func clientCount(_ kind: StreamEncoder.Kind) -> Int { queue.sync { encoders.first { $0.kind == kind }?.clients.count ?? 0 } }
    /// Encoded packets sent in a format (tests).
    func packetsSent(_ kind: StreamEncoder.Kind) -> Int { queue.sync { encoders.first { $0.kind == kind }?.packetsSent ?? 0 } }

    // MARK: Start / stop

    /// Taps the end of the chain (crossfeed) and serves the stream.
    func start(engine: AudioEngine) throws {
        guard !running else { return }
        try listen()

        let node = engine.crossfeed
        queue.sync { _ = prepare(node.outputFormat(forBus: 0)) }
        node.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buf, _ in
            self?.queue.async { self?.input(buf) }
        }
        tapNode = node
        startSilence()
        running = true
    }

    /// Serves without tapping an engine (tests feed buffers with `feed`).
    func startDetached(format: AVAudioFormat) throws {
        guard !running else { return }
        try listen()
        queue.sync { _ = prepare(format) }
        startSilence()
        running = true
    }

    private func listen() throws {
        let l = try NWListener(using: .tcp, on: .any)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { s in if case .ready = s { ready.signal() }; if case .failed = s { ready.signal() } }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard let p = l.port?.rawValue else { l.cancel(); throw URLError(.cannotConnectToHost) }
        listener = l
        port = p
    }

    func feed(_ buf: AVAudioPCMBuffer) { queue.async { self.input(buf) } }

    /// Encoders for `fmt` (rebuilt when the chain's rate changes).
    private func prepare(_ fmt: AVAudioFormat) -> Bool {
        inFormat = fmt
        return encoders.allSatisfy { $0.prepare(fmt) }
    }

    private func encode(_ buf: AVAudioPCMBuffer) {
        if buf.format != inFormat { _ = prepare(buf.format) }
        for e in encoders { e.encode(buf) }
    }

    /// While the engine is paused or stopped the tap is quiet: keep the stream alive with silence, or the
    /// speakers would give up on it.
    private func startSilence() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: 0.2)
        t.setEventHandler { [weak self] in
            guard let self, self.hasClients, let fmt = self.inFormat, Date().timeIntervalSince(self.lastInput) > 0.4,
                  let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(fmt.sampleRate * 0.2)) else { return }
            b.frameLength = b.frameCapacity   // zero-filled
            self.encode(b)
        }
        t.resume()
        silenceTimer = t
    }

    private func input(_ buf: AVAudioPCMBuffer) {
        lastInput = Date()
        guard hasClients || !hls.isEmpty else { return }
        var out = buf
        if gain < 0.999, let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength), let src = buf.floatChannelData, let dst = copy.floatChannelData {
            copy.frameLength = buf.frameLength
            let n = Int(buf.frameLength), g = gain
            for ch in 0..<Int(buf.format.channelCount) { for i in 0..<n { dst[ch][i] = src[ch][i] * g } }
            out = copy
        }
        if hasClients { encode(out) }
        if !pausedHLS { for h in hls.values { h.append(out) } }
    }

    // MARK: HLS

    func addHLS(_ h: LiveHLS) { queue.sync { hls[h.name] = h } }
    func removeHLS(_ name: String) { queue.sync { hls.removeValue(forKey: name) }?.stop() }
    func hlsStream(_ name: String) -> LiveHLS? { queue.sync { hls[name] } }

    /// http://<this Mac>:<port>/<name>/index.m3u8
    func hlsURL(_ name: String, local: Bool = false, master: Bool = false) -> URL? {
        guard port != 0, let ip = local ? "127.0.0.1" : LiveStream.localIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)/\(name)/\(master ? "master" : "index").m3u8")
    }

    func stop() {
        silenceTimer?.cancel()
        silenceTimer = nil
        tapNode?.removeTap(onBus: 0)
        tapNode = nil
        listener?.cancel()
        listener = nil
        queue.sync {
            encoders.forEach { $0.closeAll() }
            hls.values.forEach { $0.stop() }
            hls = [:]
        }
        port = 0
        running = false
    }

    // MARK: Encoding

    /// 7-byte ADTS header for one AAC-LC frame (stereo).
    static func adtsHeader(length: Int, sampleRate: Double) -> Data {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let freq = rates.firstIndex(of: sampleRate) ?? 3
        let full = length + 7
        let profile = 1   // AAC LC (object type 2) − 1
        let channels = 2
        return Data([
            0xFF, 0xF1,
            UInt8((profile << 6) | (freq << 2) | (channels >> 2)),
            UInt8(((channels & 3) << 6) | (full >> 11)),
            UInt8((full >> 3) & 0xFF),
            UInt8(((full & 7) << 5) | 0x1F),
            0xFC,
        ])
    }

    // MARK: HTTP

    private func accept(_ c: NWConnection) {
        c.stateUpdateHandler = { [weak self, weak c] s in
            guard let self, let c else { return }
            switch s {
            case .failed, .cancelled:
                self.queue.async { if self.encoders.contains(where: { $0.remove(c) }) { self.notify() } }
            default: break
            }
        }
        c.start(queue: queue)
        // Read the request line; any path gets the stream (HEAD gets the headers only).
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let agent = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") }?.dropFirst(11).trimmingCharacters(in: .whitespaces) ?? "?"
            let from: String = { if case .hostPort(let h, _) = c.endpoint { return "\(h)" } else { return "?" } }()
            OutputsLog.add("http \(from) \(request.split(separator: " ").first ?? "?") \(path) [\(agent.prefix(60))]")
            let parts = path.split(separator: "?").first.map { $0.split(separator: "/").map(String.init) } ?? []
            if parts.count == 2, let h = self.hls[parts[0]] {
                let found = h.serve(parts[1])
                let body = found?.1 ?? Data()
                let head = "HTTP/1.1 \(found == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(found?.0 ?? "text/plain")\r\n" +
                    "Content-Length: \(body.count)\r\nCache-Control: no-cache\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                c.send(content: Data(head.utf8) + (request.hasPrefix("HEAD") ? Data() : body), completion: .contentProcessed { _ in c.cancel() })
                return
            }
            if request.contains(" /cover.jpg") {
                let body = self.coverJPEG ?? Data()
                let h = "HTTP/1.1 \(body.isEmpty ? "404 Not Found" : "200 OK")\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\n" +
                    "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
                c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            // /live.flac → lossless; anything else → AAC.
            let enc = self.encoders.first { $0.path == path.split(separator: "?").first.map(String.init) } ?? self.encoders.first { $0.kind == .aac }!
            if let f = self.inFormat { enc.prepare(f) }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(enc.contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n" +
                "Access-Control-Allow-Origin: *\r\nicy-name: MusicAmp\r\n\r\n"
            c.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            if request.hasPrefix("HEAD") { c.cancel(); return }
            enc.add(c)
            self.notify()
        }
    }

    private func notify() {
        let n = encoders.reduce(0) { $0 + $1.clients.count }
        DispatchQueue.main.async { self.onClientsChanged?(n) }
    }

    /// The Mac's IPv4 address on the local network (Wi-Fi or Ethernet).
    static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard i.ifa_addr.pointee.sa_family == UInt8(AF_INET), (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host), name = String(cString: i.ifa_name)
            if name.hasPrefix("en") { return ip }
            if best == nil { best = ip }
        }
        return best
    }
}
