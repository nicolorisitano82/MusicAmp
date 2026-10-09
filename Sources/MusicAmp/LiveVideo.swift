import AppKit
import Combine
import CoreML
import CryptoKit
import FoundationModels
import ImageIO
import StableDiffusion
import UniformTypeIdentifiers

// MARK: - Models (sideloaded)

/// A Core ML Stable Diffusion model in MusicAmp's Models folder: Apple's compiled SDXL or SD 2.x resources
/// (TextEncoder, Unet, VAEDecoder, vocab, merges). Nothing is bundled: the user downloads or sideloads one.
struct LiveVideoModel: Identifiable, Hashable {
    let url: URL
    let isXL: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    /// split_einsum models are made for the Neural Engine; "original" ones run best on the GPU.
    var computeUnits: MLComputeUnits { name.contains("split_einsum") ? .cpuAndNeuralEngine : .cpuAndGPU }
    var size: Int { isXL ? 768 : 512 }
    var label: String {
        let base = isXL ? "SDXL" : (name.contains("2-1") ? "SD 2.1" : "Stable Diffusion")
        return "\(base) (\(computeUnits == .cpuAndNeuralEngine ? "Neural Engine" : "GPU"))"
    }

    static var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A folder holding a complete model.
    static func at(_ u: URL) -> LiveVideoModel? {
        let fm = FileManager.default
        func has(_ n: String) -> Bool { fm.fileExists(atPath: u.appendingPathComponent(n).path) }
        guard has("VAEDecoder.mlmodelc"), has("TextEncoder.mlmodelc"), has("vocab.json"), has("merges.txt"),
              has("Unet.mlmodelc") || (has("UnetChunk1.mlmodelc") && has("UnetChunk2.mlmodelc")) else { return nil }
        return LiveVideoModel(url: u, isXL: has("TextEncoder2.mlmodelc"))
    }

    /// Models found under the Models folder (up to three levels down, as Apple's zips unpack).
    static func installed() -> [LiveVideoModel] {
        var out: [LiveVideoModel] = []
        func scan(_ u: URL, depth: Int) {
            if let m = at(u) { out.append(m); return }
            guard depth > 0, let items = try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for i in items where (try? i.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && i.pathExtension != "mlmodelc" {
                scan(i, depth: depth - 1)
            }
        }
        scan(folder, depth: 3)
        return out.sorted { ($0.isXL ? 0 : 1, $0.name) < ($1.isXL ? 0 : 1, $1.name) }
    }

    /// Apple's ready-made Core ML models (Hugging Face), offered as downloads.
    struct Download: Identifiable {
        let id: String
        let title: String
        let bytes: Int64
        let url: URL
    }
    static let downloads: [Download] = [
        Download(id: "sdxl", title: "SDXL — best quality, 768 px, Neural Engine", bytes: 3_052_964_832,
                 url: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-xl-base-ios/resolve/main/coreml-stable-diffusion-xl-base-ios_split_einsum_compiled.zip")!),
        Download(id: "sd21", title: "SD 2.1 — faster, 512 px, GPU", bytes: 1_139_245_980,
                 url: URL(string: "https://huggingface.co/apple/coreml-stable-diffusion-2-1-base-palettized/resolve/main/coreml-stable-diffusion-2-1-base-palettized_original_compiled.zip")!),
    ]
}

// MARK: - Storyboard

/// Visual styles Stable Diffusion renders well; one per song, so the images belong together.
enum LiveVideoStyle: String, CaseIterable, Identifiable {
    /// `auto`: the director picks the look that fits the song.
    case auto, watercolor, illustration, oil, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic (the director chooses)"
        case .watercolor: return "Watercolor"
        case .illustration: return "Illustration"
        case .oil: return "Oil Painting"
        case .cinematic: return "Cinematic"
        }
    }
    var prompt: String {
        switch self {
        case .auto, .cinematic: return "cinematic color film still, rich vivid colors, dramatic lighting, shallow depth of field"
        case .watercolor: return "soft watercolor illustration, warm muted palette, gentle light, storybook"
        case .illustration: return "detailed digital illustration, vibrant colors, cinematic lighting, concept art"
        case .oil: return "oil painting, visible brush strokes, rich colors, impressionist"
        }
    }
}

/// One picture of the song: the lyric lines it illustrates and the prompt it was made from.
/// `firstLine` -1: a song without lyrics, scenes spread evenly over the track.
struct LiveVideoScene: Codable, Equatable {
    var firstLine: Int
    var lastLine: Int
    var prompt: String
}

struct LiveVideoBoard: Codable, Equatable {
    var key: String
    var theme: String
    /// The look the director chose (a LiveVideoStyle raw value), for the Automatic style.
    var style: String = ""
    /// Who appears in the video (same people in every picture) and the light and colors.
    var characters: String = ""
    var mood: String = ""
    var scenes: [LiveVideoScene]
}

