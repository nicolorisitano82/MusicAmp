import AVFoundation
import Foundation

/// Extra formats through an installed FFmpeg (Homebrew or bundled): Ogg Vorbis, Opus, Monkey's Audio, WavPack,
/// Musepack, TTA, WMA, DSD, tracker modules (when FFmpeg has libopenmpt)… Runs `ffmpeg` as a process that
/// writes 32-bit float PCM to a pipe, so nothing is linked and the app works without it.
enum FFmpeg {
    static var enabled = true

    /// Extensions macOS can't decode that FFmpeg usually can.
    static let extensions: Set<String> = ["ogg", "oga", "opus", "spx", "ape", "wv", "wma", "asf", "mpc", "mp+", "tta",
                                          "dsf", "dff", "mka", "webm", "dts", "ac3", "eac3", "tak", "shn", "ofr",
                                          "mod", "xm", "it", "s3m", "mptm", "au", "voc", "amr", "ra", "rm"]

    static let ffmpegPath: String? = locate("ffmpeg")
    static let ffprobePath: String? = locate("ffprobe")
    static var available: Bool { enabled && ffmpegPath != nil && ffprobePath != nil }

    private static func locate(_ tool: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        if let res = Bundle.main.resourcePath { dirs.insert(res, at: 0) }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(tool)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var version: String? {
        guard let p = ffmpegPath, let out = run(p, ["-hide_banner", "-version"]) else { return nil }
        return out.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "ffmpeg version ", with: "") }
            .map { String($0.split(separator: " ").first ?? "") }
    }

    struct Probe {
        var duration: Double = 0
        var sampleRate: Double = 44100
        var channels = 2
        var bitrate = 0
        var codec = ""
        var title: String?
        var artist: String?
        var album: String?
    }

    /// ffprobe: format, first audio stream and tags (JSON).
    static func probe(_ url: URL) -> Probe? {
        guard let p = ffprobePath, let out = run(p, ["-v", "quiet", "-print_format", "json", "-show_format",
                                                     "-show_streams", "-select_streams", "a:0", url.isFileURL ? url.path : url.absoluteString]),
              let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let stream = (json["streams"] as? [[String: Any]])?.first else { return nil }
        let format = json["format"] as? [String: Any] ?? [:]
        var r = Probe()
        r.duration = Double(format["duration"] as? String ?? "") ?? Double(stream["duration"] as? String ?? "") ?? 0
        r.sampleRate = Double(stream["sample_rate"] as? String ?? "") ?? 44100
        r.channels = max(1, min(2, stream["channels"] as? Int ?? 2))
        r.bitrate = (Int(format["bit_rate"] as? String ?? "") ?? Int(stream["bit_rate"] as? String ?? "") ?? 0) / 1000
        r.codec = stream["codec_name"] as? String ?? ""
        // DSD (2.8 MHz+) is converted to PCM at 176.4 kHz: plenty, and the mixer resamples anyway.
        if r.sampleRate > 192_000 { r.sampleRate = 176_400 }
        var tags: [String: String] = [:]
        for src in [format["tags"], stream["tags"]] {
            for (k, v) in (src as? [String: Any]) ?? [:] { tags[k.lowercased()] = "\(v)" }
        }
        r.title = tags["title"]
        r.artist = tags["artist"] ?? tags["album_artist"]
        r.album = tags["album"]
        return r
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}

/// Decodes a file (from an offset) or a live URL with ffmpeg into non-interleaved float PCM buffers.
/// `waitForRoom` provides back-pressure so a fast local decode doesn't fill memory.
final class FFmpegDecoder {
    let format: AVAudioFormat
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// nil = clean end of input.
    var onEnd: ((Error?) -> Void)?
    /// Blocks the reader thread while too much audio is already queued.
    var waitForRoom: (() -> Void)?

    private let input: String
    private let startOffset: Double
    private let live: Bool
    private var process: Process?
    private var cancelled = false
    private let lock = NSLock()

    init(url: URL, start: Double = 0, sampleRate: Double, channels: Int) {
        input = url.isFileURL ? url.path : url.absoluteString
        live = !url.isFileURL
        startOffset = start
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!
    }

    func start() {
        guard let exe = FFmpeg.ffmpegPath else { onEnd?(StreamError.unsupported("FFmpeg mancante")); return }
        var args = ["-nostdin", "-hide_banner", "-v", "error"]
        if live { args += ["-reconnect", "1", "-reconnect_streamed", "1", "-user_agent", RadioStream.userAgent] }
        if startOffset > 0 { args += ["-ss", String(format: "%.3f", startOffset)] }
        args += ["-i", input, "-vn", "-sn", "-map", "0:a:0", "-f", "f32le", "-acodec", "pcm_f32le",
                 "-ac", "\(format.channelCount)", "-ar", "\(Int(format.sampleRate))", "pipe:1"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { onEnd?(error); return }
        lock.lock(); process = p; lock.unlock()
        let handle = out.fileHandleForReading
        let ch = Int(format.channelCount)
        let framesPerChunk = 8192
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending = Data()
            while let self, !self.isCancelled {
                self.waitForRoom?()
                guard let chunk = try? handle.read(upToCount: framesPerChunk * ch * 4), !chunk.isEmpty else { break }
                pending += chunk
                let frames = pending.count / (ch * 4)
                guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                pending.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Float.self)
                    for c in 0..<ch {
                        let dst = buf.floatChannelData![c]
                        for i in 0..<frames { dst[i] = src[i * ch + c] }
                    }
                }
                pending.removeFirst(frames * ch * 4)
                self.onBuffer?(buf)
            }
            p.waitUntilExit()
            guard let self, !self.isCancelled else { return }
            self.onEnd?(p.terminationStatus == 0 || p.terminationStatus == 255 ? nil : StreamError.ended)
        }
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
