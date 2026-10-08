import AVFoundation
import Foundation

/// Reading and writing track tags for the tag editor.
/// - MP3: ID3v2 (keeps the file's 2.3 or 2.4 version and every frame we don't edit; updates an ID3v1 tag if present)
/// - FLAC: Vorbis comment + PICTURE blocks (keeps other comments and blocks)
/// - MP4 family (m4a, m4b, mp4, aac in mp4, ALAC): AVFoundation passthrough export with updated metadata
/// Other formats are read-only. Writes go in place when the new tag fits the old one's room (padding),
/// otherwise to a temporary file that atomically replaces the original.
struct TagSet: Equatable {
    var title = "", artist = "", album = "", albumArtist = "", year = "", genre = "", comment = ""
    var track = "", trackTotal = "", disc = "", discTotal = ""
    /// Star rating "1"…"5" ("" = none). MP3: POPM frame; FLAC: RATING (0–100). MP4 has no standard star tag.
    var rating = ""
    var artwork: Data?

    static let fields: [(String, WritableKeyPath<TagSet, String>)] = [
        ("Title", \.title), ("Artist", \.artist), ("Album", \.album), ("Album Artist", \.albumArtist),
        ("Year", \.year), ("Genre", \.genre), ("Track", \.track), ("Total Tracks", \.trackTotal),
        ("Disc", \.disc), ("Total Discs", \.discTotal), ("Comment", \.comment),
    ]
}

/// What to change: nil leaves a field as it is, "" clears it.
struct TagUpdate {
    var fields: [WritableKeyPath<TagSet, String>: String] = [:]
    enum Artwork: Equatable { case keep, remove, set(Data) }
    var artwork: Artwork = .keep
    var isEmpty: Bool { fields.isEmpty && artwork == .keep }

    func apply(to t: TagSet) -> TagSet {
        var x = t
        for (k, v) in fields { x[keyPath: k] = v }
        switch artwork {
        case .keep: break
        case .remove: x.artwork = nil
        case .set(let d): x.artwork = d
        }
        return x
    }
}

enum TagError: LocalizedError {
    case readOnly(String), corrupt(String), export(String)
    var errorDescription: String? {
        switch self {
        case .readOnly(let f): return "\(f) format: tags are read-only"
        case .corrupt(let s): return "Invalid file: \(s)"
        case .export(let s): return "Couldn’t write MP4: \(s)"
        }
    }
}

enum TagIO {
    enum Kind { case id3, flac, mp4, other }