enum LiveVideoStory {
    static let maxScenes = 14
    /// Bumped when the storyboard recipe changes, so cached boards made the old way are made again.
    static let version = 11

    /// Step 1a, the reader: who speaks to whom and the concrete world of the song, in its own words (no quotes).
    static let briefInstructions = """
        You read song lyrics (any language) and take notes for a music video director. The lyrics may talk about \
        love, heartbreak, fame, partying or loss. Never quote or translate them: use your own plain words. A \
        reference to a real person, film or song becomes its look and era, never its name ("1920s silent film \
        glamour", "a 1970s rock stage"); the song's title may be one.
        Answer with exactly these five lines, in English, without brackets:
        VOICE: who is speaking and to whom (at most 12 words)
        CHARACTERS: the people as women and men, each with age, hair and clothes that fit the song (never "a \
        figure" or "a person"; at most 18 words)
        WORLD: the concrete places, objects, eras and events mentioned or implied (at most 25 words)
        MOOD: light and colors (at most 10 words)
        THEME: the song's meaning in one sentence
        """

    /// Step 1b, the reader again: what each group of lines says, simply and literally, in its own words.
    static let partsInstructions = """
        You read song lyrics (any language) for a music video director, group by group. For each group say, in \
        your own plain English words, what those lines say: who does what, where, what happens. Name people as women \
        and men ("the young woman", "the executives"), never "a figure" or "a person". Never quote or \
        translate the lyrics; references to real people, films or songs become their look and era, never their \
        names. Write one numbered line per group (the group's number, a period, then at most 20 words) and \
        nothing else.
        """

    /// Step 2, the director: from the reader's notes only (never the lyrics), the concept, an arc through changing
    /// locations and one shot per part, written as the image prompt for the illustrator.
    static let sceneInstructions = """
        You are an acclaimed music video director, known for videos that tell a song's story with clear, cinematic \
        images. You get your assistant's notes on a song (never the lyrics). Direct the video:
        - one visual concept, and an arc: beginning, development, climax, ending;
        - locations that follow the story and change (none more than twice), and varied framing: wide, medium, \
        close-up, detail, crowd;
        - the same characters, by their looks, and the same world and mood in every shot; always say "a woman", \
        "a man", "young musicians"…, never "a figure" or "a person";
        - metaphors become visible action that keeps their meaning (a "war" between rivals is a tense standoff in \
        an office, not a battlefield);
        - only what a camera sees: no inner thoughts, no text, logos, brands or famous people's names; no old \
        people, children or animals unless the notes have them.
        Example of shot lines, for an invented song where a jukebox repairman asks a diner waitress to leave town:
        1. SHOT: wide shot of a 1950s roadside diner at night, a lanky man in grease-stained overalls kneels by a glowing chrome jukebox, neon light
        2. SHOT: close-up of a young waitress with a red ponytail and pink uniform smiling over a cup of coffee, warm neon glow
        3. SHOT: wide shot of a red convertible on an empty desert highway at dawn, the two of them inside, golden light
        - the look of the whole video, one of: cinematic (nightlife, fame, cities, drama, the present), watercolor \
        (gentle, nostalgic, countryside, childhood), oil (timeless, romantic, classical, the past), illustration \
        (playful, colorful, dreamy, fantasy).
        Answer only in this format, in English, without brackets:
        STYLE: <cinematic, watercolor, oil or illustration>
        CONCEPT: <one sentence>
        1. SHOT: <framing, location, characters by looks, what they do, light; 18-30 words>
        2. SHOT: <…>
        (one numbered SHOT line per part, nothing else)
        """

    /// Lyric lines in consecutive groups, one picture each. Synced lyrics: a new picture every ~18 s of singing,
    /// or after an instrumental break; plain lyrics: about four lines each. At most `maxScenes`.
    static func groups(times: [Double]?, count: Int) -> [ClosedRange<Int>] {
        guard count > 0 else { return [] }
        var out: [ClosedRange<Int>] = []
        if let t = times, t.count == count {
            var start = 0
            for i in 1...count {
                let ends = i == count
                let span = (ends ? t[count - 1] + 4 : t[i]) - t[start]
                let gap = ends ? 0 : t[i] - t[i - 1]
                if ends || (span >= 18 && i - start >= 2) || (gap > 8 && i - start >= 1) {
                    out.append(start...(i - 1))
                    start = i
                }
            }
        } else {
            let per = max(4, Int((Double(count) / Double(maxScenes)).rounded(.up)))
            out = stride(from: 0, to: count, by: per).map { $0...min(count - 1, $0 + per - 1) }
        }
        // Too many: merge the shortest neighbours.
        while out.count > maxScenes {
            var best = 0
            for i in 0..<(out.count - 1) where out[i].count + out[i + 1].count < out[best].count + out[best + 1].count { best = i }
            out[best] = out[best].lowerBound...out[best + 1].upperBound
            out.remove(at: best + 1)
        }
        return out
    }

