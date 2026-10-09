import AVFoundation
import Network

/// One encoding of the live stream and the listeners that receive it: AAC (ADTS frames, 320 kb/s) or FLAC
/// (lossless, 24-bit). A listener joining late gets the format's header first (FLAC: "fLaC" + STREAMINFO),
/// then frames as they are made. Runs on LiveStream's queue.
final class StreamEncoder {
    enum Kind: String { case aac, flac }

    let kind: Kind
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private(set) var inFormat: AVAudioFormat?
    private(set) var clients: [ObjectIdentifier: NWConnection] = [:]
    /// Encoded packets sent, for tests.
    private(set) var packetsSent = 0
    static let aacBitRate = 320_000
    static let flacBlock: UInt32 = 4096

    init(kind: Kind) { self.kind = kind }

    var contentType: String { kind == .aac ? "audio/aac" : "audio/flac" }
    var path: String { kind == .aac ? "/live.aac" : "/live.flac" }

    func add(_ c: NWConnection) {
        clients[ObjectIdentifier(c)] = c
        if let h = header() { c.send(content: h, completion: .contentProcessed { _ in }) }
    }

    @discardableResult
    func remove(_ c: NWConnection) -> Bool { clients.removeValue(forKey: ObjectIdentifier(c)) != nil }

    func closeAll() {
        clients.values.forEach { $0.cancel() }
        clients = [:]
    }

    /// Encoder for `fmt` (rebuilt when the chain's rate changes).
    @discardableResult
    func prepare(_ fmt: AVAudioFormat) -> Bool {
        if let c = converter, c.inputFormat == fmt { return true }
        var desc: AudioStreamBasicDescription
        switch kind {
        case .aac:
            desc = AudioStreamBasicDescription(mSampleRate: fmt.sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        case .flac:
            desc = AudioStreamBasicDescription(mSampleRate: fmt.sampleRate, mFormatID: kAudioFormatFLAC,
                                               mFormatFlags: kAppleLosslessFormatFlag_24BitSourceData,
                                               mBytesPerPacket: 0, mFramesPerPacket: StreamEncoder.flacBlock, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        }
        guard let out = AVAudioFormat(streamDescription: &desc), let conv = AVAudioConverter(from: fmt, to: out) else {
            converter = nil
            return false
        }
        if kind == .aac { conv.bitRate = StreamEncoder.aacBitRate }
        converter = conv
        outFormat = out
        inFormat = fmt
        return true
    }

    /// FLAC stream header: "fLaC" and a STREAMINFO block (block size fixed, length and MD5 unknown: it's live).
    func header() -> Data? {
        guard kind == .flac, let fmt = inFormat else { return nil }
        return StreamEncoder.flacHeader(sampleRate: Int(fmt.sampleRate), channels: 2, bitsPerSample: 24, block: Int(StreamEncoder.flacBlock))
    }

    static func flacHeader(sampleRate: Int, channels: Int, bitsPerSample: Int, block: Int) -> Data {
        var d = Data("fLaC".utf8)
        d += [0x80, 0x00, 0x00, 0x22]   // last metadata block, STREAMINFO, 34 bytes
        d += [UInt8(block >> 8), UInt8(block & 0xFF), UInt8(block >> 8), UInt8(block & 0xFF)]
        d += [0, 0, 0, 0, 0, 0]          // min/max frame size unknown
        // 20 bits sample rate, 3 bits channels−1, 5 bits bits-per-sample−1, 36 bits total samples (0 = unknown).
        let packed: UInt64 = (UInt64(sampleRate) << 44) | (UInt64(channels - 1) << 41) | (UInt64(bitsPerSample - 1) << 36)
        for shift in stride(from: 56, through: 0, by: -8) { d.append(UInt8((packed >> UInt64(shift)) & 0xFF)) }
        d += Data(count: 16)             // MD5 unknown
        return d
    }

    func encode(_ buf: AVAudioPCMBuffer) {
        guard !clients.isEmpty, prepare(buf.format), let conv = converter, let out = outFormat else { return }
        var given = false
        while true {
            let packet = AVAudioCompressedBuffer(format: out, packetCapacity: 8, maximumPacketSize: max(conv.maximumOutputPacketSize, 1))
            var error: NSError?
            let status = conv.convert(to: packet, error: &error) { _, outStatus in
                if given { outStatus.pointee = .noDataNow; return nil }
                given = true
                outStatus.pointee = .haveData
                return buf
            }
            guard status != .error, packet.packetCount > 0, let descs = packet.packetDescriptions else { break }
            var data = Data()
            for i in 0..<Int(packet.packetCount) {
                let d = descs[i]
                let len = Int(d.mDataByteSize)
                if kind == .aac { data += LiveStream.adtsHeader(length: len, sampleRate: out.sampleRate) }
                data += Data(bytes: packet.data.advanced(by: Int(d.mStartOffset)), count: len)
            }
            packetsSent += Int(packet.packetCount)
            for c in clients.values { c.send(content: data, completion: .contentProcessed { _ in }) }
            if status == .inputRanDry || status == .endOfStream { break }
        }
    }
}