    static func kind(_ url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "mp3": return .id3
        case "flac": return .flac
        case "m4a", "m4b", "mp4", "aac", "alac", "m4p": return .mp4
        default: return .other
        }
    }

    static func canWrite(_ url: URL) -> Bool { url.isFileURL && kind(url) != .other }

    static func read(_ url: URL) async -> TagSet {
        switch kind(url) {
        case .id3: if let t = try? ID3.read(url) { return t }
        case .flac: if let t = try? FLACTags.read(url) { return t }
        default: break
        }
        return await readAV(url)
    }

    static func write(_ url: URL, _ update: TagUpdate) async throws {
        guard !update.isEmpty else { return }
        switch kind(url) {
        case .id3: try ID3.write(url, update)
        case .flac: try FLACTags.write(url, update)
        case .mp4: try await MP4Tags.write(url, update)
        case .other: throw TagError.readOnly(url.pathExtension.uppercased())
        }
    }

    /// Generic reader (MP4 and anything AVFoundation understands).
    static func readAV(_ url: URL) async -> TagSet {
        var t = TagSet()
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.metadata)) ?? []
        for item in items {
            let id = item.identifier
            let s = (try? await item.load(.stringValue)) ?? nil
            switch id {
            case .iTunesMetadataSongName, .id3MetadataTitleDescription, .commonIdentifierTitle: t.title = s ?? t.title
            case .iTunesMetadataArtist, .id3MetadataLeadPerformer, .commonIdentifierArtist: t.artist = s ?? t.artist
            case .iTunesMetadataAlbum, .id3MetadataAlbumTitle, .commonIdentifierAlbumName: t.album = s ?? t.album
            case .iTunesMetadataAlbumArtist, .id3MetadataBand: t.albumArtist = s ?? t.albumArtist
            case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime: t.year = String((s ?? "").prefix(4))
            case .iTunesMetadataUserGenre, .id3MetadataContentType: t.genre = s ?? t.genre
            case .iTunesMetadataUserComment, .id3MetadataComments: t.comment = s ?? t.comment
            case .iTunesMetadataTrackNumber, .iTunesMetadataDiscNumber:
                // Binary: 2 reserved bytes, number (UInt16 BE), total (UInt16 BE).
                if let d = try? await item.load(.dataValue), d.count >= 6 {
                    let b = [UInt8](d)
                    let n = Int(b[2]) << 8 | Int(b[3]), tot = Int(b[4]) << 8 | Int(b[5])
                    if id == .iTunesMetadataTrackNumber {
                        t.track = n > 0 ? "\(n)" : ""; t.trackTotal = tot > 0 ? "\(tot)" : ""
                    } else {
                        t.disc = n > 0 ? "\(n)" : ""; t.discTotal = tot > 0 ? "\(tot)" : ""
                    }
                }
            case .iTunesMetadataCoverArt, .id3MetadataAttachedPicture, .commonIdentifierArtwork:
                if t.artwork == nil, let d = try? await item.load(.dataValue) { t.artwork = d }
            default: break
            }
        }
        return t
    }

    /// Writes `data` to `url` through a temporary file in the same folder, then swaps it in atomically.
    static func replace(_ url: URL, with data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).musicamp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp)
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// "3/12" → ("3", "12").
    static func splitNumber(_ s: String) -> (String, String) {
        let parts = s.split(separator: "/", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    static func joinNumber(_ n: String, _ tot: String) -> String { tot.isEmpty ? n : (n.isEmpty ? "" : "\(n)/\(tot)") }

    static func imageMIME(_ d: Data) -> String {
        let b = [UInt8](d.prefix(8))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "image/jpeg"
    }
}

// MARK: - ID3v2

enum ID3 {
    struct Frame { var id: String; var data: [UInt8] }

    /// Parsed tag: version (3 or 4), frames, size of the tag on disk (header + body + footer), ID3v1 present.
    struct Tag {
        var version: UInt8 = 3
        var frames: [Frame] = []
        var diskSize = 0
    }

    static func syncsafe(_ b: ArraySlice<UInt8>) -> Int {
        b.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
    }

    static func syncsafeBytes(_ v: Int) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    static func parse(_ head: [UInt8]) -> Tag {
        var tag = Tag()
        guard head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33, head[3] == 3 || head[3] == 4 else { return tag }
        tag.version = head[3]
        let flags = head[5]
        let size = syncsafe(head[6..<10])
        tag.diskSize = 10 + size + ((flags & 0x10) != 0 ? 10 : 0)
        var body = Array(head[10..<min(head.count, 10 + size)])
        if (flags & 0x80) != 0, tag.version == 3 {
            // Whole-tag unsynchronisation (v2.3): drop the 0x00 inserted after each 0xFF.
            var out: [UInt8] = []
            var i = 0
            while i < body.count { out.append(body[i]); if body[i] == 0xFF, i + 1 < body.count, body[i + 1] == 0 { i += 1 }; i += 1 }
            body = out
        }
        var i = 0
        if (flags & 0x40) != 0, body.count >= 4 {   // extended header
            let ext = tag.version == 4 ? syncsafe(body[0..<4]) : (Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])) + 4
            i = min(body.count, ext)
        }
        while i + 10 <= body.count {
            guard let id = String(bytes: body[i..<(i + 4)], encoding: .ascii), id.allSatisfy({ $0.isUppercase || $0.isNumber }) else { break }
            let fs = tag.version == 4 ? syncsafe(body[(i + 4)..<(i + 8)])
                                      : (Int(body[i + 4]) << 24 | Int(body[i + 5]) << 16 | Int(body[i + 6]) << 8 | Int(body[i + 7]))
            guard fs > 0, i + 10 + fs <= body.count else { break }
            var data = Array(body[(i + 10)..<(i + 10 + fs)])
            if tag.version == 4, (body[i + 9] & 0x02) != 0 {   // per-frame unsynchronisation
                var out: [UInt8] = []
                var k = 0
                while k < data.count { out.append(data[k]); if data[k] == 0xFF, k + 1 < data.count, data[k + 1] == 0 { k += 1 }; k += 1 }
                data = out
            }
            if tag.version == 4, (body[i + 9] & 0x01) != 0, data.count >= 4 { data.removeFirst(4) }   // data length indicator
            tag.frames.append(Frame(id: id, data: data))
            i += 10 + fs
        }
        return tag
    }

    // Text decoding/encoding.
    static func decodeText(_ d: ArraySlice<UInt8>, encoding: UInt8) -> String {
        let data = Data(d)
        let s: String?
        switch encoding {
        case 1: s = String(data: data, encoding: .utf16)
        case 2: s = String(data: data, encoding: .utf16BigEndian)
        case 3: s = String(data: data, encoding: .utf8)
        default: s = String(data: data, encoding: .isoLatin1)
        }
        return (s ?? "").replacingOccurrences(of: "\u{0}", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ f: Frame) -> String {
        guard let enc = f.data.first else { return "" }
        return decodeText(f.data.dropFirst(), encoding: enc)
    }

    /// Best encoding for this version: Latin-1 when possible, else UTF-8 (2.4) or UTF-16 with BOM (2.3).
    static func encode(_ s: String, version: UInt8) -> (UInt8, [UInt8]) {
        if s.unicodeScalars.allSatisfy({ $0.value < 0x80 }) { return (0, Array(s.utf8)) }
        if version == 4 { return (3, Array(s.utf8)) }
        var u: [UInt8] = [0xFF, 0xFE]
        for c in s.utf16 { u += [UInt8(c & 0xFF), UInt8(c >> 8)] }
        return (1, u)
    }

    static func textFrame(_ id: String, _ s: String, version: UInt8) -> Frame {
        let (enc, bytes) = encode(s, version: version)
        return Frame(id: id, data: [enc] + bytes)
    }

    static func terminator(_ enc: UInt8) -> [UInt8] { enc == 1 || enc == 2 ? [0, 0] : [0] }

    /// COMM / USLT layout: encoding, language, description (terminated), text.
    static func commentParts(_ f: Frame) -> (desc: String, text: String)? {
        guard f.data.count >= 4 else { return nil }
        let enc = f.data[0]
        let rest = Array(f.data[4...])
        let term = terminator(enc)
        var i = 0
        while i + term.count <= rest.count {
            if Array(rest[i..<(i + term.count)]) == term, term.count == 1 || i % 2 == 0 { break }
            i += term.count == 2 ? 2 : 1
        }
        let desc = decodeText(rest[0..<min(i, rest.count)], encoding: enc)
        let text = i + term.count <= rest.count ? decodeText(rest[(i + term.count)...], encoding: enc) : ""
        return (desc, text)
    }

    /// APIC: encoding, MIME (Latin-1, terminated), picture type, description (terminated), data.
    static func pictureParts(_ f: Frame) -> (type: UInt8, data: Data)? {
        guard f.data.count > 4 else { return nil }
        let enc = f.data[0]
        var i = 1
        while i < f.data.count, f.data[i] != 0 { i += 1 }
        i += 1
        guard i < f.data.count else { return nil }
        let type = f.data[i]
        i += 1
        let term = terminator(enc)
        while i + term.count <= f.data.count {
            if Array(f.data[i..<(i + term.count)]) == term { break }
            i += 1
        }
        i += term.count
        guard i <= f.data.count else { return nil }
        return (type, Data(f.data[i...]))
    }

    static func tagSet(_ tag: Tag) -> TagSet {
        var t = TagSet()
        for f in tag.frames {
            switch f.id {
            case "TIT2": t.title = text(f)
            case "TPE1": t.artist = text(f)
            case "TALB": t.album = text(f)
            case "TPE2": t.albumArtist = text(f)
            case "TYER", "TDRC": if t.year.isEmpty || f.id == "TDRC" { t.year = String(text(f).prefix(4)) }
            case "TCON": t.genre = genreName(text(f))
            case "TRCK": (t.track, t.trackTotal) = TagIO.splitNumber(text(f))
            case "TPOS": (t.disc, t.discTotal) = TagIO.splitNumber(text(f))
            case "COMM": if let c = commentParts(f), c.desc.isEmpty, t.comment.isEmpty { t.comment = c.text }
            case "APIC": if let p = pictureParts(f), t.artwork == nil || p.type == 3 { t.artwork = p.data }
            case "POPM": if let s = popmStars(f), t.rating.isEmpty || popmEmail(f) == popmOwner { t.rating = s > 0 ? String(s) : "" }
            default: break
            }
        }
        return t
    }

    /// The POPM owner MusicAmp writes: Windows Media Player's, which most players (foobar2000, MusicBee,
    /// MediaMonkey, Mp3tag) read.
    static let popmOwner = "Windows Media Player 9 Series"

    static func popmEmail(_ f: Frame) -> String? {
        guard let z = f.data.firstIndex(of: 0) else { return nil }
        return String(decoding: f.data[..<z], as: UTF8.self)
    }

    /// POPM rating byte → stars, with the usual ranges (1 = 1★, 64 = 2★, 128 = 3★, 196 = 4★, 255 = 5★).
    static func popmStars(_ f: Frame) -> Int? {
        guard let z = f.data.firstIndex(of: 0), z + 1 < f.data.count else { return nil }
        switch f.data[z + 1] {
        case 0: return 0
        case 1...31: return 1
        case 32...95: return 2
        case 96...159: return 3
        case 160...223: return 4
        default: return 5
        }
    }

    static func popmFrame(stars: Int) -> Frame {
        let byte: [UInt8] = [0, 1, 64, 128, 196, 255]
        return Frame(id: "POPM", data: Array(popmOwner.utf8) + [0, byte[max(0, min(5, stars))]])
    }

    /// "(17)" or "17" (ID3v1 genre numbers in v2) → name.
    static func genreName(_ s: String) -> String {
        let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        if let n = Int(digits), n >= 0, n < v1Genres.count, s.count <= 5 { return v1Genres[n] }
        return s
    }

    static func read(_ url: URL) throws -> TagSet {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        guard let head10 = try h.read(upToCount: 10), head10.count == 10 else { return TagSet() }
        let b = [UInt8](head10)
        guard b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return TagSet() }
        let size = syncsafe(b[6..<10])
        let rest = try h.read(upToCount: size) ?? Data()
        return tagSet(parse(b + [UInt8](rest)))
    }

    /// Frames after applying `update` (frames we don't manage are kept in order).
    static func updatedFrames(_ tag: Tag, _ update: TagUpdate, version v: UInt8) -> [Frame] {
        let current = tagSet(tag)
        let new = update.apply(to: current)
        var frames = tag.frames
        func setText(_ id: String, _ value: String, also: [String] = []) {
            frames.removeAll { $0.id == id || also.contains($0.id) }
            if !value.isEmpty { frames.append(textFrame(id, value, version: v)) }
        }
        for (k, _) in update.fields {
            switch k {
            case \TagSet.title: setText("TIT2", new.title)
            case \TagSet.artist: setText("TPE1", new.artist)
            case \TagSet.album: setText("TALB", new.album)
            case \TagSet.albumArtist: setText("TPE2", new.albumArtist)
            case \TagSet.year: setText(v == 4 ? "TDRC" : "TYER", new.year, also: ["TYER", "TDRC", "TDAT", "TIME"])
            case \TagSet.genre: setText("TCON", new.genre)
            case \TagSet.rating:
                // One rating per file: other players' POPM frames would contradict ours.
                frames.removeAll { $0.id == "POPM" }
                if let s = Int(new.rating), s > 0 { frames.append(popmFrame(stars: s)) }
            case \TagSet.track, \TagSet.trackTotal: setText("TRCK", TagIO.joinNumber(new.track, new.trackTotal))
            case \TagSet.disc, \TagSet.discTotal: setText("TPOS", TagIO.joinNumber(new.disc, new.discTotal))
            case \TagSet.comment:
                frames.removeAll { $0.id == "COMM" && (commentParts($0)?.desc.isEmpty ?? false) }
                if !new.comment.isEmpty {
                    let (enc, bytes) = encode(new.comment, version: v)
                    frames.append(Frame(id: "COMM", data: [enc] + Array("eng".utf8) + terminator(enc) + bytes))
                }
            default: break
            }
        }
        switch update.artwork {
        case .keep: break
        case .remove: frames.removeAll { $0.id == "APIC" }
        case .set(let d):
            frames.removeAll { $0.id == "APIC" && (pictureParts($0)?.type == 3 || pictureParts($0)?.type == 0) }
            frames.append(Frame(id: "APIC", data: [0] + Array(TagIO.imageMIME(d).utf8) + [0, 3, 0] + [UInt8](d)))
        }
        return frames
    }

    static func serialize(_ frames: [Frame], version v: UInt8, totalSize: Int? = nil, padding: Int = 2048) -> [UInt8] {
        var body: [UInt8] = []
        for f in frames {
            var data = f.data
            // UTF-8 text is a 2.4 feature: re-encode as UTF-16 for a 2.3 tag.
            if v == 3, f.id.hasPrefix("T"), data.first == 3 {
                let s = decodeText(data.dropFirst(), encoding: 3)
                data = textFrame(f.id, s, version: 3).data
            }
            let size = v == 4 ? syncsafeBytes(data.count)
                              : [UInt8((data.count >> 24) & 0xFF), UInt8((data.count >> 16) & 0xFF), UInt8((data.count >> 8) & 0xFF), UInt8(data.count & 0xFF)]
            body += Array(f.id.utf8) + size + [0, 0] + data
        }
        let bodySize = totalSize.map { $0 - 10 } ?? (body.count + padding)
        body += [UInt8](repeating: 0, count: max(0, bodySize - body.count))
        return Array("ID3".utf8) + [v, 0, 0] + syncsafeBytes(body.count) + body
    }

    static func write(_ url: URL, _ update: TagUpdate) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let b = [UInt8](data.prefix(10))
        var tag = Tag()
        if b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            let size = syncsafe(b[6..<10])
            tag = parse([UInt8](data.prefix(10 + size)))
            if tag.diskSize == 0 { tag.diskSize = 10 + size }
        }
        let v: UInt8 = tag.version == 4 ? 4 : 3
        let frames = updatedFrames(tag, update, version: v)
        let fitted = serialize(frames, version: v, padding: 0)
        let audioStart = tag.diskSize
        var audio = data.subdata(in: audioStart..<data.count)
        updateV1(&audio, update.apply(to: tagSet(tag)))
        if fitted.count <= tag.diskSize, tag.diskSize > 0 {
            // Fits in the old tag's room: rewrite only the tag (and ID3v1 at the end).
            let newTag = serialize(frames, version: v, totalSize: tag.diskSize)
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seek(toOffset: 0)
            try h.write(contentsOf: newTag)
            if audio.count >= 128, data.count >= 128, audio.suffix(128) != data.suffix(128) {
                try h.seek(toOffset: UInt64(data.count - 128))
                try h.write(contentsOf: audio.suffix(128))
            }
        } else {
            try TagIO.replace(url, with: Data(serialize(frames, version: v)) + audio)
        }
    }

    /// Keeps an existing ID3v1 tag ("TAG" in the last 128 bytes) in step with the new values.
    static func updateV1(_ audio: inout Data, _ t: TagSet) {
        guard audio.count >= 128 else { return }
        let start = audio.count - 128
        guard audio[start] == 0x54, audio[start + 1] == 0x41, audio[start + 2] == 0x47 else { return }
        func put(_ s: String, _ offset: Int, _ len: Int) {
            let bytes = Array((s.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()).prefix(len))
            for k in 0..<len { audio[start + offset + k] = k < bytes.count ? bytes[k] : 0 }
        }
        put(t.title, 3, 30); put(t.artist, 33, 30); put(t.album, 63, 30); put(t.year, 93, 4)
        // ID3v1.1: comment is 28 bytes when a track number is stored in byte 126.
        if let n = UInt8(t.track), n > 0 { put(t.comment, 97, 28); audio[start + 125] = 0; audio[start + 126] = n } else { put(t.comment, 97, 30) }
    }

    static let v1Genres = ["Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal", "New Age",
        "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative", "Ska", "Death Metal", "Pranks",
        "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
        "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk",
        "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
        "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk",
        "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock"]
}