    /// The parsed answer: characters, theme and, per group number, the image.
    struct Parsed: Equatable {
        var voice = ""
        var concept = ""
        var style = ""
        var characters = ""
        var setting = ""
        var mood = ""
        var theme = ""
        /// Numbered lines: the retelling of each part (step 1) or its image prompt (step 2).
        var parts: [Int: String] = [:]
    }

    /// Reads "CHARACTERS:", "SETTING:", "MOOD:", "THEME:" and numbered lines ("3. …" or "3. IMAGE: …"), tolerant of
    /// small format slips (bold markers, quotes, "Group 3:" prefixes).
    static func parse(_ text: String) -> Parsed {
        var p = Parsed()
        let tags = ["CHARACTERS:": \Parsed.characters, "SETTING:": \Parsed.setting, "WORLD:": \Parsed.setting, "VOICE:": \Parsed.voice,
                    "CONCEPT:": \Parsed.concept, "MOOD:": \Parsed.mood, "THEME:": \Parsed.theme, "STYLE:": \Parsed.style]
        for raw in text.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            if line.hasPrefix("- ") { line.removeFirst(2) }
            let upper = line.uppercased()
            if let (tag, kp) = tags.first(where: { upper.hasPrefix($0.key) }) {
                // The first one counts: the model sometimes repeats the header before each group.
                if p[keyPath: kp].isEmpty { p[keyPath: kp] = String(line.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "<>"))) }
                continue
            }
            var rest = Substring(line)
            if upper.hasPrefix("GROUP ") || upper.hasPrefix("PART ") || upper.hasPrefix("SCENE ") { rest = rest.drop { $0 != " " }.dropFirst() }
            let digits = rest.prefix { $0.isNumber }
            guard let n = Int(digits), n >= 1 else { continue }
            var body = rest.dropFirst(digits.count).drop { ".:)- ".contains($0) }
            // "1. 1. …": a doubled number.
            if body.hasPrefix("\(n).") || body.hasPrefix("\(n) ") { body = body.dropFirst("\(n)".count).drop { ".:)- ".contains($0) } }
            // "2. VOICE: …": a repeated header, not a part.
            if tags.keys.contains(where: { body.uppercased().hasPrefix($0) }) { continue }
            if let r = body.range(of: "IMAGE:", options: .caseInsensitive) ?? body.range(of: "SHOT:", options: .caseInsensitive) { body = body[r.upperBound...] }
            let value = body.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"<>")))
            if !value.isEmpty { p.parts[n] = value }
        }
        return p
    }

    /// A session allowed to rework the user's own lyrics (Apple's guardrails for content transformations: the
    /// default ones refuse a lot of ordinary pop lyrics).
    static func session(_ instructions: String) throws -> LanguageModelSession {
        guard AI.languageModelAvailable else { throw AI.Unavailable() }
        return LanguageModelSession(model: SystemLanguageModel(guardrails: .permissiveContentTransformations), instructions: instructions)
    }

    /// Low temperature: faithful to the lyrics and steady from one try to the next.
    static func ask(_ instructions: String, _ prompt: String) async throws -> String {
        try await session(instructions).respond(to: prompt, options: GenerationOptions(temperature: 0.3)).content
    }

    /// The song's storyboard, written on this Mac by Apple Intelligence in two steps: a retelling of the lyrics
    /// (characters, setting, mood, what happens in each part), then image prompts made from that retelling alone,
    /// so no lyric text reaches the pictures. Never fails for a refused passage: it gets a scene from the theme.
    static func make(key: String, title: String, artist: String, lines: [String], groups: [ClosedRange<Int>]) async throws -> LiveVideoBoard {
        let song = "Song: \"\(title)\"\(artist.isEmpty ? "" : " by \(artist)")."
        let partCount = lines.isEmpty || groups.isEmpty ? 4 : groups.count

        // 1. The reader's notes: the song as a whole, then each group.
        let debug = ProcessInfo.processInfo.environment["MUSICAMP_BOARD_DEBUG"] == "1"
        var brief = Parsed()
        if lines.isEmpty || groups.isEmpty {
            brief = parse((try? await ask(briefInstructions, "\(song) Its lyrics aren't available: imagine its video from the title.")) ?? "")
            for n in 1...partCount { brief.parts[n] = "part \(n) of the story suggested by the title" }
        } else {
            let numbered = groups.enumerated().map { g, r in "Group \(g + 1):\n" + lines[r].joined(separator: "\n") }.joined(separator: "\n\n")
            do { brief = parse(try await ask(briefInstructions, "\(song)\nThe lyrics:\n\n" + lines.joined(separator: "\n"))) } catch {
                if debug { print("reader error:", error) }
            }
            let header = [brief.voice.isEmpty ? "" : "Who speaks: \(brief.voice)", brief.characters.isEmpty ? "" : "People: \(brief.characters)",
                          brief.setting.isEmpty ? "" : "World: \(brief.setting)", brief.theme.isEmpty ? "" : "Meaning: \(brief.theme)"]
                .filter { !$0.isEmpty }.joined(separator: "\n")
            var raw = ""
            do { raw = try await ask(partsInstructions, "\(song)\n\(header)\n\nThe lyrics, in \(groups.count) groups. Write exactly \(groups.count) numbered lines.\n\n\(numbered)") } catch {
                if debug { print("parts error:", error) }
            }
            if debug { print("--- parts raw\n\(raw)\n---") }
            brief.parts = parse(raw).parts.filter { !isPlaceholder($0.value) }
            // Groups the whole-song answer missed (or refused): one at a time, with the song's notes as context.
            for (g, r) in groups.enumerated() where brief.parts[g + 1] == nil {
                let one = parse((try? await ask(partsInstructions, "\(song)\n\(header)\n\nOne group of lines; write line 1 only.\n\n" + lines[r].joined(separator: "\n"))) ?? "")
                if let part = one.parts[1], !isPlaceholder(part) { brief.parts[g + 1] = part }
            }
        }
        if brief.theme.isEmpty { brief.theme = "the feeling of the song \"\(title)\"" }
        if ProcessInfo.processInfo.environment["MUSICAMP_BOARD_DEBUG"] == "1" {
            print("--- reader notes\nVOICE: \(brief.voice)\nCHARACTERS: \(brief.characters)\nWORLD: \(brief.setting)\nMOOD: \(brief.mood)\nTHEME: \(brief.theme)")
            for n in 1...partCount { print("\(n). \(brief.parts[n] ?? "-")") }
            print("---")
        }

        // 2. Pictures, from the retelling only.
        let treatment = """
            \(song)
            Your assistant's notes:
            Voice: \(brief.voice.isEmpty ? "the singer" : brief.voice)
            Characters: \(brief.characters.isEmpty ? "the singer and the person they sing to" : brief.characters)
            World: \(brief.setting.isEmpty ? "places that fit the song" : brief.setting)
            Mood: \(brief.mood.isEmpty ? "cinematic" : brief.mood)
            Theme: \(brief.theme)
            What each part says:
            """ + "\n" + (1...partCount).map { "\($0). \(brief.parts[$0] ?? "a moment that carries the theme")" }.joined(separator: "\n")
        let direction = parse((try? await ask(sceneInstructions, treatment + "\n\nDirect it: STYLE, CONCEPT, then exactly \(partCount) numbered SHOT lines, one per part.")) ?? "")
        var scenes = direction.parts
        let chosen = LiveVideoStyle(rawValue: direction.style.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)))
        for n in 1...partCount {
            if let s = scenes[n] {
                // Stable Diffusion reads ~75 tokens: keep each scene to 32 words (style and mood come with it).
                let words = s.split(separator: " ")
                if words.count > 32 {
                    // Cut at the last comma within the limit, so the prompt ends on a whole phrase.
                    var cut = words.prefix(32).joined(separator: " ")
                    if let c = cut.range(of: ",", options: .backwards), cut.distance(from: cut.startIndex, to: c.lowerBound) > cut.count / 2 { cut = String(cut[..<c.lowerBound]) }
                    scenes[n] = cut
                }
            } else {
                scenes[n] = fallback(n - 1, theme: brief.theme, title: title)
            }
        }
        let ranges: [ClosedRange<Int>?] = lines.isEmpty || groups.isEmpty ? Array(repeating: nil, count: partCount) : groups.map { Optional($0) }
        return LiveVideoBoard(key: key, theme: brief.theme, style: (chosen == .auto ? nil : chosen)?.rawValue ?? "", characters: brief.characters, mood: brief.mood,
                              scenes: ranges.enumerated().map { i, r in
                                  LiveVideoScene(firstLine: r?.lowerBound ?? -1, lastLine: r?.upperBound ?? -1, prompt: scenes[i + 1] ?? fallback(i, theme: brief.theme, title: title))
                              })
    }

    /// The model sometimes copies the format's instructions instead of answering.
    static func isPlaceholder(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("at most") || l.contains("what these lines say") || l.contains("numbered line") || l.count < 8
    }

    /// A scene for a passage that couldn't be described: the song's mood, a different framing each time.
    static func fallback(_ i: Int, theme: String, title: String) -> String {
        let frames = ["a city at night seen from a window", "an empty road at dusk", "a quiet room with soft light through the curtains",
                      "a crowd under colored lights", "the sea at sunrise", "rain on a window with blurred lights behind"]
        return "\(frames[i % frames.count]), mood of \(theme.isEmpty ? "the song \"\(title)\"" : theme)"
    }
}

