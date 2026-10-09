import Foundation
import Network

/// A speaker on the local network that can play MusicAmp's live stream (see LiveStream.swift).
struct NetSpeaker: Identifiable, Hashable {
    enum Kind: String { case chromecast, upnp, sonos }
    let id: String
    let kind: Kind
    let name: String
    let model: String
    /// Chromecast: host and port of the Cast channel. UPnP/Sonos: the AVTransport control URL.
    let host: String
    let port: UInt16
    let control: URL?
    /// UPnP/Sonos: the RenderingControl control URL (volume).
    var rendering: URL? = nil

    var symbol: String {
        switch kind {
        case .chromecast: return "tv.and.mediabox"
        case .sonos: return "hifispeaker.2"
        case .upnp: return "hifispeaker"
        }
    }
    var kindName: String {
        switch kind {
        case .chromecast: return "Chromecast"
        case .sonos: return "Sonos"
        case .upnp: return "UPnP / DLNA"
        }
    }
}

/// Finds Chromecasts (Bonjour _googlecast._tcp) and UPnP media renderers, Sonos included (SSDP).
final class SpeakerDiscovery: ObservableObject {
    static let shared = SpeakerDiscovery()
    @Published private(set) var speakers: [NetSpeaker] = []
    @Published private(set) var searching = false
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "musicamp.discovery")

    func start() {
        guard browser == nil else { ssdp(); return }
        searching = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            for r in results { self?.resolveCast(r) }
        }
        b.start(queue: queue)
        browser = b
        ssdp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.searching = false }
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func add(_ s: NetSpeaker) {
        DispatchQueue.main.async {
            if let i = self.speakers.firstIndex(where: { $0.id == s.id }) { self.speakers[i] = s } else { self.speakers.append(s) }
            self.speakers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Chromecast

    private func resolveCast(_ r: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = r.endpoint else { return }
        var txt: [String: String] = [:]
        if case .bonjour(let t) = r.metadata { txt = t.dictionary }
        let friendly = txt["fn"] ?? name
        let model = txt["md"] ?? "Chromecast"
        let id = "cast:" + (txt["id"] ?? name)
        // Resolve host and port with a throw-away connection.
        let c = NWConnection(to: r.endpoint, using: .tcp)
        c.stateUpdateHandler = { [weak self] s in
            switch s {
            case .ready:
                if case .hostPort(let h, let p) = c.currentPath?.remoteEndpoint {
                    var host = "\(h)"
                    if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
                    self?.add(NetSpeaker(id: id, kind: .chromecast, name: friendly, model: model, host: host, port: p.rawValue, control: nil))
                }
                c.cancel()
            case .failed, .waiting: c.cancel()
            default: break
            }
        }
        c.start(queue: queue)
    }

    // MARK: UPnP / Sonos (SSDP)

    private func ssdp() {
        queue.async { [weak self] in
            let locations = SpeakerDiscovery.search(target: "urn:schemas-upnp-org:device:MediaRenderer:1", seconds: 3)
            for l in locations { self?.describe(l) }
        }
    }

    /// M-SEARCH on 239.255.255.250:1900; returns the LOCATION URLs of the replies.
    static func search(target: String, seconds: Double) -> Set<URL> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(1900).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(target)\r\n\r\n"
        for _ in 0..<2 {
            _ = msg.withCString { p in
                withUnsafePointer(to: &addr) { a in
                    a.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        var out = Set<URL>()
        let end = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 4096)
        while Date() < end {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0, let s = String(bytes: buf[0..<n], encoding: .utf8) else { continue }
            for line in s.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let u = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces)) { out.insert(u) }
            }
        }
        return out
    }

    private func describe(_ location: URL) {
        URLSession.shared.dataTask(with: location) { [weak self] data, _, _ in
            guard let data, let xml = String(data: data, encoding: .utf8) else { return }
            guard let s = SpeakerDiscovery.renderer(fromDescription: xml, location: location) else { return }
            self?.add(s)
        }.resume()
    }

    /// Parses a UPnP device description: name, model and the AVTransport control URL.
    static func renderer(fromDescription xml: String, location: URL) -> NetSpeaker? {
        func tag(_ name: String, in s: Substring) -> String? {
            guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
            return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let all = Substring(xml)
        var control: String?
        var rendering: String?
        var rest = all
        while let a = rest.range(of: "<service>"), let b = rest.range(of: "</service>", range: a.upperBound..<rest.endIndex) {
            let svc = rest[a.upperBound..<b.lowerBound]
            let type = tag("serviceType", in: svc) ?? ""
            if type.contains(":AVTransport:"), control == nil { control = tag("controlURL", in: svc) }
            if type.contains(":RenderingControl:"), rendering == nil { rendering = tag("controlURL", in: svc) }
            rest = rest[b.upperBound...]
        }
        guard let control, let url = URL(string: control, relativeTo: location)?.absoluteURL, let host = location.host else { return nil }
        let manufacturer = tag("manufacturer", in: all) ?? ""
        let isSonos = manufacturer.localizedCaseInsensitiveContains("sonos")
        var name = tag("friendlyName", in: all) ?? host
        if isSonos, let room = tag("roomName", in: all) { name = room }
        let model = tag("modelName", in: all) ?? manufacturer
        let udn = tag("UDN", in: all) ?? location.absoluteString
        let renderingURL = rendering.flatMap { URL(string: $0, relativeTo: location)?.absoluteURL }
        return NetSpeaker(id: "upnp:" + udn, kind: isSonos ? .sonos : .upnp, name: SpeakerDiscovery.unescape(name), model: SpeakerDiscovery.unescape(model),
                          host: host, port: UInt16(location.port ?? 80), control: url, rendering: renderingURL)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - UPnP AVTransport

/// Plays a URL on a UPnP renderer (Sonos, DLNA TVs and speakers): SetAVTransportURI then Play; Stop to end.
enum UPnPRenderer {
    static func play(_ s: NetSpeaker, stream: URL, title: String, contentType: String = "audio/aac", completion: @escaping (String?) -> Void) {
        guard let control = s.control else { completion("No control URL."); return }
        // Sonos plays internet-radio style streams with its own scheme.
        let uri = s.kind == .sonos ? stream.absoluteString.replacingOccurrences(of: "http://", with: "x-rincon-mp3radio://") : stream.absoluteString
        let didl = """
            <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
            xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="1" parentID="0" restricted="1">\
            <dc:title>\(SpeakerDiscovery.escape(title))</dc:title><upnp:class>object.item.audioItem.audioBroadcast</upnp:class>\
            <res protocolInfo="http-get:*:\(contentType):*">\(SpeakerDiscovery.escape(stream.absoluteString))</res></item></DIDL-Lite>
            """
        soap(control, "SetAVTransportURI", "<InstanceID>0</InstanceID><CurrentURI>\(SpeakerDiscovery.escape(uri))</CurrentURI><CurrentURIMetaData>\(SpeakerDiscovery.escape(didl))</CurrentURIMetaData>") { err in
            if let err { completion(err); return }
            soap(control, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>", completion)
        }
    }

    /// Pauses; a renderer that can't pause a live stream is stopped instead (`completion(true)` = stopped).
    static func pause(_ s: NetSpeaker, completion: @escaping (Bool) -> Void) {
        guard let control = s.control else { return }
        soap(control, "Pause", "<InstanceID>0</InstanceID>") { err in
            guard err != nil else { completion(false); return }
            soap(control, "Stop", "<InstanceID>0</InstanceID>") { _ in completion(true) }
        }
    }

    static func resume(_ s: NetSpeaker, completion: @escaping (String?) -> Void) {
        guard let control = s.control else { return }
        soap(control, "Play", "<InstanceID>0</InstanceID><Speed>1</Speed>", completion)
    }

    /// Volume 0…100 (RenderingControl, master channel).
    static func getVolume(_ s: NetSpeaker, completion: @escaping (Int?) -> Void) {
        guard let r = s.rendering else { completion(nil); return }
        soap(r, "GetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel>", service: "RenderingControl") { _, body in
            let v = body.range(of: "<CurrentVolume>").flatMap { a in body.range(of: "</CurrentVolume>").map { String(body[a.upperBound..<$0.lowerBound]) } }
            completion(v.flatMap { Int($0) })
        }
    }

    static func setVolume(_ s: NetSpeaker, _ v: Int) {
        guard let r = s.rendering else { return }
        soap(r, "SetVolume", "<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>\(max(0, min(100, v)))</DesiredVolume>",
             service: "RenderingControl") { _, _ in }
    }

    static func stop(_ s: NetSpeaker) {
        guard let control = s.control else { return }
        soap(control, "Stop", "<InstanceID>0</InstanceID>") { _ in }
    }

    static func soap(_ url: URL, _ action: String, _ args: String, _ completion: @escaping (String?) -> Void) {
        soap(url, action, args, service: "AVTransport") { err, _ in completion(err) }
    }

    static func soap(_ url: URL, _ action: String, _ args: String, service: String, _ completion: @escaping (String?, String) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data("""
            <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
            s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) \
            xmlns:u="urn:schemas-upnp-org:service:\(service):1">\(args)</u:\(action)></s:Body></s:Envelope>
            """.utf8)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if let error { completion(error.localizedDescription, body); return }
            if code != 200 {
                let detail = body.range(of: "<errorDescription>").flatMap { a in body.range(of: "</errorDescription>").map { String(body[a.upperBound..<$0.lowerBound]) } }
                let suffix: String = detail.map { ": " + $0 } ?? ""
                OutputsLog.add("upnp \(action) → HTTP \(code)\(suffix)")
                completion("\(action) failed (HTTP \(code)\(suffix))", body)
                return
            }
            completion(nil, body)
        }.resume()
    }
}

// MARK: - Chromecast (Cast v2)

/// Minimal Cast v2 sender: TLS to port 8009, length-prefixed protobuf CastMessages with JSON payloads.
/// Launches the Default Media Receiver and loads MusicAmp's live stream.
final class CastSession {
    let speaker: NetSpeaker
    var onState: ((String?, Bool) -> Void)?   // error, playing
    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "musicamp.cast")
    private var buffer = Data()
    private var requestID = 1
    private var transportID: String?
    private var mediaSessionID: Int?
    private var heartbeat: Timer?
    private var stream: URL
    private var title: String
    private var artist: String
    private var cover: URL?
    private let sender = "sender-musicamp"
    static let mediaReceiver = "CC1AD845"
    /// The stream is the HLS video with the karaoke (fMP4 segments), not the plain audio stream.
    var video = false
    /// Content type of the audio stream ("audio/flac" or "audio/aac").
    var audioType = "audio/aac"
    /// Stream to fall back to if the device refuses the first (FLAC → AAC).
    var fallback: (url: URL, type: String)?
    /// The device's volume (0…1) as it reports it, whoever changed it.
    var onVolume: ((Double) -> Void)?
    /// Called when the session falls back to the other stream.
    var onFallback: (() -> Void)?

    enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    init(speaker: NetSpeaker, stream: URL, title: String, artist: String, cover: URL?) {
        self.speaker = speaker; self.stream = stream; self.title = title; self.artist = artist; self.cover = cover
    }

    func start() {
        let tls = NWProtocolTLS.Options()
        // Cast devices use self-signed certificates.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) }, queue)
        let c = NWConnection(host: NWEndpoint.Host(speaker.host), port: NWEndpoint.Port(rawValue: speaker.port) ?? 8009, using: NWParameters(tls: tls))
        c.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.send(NS.connection, to: "receiver-0", ["type": "CONNECT"])
                self.send(NS.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": CastSession.mediaReceiver])
                self.receive()
                DispatchQueue.main.async {
                    self.heartbeat = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        self?.queue.async { self?.send(NS.heartbeat, to: "receiver-0", ["type": "PING"]) }
                    }
                }
            case .failed(let e): self.report(e.localizedDescription, false)
            case .waiting(let e): self.report(e.localizedDescription, false)
            default: break
            }
        }
        conn = c
        c.start(queue: queue)
    }

    func stop() {
        heartbeat?.invalidate()
        heartbeat = nil
        queue.async { [self] in
            if let t = transportID {
                send(NS.connection, to: t, ["type": "CLOSE"])
            }
            // Stop the receiver app so the TV/speaker goes back to idle.
            send(NS.receiver, to: "receiver-0", ["type": "STOP"])
            queue.asyncAfter(deadline: .now() + 0.3) { self.conn?.cancel() }
        }
    }

    /// Pauses or resumes the receiver's player (MusicAmp paused or resumed).
    func setPlaying(_ playing: Bool) {
        queue.async { [self] in
            guard let t = transportID, let id = mediaSessionID else { return }
            OutputsLog.add("cast \(speaker.name) → \(playing ? "PLAY" : "PAUSE")")
            send(NS.media, to: t, ["type": playing ? "PLAY" : "PAUSE", "mediaSessionId": id])
        }
    }

    /// Sets the device volume (0…1).
    func setVolume(_ v: Double) {
        queue.async { self.send(NS.receiver, to: "receiver-0", ["type": "SET_VOLUME", "volume": ["level": max(0, min(1, v))]]) }
    }

    private func report(_ error: String?, _ playing: Bool) {
        DispatchQueue.main.async { self.onState?(error, playing) }
    }

    // MARK: Messages

    private func send(_ namespace: String, to dest: String, _ payload: [String: Any]) {
        var p = payload
        if p["type"] as? String != "PING", p["type"] as? String != "PONG", p["type"] as? String != "CONNECT", p["type"] as? String != "CLOSE" {
            p["requestId"] = requestID; requestID += 1
        }
        guard let json = try? JSONSerialization.data(withJSONObject: p), let s = String(data: json, encoding: .utf8) else { return }
        let msg = CastSession.encode(source: sender, destination: dest, namespace: namespace, payload: s)
        var len = UInt32(msg.count).bigEndian
        conn?.send(content: Data(bytes: &len, count: 4) + msg, completion: .contentProcessed { _ in })
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer += data; self.drain() }
            if done || error != nil { self.report(error?.localizedDescription, false); return }
            self.receive()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let len = Int(buffer.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
            guard buffer.count >= 4 + len else { return }
            let msg = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + len)
            buffer.removeFirst(4 + len)
            guard let m = CastSession.decode(msg), let d = m.payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            handle(m.namespace, m.source, json)
        }
    }

    private func handle(_ namespace: String, _ source: String, _ j: [String: Any]) {
        let type = j["type"] as? String ?? ""
        if namespace != NS.heartbeat, let d = try? JSONSerialization.data(withJSONObject: j), let text = String(data: d, encoding: .utf8) {
            OutputsLog.add("cast \(speaker.name) ← \(String(text.prefix(1500)))")
        }
        switch (namespace, type) {
        case (NS.heartbeat, "PING"):
            send(NS.heartbeat, to: source, ["type": "PONG"])
        case (NS.receiver, "RECEIVER_STATUS"):
            if let level = ((j["status"] as? [String: Any])?["volume"] as? [String: Any])?["level"] as? Double {
                DispatchQueue.main.async { self.onVolume?(level) }
            }
            let apps = (j["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
            guard transportID == nil, let app = apps.first(where: { $0["appId"] as? String == CastSession.mediaReceiver }),
                  let t = app["transportId"] as? String else { return }
            transportID = t
            send(NS.connection, to: t, ["type": "CONNECT"])
            load()
        case (NS.receiver, "LAUNCH_ERROR"):
            report("The device refused to start the player (\(j["reason"] as? String ?? "?")).", false)
        case (NS.media, "MEDIA_STATUS"):
            let status = (j["status"] as? [[String: Any]])?.first
            if let id = status?["mediaSessionId"] as? Int { mediaSessionID = id }
            let state = status?["playerState"] as? String
            if state == "IDLE", let reason = status?["idleReason"] as? String, reason == "ERROR" {
                if !tryFallback() { report("The device couldn't play the stream.", false) }
            } else if state == "PLAYING" || state == "BUFFERING" {
                report(nil, true)
            }
        case (NS.media, "LOAD_FAILED"), (NS.media, "LOAD_CANCELLED"), (NS.media, "INVALID_REQUEST"):
            if !tryFallback() { report("The device couldn't load the stream (\(type)).", false) }
        default: break
        }
    }

    /// The device refused the stream: load the fallback one (once).
    private func tryFallback() -> Bool {
        guard let f = fallback, !video else { return false }
        fallback = nil
        OutputsLog.add("cast \(speaker.name): \(audioType) refused, falling back to \(f.type)")
        stream = f.url
        audioType = f.type
        DispatchQueue.main.async { self.onFallback?() }
        load()
        return true
    }

    private func load() {
        guard let t = transportID else { return }
        // A music track's metadata makes the receiver show its own audio screen (cover and title) and hide the
        // video: the karaoke goes as generic media.
        var meta: [String: Any] = video ? ["metadataType": 0, "title": title, "subtitle": artist] : ["metadataType": 3, "title": title, "artist": artist]
        if let cover { meta["images"] = [["url": cover.absoluteString]] }
        var media: [String: Any] = ["contentId": stream.absoluteString, "contentType": audioType, "streamType": "LIVE", "metadata": meta]
        if video {
            media["contentType"] = "application/x-mpegURL"
            media["hlsSegmentFormat"] = "fmp4"
            media["hlsVideoSegmentFormat"] = "fmp4"
        }
        OutputsLog.add("cast \(speaker.name) → LOAD \(media["contentType"] ?? "") \(stream.absoluteString)")
        send(NS.media, to: t, ["type": "LOAD", "autoplay": true, "media": media])
    }

    // MARK: Protobuf (CastMessage)

    /// CastMessage: 1 protocol_version=0, 2 source_id, 3 destination_id, 4 namespace, 5 payload_type=0 (string), 6 payload_utf8.
    static func encode(source: String, destination: String, namespace: String, payload: String) -> Data {
        var d = Data()
        func varint(_ v: Int) { var v = UInt64(v); repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0 }
        func string(_ field: Int, _ s: String) { let b = Data(s.utf8); varint(field << 3 | 2); varint(b.count); d += b }
        varint(1 << 3); varint(0)
        string(2, source); string(3, destination); string(4, namespace)
        varint(5 << 3); varint(0)
        string(6, payload)
        return d
    }

    static func decode(_ d: Data) -> (source: String, destination: String, namespace: String, payload: String)? {
        var i = d.startIndex
        func varint() -> Int? {
            var v = 0, shift = 0
            while i < d.endIndex {
                let b = d[i]; i += 1
                v |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        var f: [Int: String] = [:]
        while i < d.endIndex {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0: _ = varint()
            case 2:
                guard let n = varint(), i + n <= d.endIndex else { return nil }
                f[key >> 3] = String(data: d[i..<i + n], encoding: .utf8) ?? ""
                i += n
            default: return nil
            }
        }
        guard let ns = f[4] else { return nil }
        return (f[2] ?? "", f[3] ?? "", ns, f[6] ?? "")
    }
}