// MARK: - FLAC

enum FLACTags {
    struct Block { var type: UInt8; var data: [UInt8] }

    /// Metadata blocks and the offset where audio frames start.
    static func blocks(_ d: Data) throws -> ([Block], Int) {
        let b = [UInt8](d.prefix(4))
        var start = 0
        // Some FLAC files carry an ID3v2 tag in front: skip it.
        if b.count == 4, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33, d.count >= 10 {
            start = 10 + ID3.syncsafe([UInt8](d[6..<10])[0..<4])
        }
        guard d.count >= start + 4, [UInt8](d[start..<(start + 4)]) == Array("fLaC".utf8) else { throw TagError.corrupt("missing FLAC header") }
        var out: [Block] = []
        var i = start + 4
        while i + 4 <= d.count {
            let h = d[i]
            let len = Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
            guard i + 4 + len <= d.count else { throw TagError.corrupt("truncated FLAC block") }
            out.append(Block(type: h & 0x7F, data: [UInt8](d[(i + 4)..<(i + 4 + len)])))
            i += 4 + len
            if (h & 0x80) != 0 { break }
        }
        return (out, i)
    }

    static func le32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
    static func be32(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
    static func le32Bytes(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    static func be32Bytes(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    /// Vorbis comment → vendor and "KEY=value" entries.
    static func comments(_ b: [UInt8]) -> (vendor: [UInt8], entries: [String]) {
        guard b.count >= 8 else { return ([], []) }
        let vl = le32(b, 0)
        guard 4 + vl + 4 <= b.count else { return ([], []) }
        let vendor = Array(b[4..<(4 + vl)])
        var i = 4 + vl
        let n = le32(b, i)
        i += 4
        var out: [String] = []
        for _ in 0..<n {
            guard i + 4 <= b.count else { break }
            let l = le32(b, i)
            i += 4
            guard i + l <= b.count else { break }
            out.append(String(decoding: b[i..<(i + l)], as: UTF8.self))
            i += l
        }
        return (vendor, out)
    }

    static func picture(_ b: [UInt8]) -> (type: Int, data: Data)? {
        guard b.count >= 32 else { return nil }
        var i = 0
        let type = be32(b, i); i += 4
        let ml = be32(b, i); i += 4 + ml
        guard i + 4 <= b.count else { return nil }
        let dl = be32(b, i); i += 4 + dl
        i += 16
        guard i + 4 <= b.count else { return nil }
        let len = be32(b, i); i += 4
        guard i + len <= b.count else { return nil }
        return (type, Data(b[i..<(i + len)]))
    }

    static let keys: [(String, WritableKeyPath<TagSet, String>)] = [
        ("TITLE", \.title), ("ARTIST", \.artist), ("ALBUM", \.album), ("ALBUMARTIST", \.albumArtist), ("DATE", \.year),
        ("GENRE", \.genre), ("TRACKNUMBER", \.track), ("TRACKTOTAL", \.trackTotal), ("DISCNUMBER", \.disc),
        ("DISCTOTAL", \.discTotal), ("COMMENT", \.comment),
    ]

    static func tagSet(_ blocks: [Block]) -> TagSet {
        var t = TagSet()
        for bl in blocks {
            if bl.type == 4 {
                for e in comments(bl.data).entries {
                    guard let eq = e.firstIndex(of: "=") else { continue }
                    let k = e[..<eq].uppercased(), v = String(e[e.index(after: eq)...])
                    if let path = keys.first(where: { $0.0 == k })?.1 { t[keyPath: path] = path == \TagSet.year ? String(v.prefix(4)) : v }
                    if k == "TRACKNUMBER", v.contains("/") { (t.track, t.trackTotal) = TagIO.splitNumber(v) }
                    if k == "DISCNUMBER", v.contains("/") { (t.disc, t.discTotal) = TagIO.splitNumber(v) }
                    if k == "DESCRIPTION", t.comment.isEmpty { t.comment = v }
                    if k == "TOTALTRACKS", t.trackTotal.isEmpty { t.trackTotal = v }
                    if k == "TOTALDISCS", t.discTotal.isEmpty { t.discTotal = v }
                    if k == "RATING", let n = Double(v.replacingOccurrences(of: ",", with: ".")) {
                        // 0–100 (MusicBee, Kodi, MediaMonkey) or 1–5 (foobar2000).
                        let stars = n <= 5 ? Int(n.rounded()) : Int((n / 20).rounded())
                        t.rating = stars > 0 ? String(min(5, stars)) : ""
                    }
                }
            } else if bl.type == 6, let p = picture(bl.data), t.artwork == nil || p.type == 3 {
                t.artwork = p.data
            }
        }
        return t
    }

    static func read(_ url: URL) throws -> TagSet {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        return tagSet(try blocks(d).0)
    }

    static func write(_ url: URL, _ update: TagUpdate) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        let (old, audioStart) = try blocks(d)
        let prefixEnd = d.starts(with: Array("fLaC".utf8)) ? 0 : (audioStart - old.reduce(4) { $0 + 4 + $1.data.count })
        let new = update.apply(to: tagSet(old))
        // Vorbis comment: keep entries we don't manage, replace the ones being changed.
        let vc: (vendor: [UInt8], entries: [String]) = old.first { $0.type == 4 }.map { comments($0.data) } ?? (Array("MusicAmp".utf8), [])
        var entries = vc.entries
        let changed = Set(update.fields.keys)
        if changed.contains(\TagSet.rating) {
            entries.removeAll { $0.uppercased().hasPrefix("RATING=") }
            if let s = Int(new.rating), s > 0 { entries.append("RATING=\(min(5, s) * 20)") }
        }
        for (key, path) in keys where changed.contains(path) {
            entries.removeAll { $0.uppercased().hasPrefix(key + "=") }
            if key == "COMMENT" { entries.removeAll { $0.uppercased().hasPrefix("DESCRIPTION=") } }
            if key == "TRACKTOTAL" { entries.removeAll { $0.uppercased().hasPrefix("TOTALTRACKS=") } }
            if key == "DISCTOTAL" { entries.removeAll { $0.uppercased().hasPrefix("TOTALDISCS=") } }
            let v = new[keyPath: path]
            if !v.isEmpty { entries.append("\(key)=\(v)") }
        }
        var vcData = le32Bytes(vc.vendor.count) + vc.vendor + le32Bytes(entries.count)
        for e in entries { let u = Array(e.utf8); vcData += le32Bytes(u.count) + u }

        var out: [Block] = old.filter { $0.type != 4 && $0.type != 1 }
        out.insert(Block(type: 4, data: vcData), at: min(1, out.count))
        switch update.artwork {
        case .keep: break
        case .remove: out.removeAll { $0.type == 6 }
        case .set(let img):
            out.removeAll { $0.type == 6 && (picture($0.data)?.type == 3 || picture($0.data)?.type == 0) }
            let mime = Array(TagIO.imageMIME(img).utf8)
            let pic = be32Bytes(3) + be32Bytes(mime.count) + mime + be32Bytes(0) + be32Bytes(0) + be32Bytes(0) + be32Bytes(0) + be32Bytes(0)
                + be32Bytes(img.count) + [UInt8](img)
            out.append(Block(type: 6, data: pic))
        }
        let oldMeta = audioStart - prefixEnd - 4
        let used = out.reduce(0) { $0 + 4 + $1.data.count }
        func serialize(padding: Int) -> [UInt8] {
            var blocks = out
            if padding >= 0 { blocks.append(Block(type: 1, data: [UInt8](repeating: 0, count: padding))) }
            var bytes = Array("fLaC".utf8)
            for (k, bl) in blocks.enumerated() {
                let last: UInt8 = k == blocks.count - 1 ? 0x80 : 0
                bytes += [last | bl.type, UInt8((bl.data.count >> 16) & 0xFF), UInt8((bl.data.count >> 8) & 0xFF), UInt8(bl.data.count & 0xFF)] + bl.data
            }
            return bytes
        }
        if used + 4 <= oldMeta {
            // Fits in the old metadata room: rewrite it in place, the rest becomes padding.
            let bytes = serialize(padding: oldMeta - used - 4)
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(prefixEnd))
            try h.write(contentsOf: bytes)
        } else {
            try TagIO.replace(url, with: d.prefix(prefixEnd) + Data(serialize(padding: 4096)) + d.subdata(in: audioStart..<d.count))
        }
    }
}

// MARK: - MP4

enum MP4Tags {
    static func write(_ url: URL, _ update: TagUpdate) async throws {
        let asset = AVURLAsset(url: url)
        let current = await TagIO.readAV(url)
        let new = update.apply(to: current)
        var items = ((try? await asset.load(.metadata)) ?? []).compactMap { $0.mutableCopy() as? AVMutableMetadataItem }
        func set(_ id: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            items.removeAll { $0.identifier == id }
            guard let value else { return }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            if let dataType { m.dataType = dataType }
            items.append(m)
        }
        func str(_ s: String) -> NSString? { s.isEmpty ? nil : s as NSString }
        func pair(_ n: String, _ tot: String) -> NSData? {
            let a = Int(n) ?? 0, b = Int(tot) ?? 0
            guard a > 0 || b > 0 else { return nil }
            return Data([0, 0, UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF), 0, 0]) as NSData
        }
        for (k, _) in update.fields {
            switch k {
            case \TagSet.title: set(.iTunesMetadataSongName, str(new.title))
            case \TagSet.artist: set(.iTunesMetadataArtist, str(new.artist))
            case \TagSet.album: set(.iTunesMetadataAlbum, str(new.album))
            case \TagSet.albumArtist: set(.iTunesMetadataAlbumArtist, str(new.albumArtist))
            case \TagSet.year: set(.iTunesMetadataReleaseDate, str(new.year))
            case \TagSet.genre: set(.iTunesMetadataUserGenre, str(new.genre)); items.removeAll { $0.identifier == .iTunesMetadataPredefinedGenre }
            case \TagSet.comment: set(.iTunesMetadataUserComment, str(new.comment))
            case \TagSet.track, \TagSet.trackTotal: set(.iTunesMetadataTrackNumber, pair(new.track, new.trackTotal), dataType: kCMMetadataBaseDataType_RawData as String)
            case \TagSet.disc, \TagSet.discTotal: set(.iTunesMetadataDiscNumber, pair(new.disc, new.discTotal), dataType: kCMMetadataBaseDataType_RawData as String)
            default: break
            }
        }
        switch update.artwork {
        case .keep: break
        case .remove: set(.iTunesMetadataCoverArt, nil)
        case .set(let d):
            set(.iTunesMetadataCoverArt, d as NSData,
                dataType: (TagIO.imageMIME(d) == "image/png" ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String)
        }
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw TagError.export("session") }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.deletingPathExtension().lastPathComponent).musicamp-\(UUID().uuidString.prefix(8)).m4a")
        ex.outputURL = tmp
        ex.outputFileType = .m4a
        ex.metadata = items
        await ex.export()
        guard ex.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw TagError.export(ex.error?.localizedDescription ?? "status \(ex.status.rawValue)")
        }
        do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