// MARK: - Image engine

/// Runs Stable Diffusion off the main thread, one image at a time. The pipeline stays loaded while Live Video
/// is in use (SDXL takes ~3 GB) and is released after a few idle minutes.
final class LiveVideoEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "musicamp.livevideo", qos: .userInitiated)
    private var pipeline: (any StableDiffusionPipelineProtocol)?
    private var loaded: LiveVideoModel?
    private var lastUse = Date()
    private var cancelled = false
    private let lock = NSLock()

    static let negative = "text, letters, words, watermark, signature, logo, blurry, deformed hands, extra fingers, ugly, low quality, photo frame, border"

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    /// The model is loaded and ready (otherwise the next image starts by loading it: ~2 minutes the first
    /// time after installing or updating MusicAmp, while Core ML prepares it for the Neural Engine).
    func isLoaded(_ m: LiveVideoModel) -> Bool { lock.lock(); defer { lock.unlock() }; return readyModel == m.id }
    /// Set once a model is loaded (read from the main thread without waiting on a running generation).
    private var readyModel: String?
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// One image; nil when cancelled.
    func image(_ prompt: String, seed: UInt32, model: LiveVideoModel) async throws -> CGImage? {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                lock.lock(); cancelled = false; lock.unlock()
                do {
                    if loaded != model || pipeline == nil {
                        pipeline = nil
                        lock.lock(); readyModel = nil; lock.unlock()
                        let cfg = MLModelConfiguration()
                        cfg.computeUnits = model.computeUnits
                        let p: any StableDiffusionPipelineProtocol = model.isXL
                            ? try StableDiffusionXLPipeline(resourcesAt: model.url, configuration: cfg, reduceMemory: false)
                            : try StableDiffusionPipeline(resourcesAt: model.url, controlNet: [], configuration: cfg, disableSafety: true, reduceMemory: false)
                        try p.loadResources()
                        pipeline = p
                        loaded = model
                        lock.lock(); readyModel = model.id; lock.unlock()
                    }
                    var c = PipelineConfiguration(prompt: prompt)
                    c.negativePrompt = Self.negative
                    c.stepCount = 20
                    c.seed = seed
                    c.guidanceScale = 7.5
                    c.schedulerType = .dpmSolverMultistepScheduler
                    if model.isXL {
                        c.encoderScaleFactor = 0.13025
                        c.decoderScaleFactor = 0.13025
                        c.originalSize = Float32(model.size)
                        c.targetSize = Float32(model.size)
                    }
                    let out = try pipeline!.generateImages(configuration: c) { [self] _ in !isCancelled }
                    lastUse = Date()
                    cont.resume(returning: isCancelled ? nil : (out.first ?? nil))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Frees the model if unused for `idle` seconds.
    func unloadIfIdle(_ idle: TimeInterval) {
        queue.async { [self] in
            guard pipeline != nil, Date().timeIntervalSince(lastUse) > idle else { return }
            pipeline?.unloadResources()
            pipeline = nil
            loaded = nil
            lock.lock(); readyModel = nil; lock.unlock()
        }
    }
}

// MARK: - Live Video

/// "Live Video": while a song plays, a sequence of pictures made on this Mac from what its lyrics are about,
/// with the lyrics underneath. Storyboard by Apple Intelligence, images by a sideloaded Stable Diffusion model,
/// both cached per song. Shown in its own window and, optionally, on a TV through Chromecast.
@MainActor
final class LiveVideo: ObservableObject {
    static let shared = LiveVideo()

    @Published private(set) var models: [LiveVideoModel] = LiveVideoModel.installed()
    @Published var modelPath = UserDefaults.standard.string(forKey: "liveVideo.model") ?? "" {
        didSet { UserDefaults.standard.set(modelPath, forKey: "liveVideo.model"); restart() }
    }
    @Published var style = LiveVideoStyle(rawValue: UserDefaults.standard.string(forKey: "liveVideo.style") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "liveVideo.style"); restart() }
    }
    /// Prepare the next track's pictures while this one plays.
    @Published var prefetch = UserDefaults.standard.object(forKey: "liveVideo.prefetch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(prefetch, forKey: "liveVideo.prefetch") }
    }
    /// Storyboard and pictures first, then the song: a track starting without its video waits at 0:00.
    @Published var waitBeforePlaying = UserDefaults.standard.object(forKey: "liveVideo.wait") as? Bool ?? true {
        didSet { UserDefaults.standard.set(waitBeforePlaying, forKey: "liveVideo.wait"); if !waitBeforePlaying { playNow() } }
    }
    /// The song is held at 0:00 while its video is made.
    @Published private(set) var holding = false
    private weak var heldTrack: Track?
    /// Tracks the user chose to play without waiting (don't hold them again).
    private var releasedTrack: ObjectIdentifier?
    private var resuming = false

    /// The TV (Chromecast with lyrics) shows Live Video instead of the plain karaoke.
    @Published var onTV = UserDefaults.standard.bool(forKey: "liveVideo.onTV") {
        didSet { UserDefaults.standard.set(onTV, forKey: "liveVideo.onTV"); refresh() }
    }

    /// The current song's storyboard and the pictures made so far (scene index → image).
    @Published private(set) var board: LiveVideoBoard?
    @Published private(set) var images: [Int: CGImage] = [:]
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var download: (id: String, progress: Double)?

    var windowOpen = false
    var active: Bool { windowOpen || (onTV && TVKaraoke.shared.active) }

    var model: LiveVideoModel? { models.first { $0.id == modelPath } ?? models.first }

    private let engine = LiveVideoEngine()
    private var job: Task<Void, Never>?
    private var jobKey = ""
    private var idleTimer: Timer?
    private var downloader: ModelDownloader?
    private var lyricsWatch: AnyCancellable?

    init() {
        // The lyrics arrive or change (found, synced from the audio): illustrate the right version.
        lyricsWatch = LyricsService.shared.$state.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    static var cacheFolder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MusicAmp/LiveVideo", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // MARK: Song

    /// What a song's pictures depend on: the model, the style, the song and its lyrics.
    static func key(model: LiveVideoModel, style: LiveVideoStyle, title: String, artist: String, lines: [String]) -> String {
        let s = ["v\(LiveVideoStory.version)", model.name, style.rawValue, artist.lowercased(), title.lowercased(), lines.joined(separator: "\n")].joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct Song {
        var title: String
        var artist: String
        var lines: [String]
        var times: [Double]?
    }

    /// The song playing now, once its lyrics are settled (nil while they're being looked up).
    private func currentSong() -> Song? {
        let c = Ctl.shared
        guard let t = c.playlist.currentTrack, !t.isStream else { return nil }
        let title = t.songTitle ?? t.title, artist = t.artist ?? ""
        switch LyricsService.shared.state {
        case .loading, .idle: return nil
        case .found(let l):
            if let s = l.synced, !s.isEmpty { return Song(title: title, artist: artist, lines: s.map(\.text), times: s.map(\.time)) }
            let plain = (l.plain ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return Song(title: title, artist: artist, lines: plain, times: nil)
        case .notFound, .error: return Song(title: title, artist: artist, lines: [], times: nil)
        }
    }

    // MARK: Running

    /// Something changed (track, lyrics, window, setting): make sure the right song is being illustrated.
    func refresh() {
        models = LiveVideoModel.installed()
        guard active else { stopJob(); release(); return }
        Ctl.shared.refreshLyrics(evenIfHidden: true)
        if case .found(let l) = LyricsService.shared.state, l.synced?.isEmpty != false { LyricsService.shared.autoSyncIfUseful() }
        guard let model else { status = L("Live Video needs an image model: Settings → Visualization → Live Video."); board = nil; images = [:]; release(); return }
        guard AI.languageModelAvailable else { status = AI.unavailableReason ?? "Apple Intelligence is off."; release(); return }
        guard let song = currentSong() else { status = L("Waiting for the lyrics…"); holdIfStarting(complete: false); return }
        let key = Self.key(model: model, style: style, title: song.title, artist: song.artist, lines: song.lines)
        holdIfStarting(complete: Self.isComplete(key))
        guard key != jobKey else { return }
        stopJob()
        jobKey = key
        board = nil
        images = [:]
        error = nil
        let style = self.style
        job = Task { [weak self] in
            await self?.illustrate(song, key: key, model: model, style: style, current: true)
            guard let self, !Task.isCancelled, self.prefetch, let next = await self.nextSong() else { return }
            let nk = Self.key(model: model, style: style, title: next.title, artist: next.artist, lines: next.lines)
            await self.illustrate(next, key: nk, model: model, style: style, current: false)
        }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.active != true { self?.engine.unloadIfIdle(180) } }
        }
    }

    private func restart() { jobKey = ""; refresh() }

    // MARK: Video first, then the song

    /// The song just started and its video isn't ready: pause at 0:00 until it is.
    private func holdIfStarting(complete: Bool) {
        let c = Ctl.shared
        guard waitBeforePlaying, !complete, !holding, let t = c.playlist.currentTrack, !t.isStream,
              releasedTrack != ObjectIdentifier(t), c.transport.state == .playing, c.transport.currentTime < 3 else { return }
        holding = true
        heldTrack = t
        c.pause()
        c.audio.seek(to: 0)
    }

    /// The video is ready (or can't be made): start the held song from the top.
    private func release() {
        guard holding else { return }
        holding = false
        let c = Ctl.shared
        guard let t = heldTrack, c.playlist.currentTrack === t else { return }
        resuming = true
        c.audio.seek(to: 0)
        c.play()
        resuming = false
    }

    /// "Play Now": the song starts, the pictures keep coming while it plays.
    func playNow() {
        if let t = heldTrack { releasedTrack = ObjectIdentifier(t) }
        release()
    }

    /// Transport changed: Play pressed while waiting means "don't wait for this one".
    func transportChanged() {
        let c0 = Ctl.shared
        // A track just started: check whether to hold it.
        if !holding, active, c0.transport.state == .playing, c0.transport.currentTime < 3 { refresh(); return }
        guard holding, !resuming else { return }
        let c = Ctl.shared
        if c.playlist.currentTrack !== heldTrack {
            holding = false   // another track: the new one decides for itself
        } else if c.transport.state == .playing {
            playNow()
        }
    }

    /// Board and every picture already in the cache.
    static func isComplete(_ key: String) -> Bool {
        let dir = cacheFolder.appendingPathComponent(key, isDirectory: true)
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("board.json")),
              let b = try? JSONDecoder().decode(LiveVideoBoard.self, from: d) else { return false }
        return b.scenes.indices.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent("scene\($0).jpg").path) }
    }

    private func stopJob() {
        job?.cancel()
        job = nil
        engine.cancel()
        jobKey = ""
    }

    /// Storyboard then pictures, in the order they'll be shown, from the cache when already made.
    private func illustrate(_ song: Song, key: String, model: LiveVideoModel, style: LiveVideoStyle, current: Bool) async {
        let dir = Self.cacheFolder.appendingPathComponent(key, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let boardFile = dir.appendingPathComponent("board.json")
        var b: LiveVideoBoard
        if let d = try? Data(contentsOf: boardFile), let cached = try? JSONDecoder().decode(LiveVideoBoard.self, from: d) {
            b = cached
        } else {
            if current { status = L("Reading the song…") }
            do {
                let groups = LiveVideoStory.groups(times: song.times, count: song.lines.count)
                b = try await LiveVideoStory.make(key: key, title: song.title, artist: song.artist, lines: song.lines, groups: groups)
                try? JSONEncoder().encode(b).write(to: boardFile)
            } catch {
                if current { self.error = error.localizedDescription; status = L("Couldn't imagine this song."); release() }
                return
            }
        }
        if Task.isCancelled { return }
        if current { board = b }
        // Same song, same pictures: the seed comes from the song's key (hashValue changes at every launch).
        let seed = UInt32(key.prefix(8), radix: 16) ?? 4242
        for (i, scene) in b.scenes.enumerated() {
            if Task.isCancelled { return }
            let file = dir.appendingPathComponent("scene\(i).jpg")
            if let img = Self.load(file) {
                if current { images[i] = img }
                continue
            }
            if current {
                status = engine.isLoaded(model) ? String(format: L("Painting %d of %d…"), i + 1, b.scenes.count)
                    : L("Preparing the image model (the first time takes a couple of minutes)…")
            }
            do {
                // Style, the scene (characters already in it), then the mood: Stable Diffusion reads ~75 words.
                // The scene first (Stable Diffusion weighs the first words most), then the look, then the mood.
                let look = style == .auto ? (LiveVideoStyle(rawValue: b.style) ?? .cinematic) : style
                let prompt = [scene.prompt, look.prompt, b.mood].filter { !$0.isEmpty }.joined(separator: ", ")
                guard let img = try await engine.image(prompt, seed: seed &+ UInt32(i), model: model) else { return }
                Self.save(img, file)
                if current, !Task.isCancelled { images[i] = img }
            } catch {
                if current { self.error = error.localizedDescription; status = L("The image model failed."); release() }
                return
            }
        }
        if current { status = ""; release() }
    }

    /// The next track in the playlist, with its lyrics from the cache or the network.
    private func nextSong() async -> Song? {
        let c = Ctl.shared
        guard let n = c.peekNext(), c.playlist.tracks.indices.contains(n.index) else { return nil }
        let t = c.playlist.tracks[n.index]
        guard !t.isStream, let q = LyricsService.query(for: t, duration: t.duration ?? 0) else { return nil }
        guard case .success(let l?) = await LyricsService.find(q, cacheDir: LyricsService.shared.cacheDir, force: false) else {
            return Song(title: q.title, artist: q.artist, lines: [], times: nil)
        }
        if let s = l.synced, !s.isEmpty { return Song(title: q.title, artist: q.artist, lines: s.map(\.text), times: s.map(\.time)) }
        let plain = (l.plain ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Song(title: q.title, artist: q.artist, lines: plain, times: nil)
    }

    static func save(_ img: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(s, 0, nil)
    }

    // MARK: Timing

    /// Where scene `i` starts, in seconds: at its first lyric line (the first scene from the top), or evenly
    /// spread when the lyrics aren't timed.
    func sceneStart(_ i: Int, lyrics: Lyrics?, duration: Double) -> Double {
        guard let b = board, b.scenes.indices.contains(i) else { return 0 }
        if i == 0 { return 0 }
        let scene = b.scenes[i]
        if scene.firstLine >= 0, let s = lyrics?.synced, s.indices.contains(scene.firstLine) { return s[scene.firstLine].time }
        let n = scene.firstLine >= 0 ? Double(max(1, (b.scenes.last?.lastLine ?? 0) + 1)) : Double(b.scenes.count)
        let pos = scene.firstLine >= 0 ? Double(scene.firstLine) : Double(i)
        return max(0, duration) * pos / n
    }

    /// The scene on screen at `t`, with its start and the next one's.
    func scene(at t: Double, lyrics: Lyrics?, duration: Double) -> (index: Int, start: Double, end: Double)? {
        guard let b = board, !b.scenes.isEmpty else { return nil }
        var idx = 0
        for i in b.scenes.indices where sceneStart(i, lyrics: lyrics, duration: duration) <= t { idx = i }
        let start = sceneStart(idx, lyrics: lyrics, duration: duration)
        let end = idx + 1 < b.scenes.count ? sceneStart(idx + 1, lyrics: lyrics, duration: duration) : max(start + 20, duration)
        return (idx, start, end)
    }

    /// The latest picture ready at or before scene `i` (a scene still being painted shows the previous one).
    func image(upTo i: Int) -> (Int, CGImage)? {
        for k in stride(from: i, through: 0, by: -1) { if let img = images[k] { return (k, img) } }
        return nil
    }

    // MARK: Models

    func chooseModel() {
        let p = NSOpenPanel()
        p.message = L("Choose a Core ML Stable Diffusion model: a folder or a .zip from Apple's Hugging Face pages.")
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowedContentTypes = [.zip, .folder]
        guard p.runModal() == .OK, let u = p.url else { return }
        Task {
            do {
                try await Self.install(u)
                models = LiveVideoModel.installed()
                if modelPath.isEmpty, let m = models.first { modelPath = m.id }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Copies a model folder, or unpacks a zip, into the Models folder.
    nonisolated static func install(_ u: URL) async throws {
        let dest = LiveVideoModel.folder
        if u.pathExtension.lowercased() == "zip" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", u.path, dest.appendingPathComponent(u.deletingPathExtension().lastPathComponent).path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        } else {
            guard LiveVideoModel.at(u) != nil else { throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "That folder isn't a Core ML Stable Diffusion model."]) }
            try FileManager.default.copyItem(at: u, to: dest.appendingPathComponent(u.lastPathComponent))
        }
    }

    func startDownload(_ d: LiveVideoModel.Download) {
        guard download == nil else { return }
        download = (d.id, 0)
        let dl = ModelDownloader(url: d.url) { [weak self] p in
            Task { @MainActor in self?.download = (d.id, p) }
        } done: { [weak self] file, err in
            Task { @MainActor in
                guard let self else { return }
                defer { self.download = nil; self.downloader = nil }
                guard let file else { self.error = err?.localizedDescription; return }
                do {
                    let named = file.deletingLastPathComponent().appendingPathComponent(d.url.lastPathComponent)
                    try? FileManager.default.removeItem(at: named)
                    try FileManager.default.moveItem(at: file, to: named)
                    try await Self.install(named)
                    try? FileManager.default.removeItem(at: named)
                    self.models = LiveVideoModel.installed()
                    if self.modelPath.isEmpty || self.model == nil, let m = self.models.first { self.modelPath = m.id }
                    self.refresh()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        downloader = dl
        dl.start()
    }

    func cancelDownload() { downloader?.cancel(); downloader = nil; download = nil }

    /// Bytes used by the picture cache.
    var cacheSize: Int64 {
        let e = FileManager.default.enumerator(at: Self.cacheFolder, includingPropertiesForKeys: [.fileSizeKey])
        var n: Int64 = 0
        while let u = e?.nextObject() as? URL { n += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return n
    }

    /// Tests: a storyboard and pictures without generating them.
    func setForTesting(board: LiveVideoBoard?, images: [Int: CGImage]) { self.board = board; self.images = images }

    /// Tests: one picture from a complete prompt.
    func paintRawForTesting(_ prompt: String, model: LiveVideoModel) async throws -> CGImage? {
        try await engine.image(prompt, seed: 4242, model: model)
    }

    /// Tests: one picture with the installed model.
    func paintForTesting(_ prompt: String, model: LiveVideoModel) async throws -> CGImage? {
        try await engine.image("\(style.prompt), \(prompt)", seed: 4242, model: model)
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: Self.cacheFolder)
        restart()
    }
}

/// Downloads a model zip with progress.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let progress: (Double) -> Void
    private let done: (URL?, Error?) -> Void
    private var session: URLSession?

    init(url: URL, progress: @escaping (Double) -> Void, done: @escaping (URL?, Error?) -> Void) {
        self.url = url; self.progress = progress; self.done = done
    }

    func start() {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: url).resume()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is deleted when this returns: keep it.
        let keep = LiveVideoModel.folder.appendingPathComponent("download-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            done(keep, nil)
        } catch {
            done(nil, error)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { done(nil, error) }
    }
}
