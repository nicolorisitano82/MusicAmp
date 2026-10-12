import CryptoKit
import Foundation
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import NaturalLanguage
import Tokenizers

// MARK: - Story model

/// Who reads the lyrics and plans Live Video's storyboard. Apple Intelligence's on-device model is small and often
/// misreads who sings to whom and what a metaphor means; Qwen 2.5 (Alibaba, Apache 2.0) runs on this Mac with
/// Apple's MLX, sideloaded like the image models. On five test songs the reader got 43% of the key facts with
/// the 7B model as the app asked Apple's, 57% with the guided instructions below, 71% with the 14B.
enum StoryModel: String, CaseIterable, Identifiable, Sendable {
    /// `auto`: the best one installed for this Mac's memory, else Apple Intelligence.
    case auto, apple, qwen14, qwen7
    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .apple: return "Apple Intelligence"
        case .qwen14: return "Qwen 2.5 14B (on this Mac, best)"
        case .qwen7: return "Qwen 2.5 7B (on this Mac)"
        }
    }
    /// Short name for the storyboard export.
    var shortName: String {
        switch self {
        case .auto, .apple: return "Apple Intelligence"
        case .qwen14: return "Qwen 2.5 14B"
        case .qwen7: return "Qwen 2.5 7B"
        }
    }
    var isLocal: Bool { self == .qwen14 || self == .qwen7 }

    /// MLX's 4-bit conversion on Hugging Face.
    var repo: String { self == .qwen14 ? "mlx-community/Qwen2.5-14B-Instruct-4bit" : "mlx-community/Qwen2.5-7B-Instruct-4bit" }
    var bytes: Int64 { self == .qwen14 ? 8_321_093_500 : 4_280_000_000 }
    /// The 14B holds ~9 GB while it reads: Macs with 32 GB (it's freed before the pictures are painted).
    var fitsThisMac: Bool { self != .qwen14 || LiveVideoModel.bigMemory }

    static var folder: URL { LiveVideoModel.folder.appendingPathComponent("llm", isDirectory: true) }
    var url: URL { Self.folder.appendingPathComponent(repo.components(separatedBy: "/").last!, isDirectory: true) }

    /// A complete download: the config, the tokenizer and every weight file the index names.
    var installed: Bool {
        guard isLocal, LocalStoryModel.shadersInstalled else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.appendingPathComponent("config.json").path),
              fm.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path) else { return false }
        if let d = try? Data(contentsOf: url.appendingPathComponent("model.safetensors.index.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let map = j["weight_map"] as? [String: String] {
            return Set(map.values).allSatisfy { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        }
        return fm.fileExists(atPath: url.appendingPathComponent("model.safetensors").path)
    }

    static var chosen: StoryModel { StoryModel(rawValue: UserDefaults.standard.string(forKey: "liveVideo.storyModel") ?? "") ?? .auto }

    /// The model that will actually be used: the chosen one when it's installed, else the best installed Qwen that
    /// fits this Mac, else Apple Intelligence. MUSICAMP_LV_READER=apple|qwen7|qwen14 overrides it (benchmarks).
    static var resolved: StoryModel {
        if let env = ProcessInfo.processInfo.environment["MUSICAMP_LV_READER"], let m = StoryModel(rawValue: env), m != .auto {
            return m.isLocal && !m.installed ? .apple : m
        }
        switch chosen {
        case .apple: return .apple
        case .qwen14, .qwen7: return chosen.installed ? chosen : .apple
        case .auto: return [.qwen14, .qwen7].first { $0.installed && $0.fitsThisMac } ?? .apple
        }
    }

    /// The model writing the storyboard in progress (set for the whole board, so every step uses the same one).
    @TaskLocal static var using: StoryModel?
    static var current: StoryModel { using ?? resolved }
}

// MARK: - Running Qwen (MLX)

/// Qwen loaded with MLX, one model at a time. It's freed when a storyboard is done: the image model needs the
/// memory next.
actor LocalStoryModel {
    static let shared = LocalStoryModel()

    /// MLX's GPU shaders, precompiled: mlx-metal's wheel on PyPI for the MLX version mlx-swift 0.32.3 is built on
    /// (0.32.2). The app is built without compiling them (Scripts/mlx-precompiled-shaders.sh).
    static let shadersWheel = URL(string: "https://files.pythonhosted.org/packages/dd/cd/4e50bf325100e7165e13d025f264362bf0009196269f9eaf87f2c6e738a2/mlx_metal-0.32.2-py3-none-macosx_26_0_arm64.whl")!
    static let shadersWheelSHA256 = "e6abeac9ac5265830c9c1541b6f96e9be37a85c2446763a46ad466c63a3837ab"
    static let shadersBytes: Int64 = 64_367_860
    static let shadersSize = 182_351_120
    static var shadersURL: URL { StoryModel.folder.appendingPathComponent("mlx-0.32.2.metallib") }
    static var shadersInstalled: Bool {
        ((try? FileManager.default.attributesOfItem(atPath: shadersURL.path))?[.size] as? Int) == shadersSize
    }

    private var container: ModelContainer?
    private var loaded: StoryModel?

    private func load(_ m: StoryModel) async throws -> ModelContainer {
        if let container, loaded == m { return container }
        unload()
        guard m.installed else { throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "\(m.shortName) isn't installed."]) }
        GPU.metallib = Self.shadersURL
        let c = try await LLMModelFactory.shared.loadContainer(from: m.url, using: #huggingFaceTokenizerLoader())
        container = c
        loaded = m
        return c
    }

    /// One answer, at the same low temperature as Apple's model.
    func ask(_ m: StoryModel, instructions: String, prompt: String) async throws -> String {
        let c = try await load(m)
        let session = ChatSession(c, instructions: instructions, generateParameters: GenerateParameters(maxTokens: 1200, temperature: 0.3))
        return try await session.respond(to: prompt)
    }

    func unload() {
        guard container != nil else { return }
        container = nil
        loaded = nil
        Memory.clearCache()
    }
}

// MARK: - Downloads

/// Downloads Qwen's files from Hugging Face and MLX's shaders from PyPI into Models/llm, with progress over the
/// total. Files go into "<name>.partial" and the folder is renamed when everything is there.
enum StoryModelDownload {
    struct Failure: LocalizedError { var errorDescription: String? }

    static func run(_ m: StoryModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: StoryModel.folder, withIntermediateDirectories: true)
        // The file list (Hugging Face API).
        let api = URL(string: "https://huggingface.co/api/models/\(m.repo)/tree/main")!
        let (listData, _) = try await URLSession.shared.data(from: api)
        guard let list = try JSONSerialization.jsonObject(with: listData) as? [[String: Any]] else { throw Failure(errorDescription: "Unexpected answer from Hugging Face.") }
        let files = list.compactMap { f -> (String, Int64)? in
            guard (f["type"] as? String) == "file", let p = f["path"] as? String, !p.hasPrefix("."), p != "README.md" else { return nil }
            return (p, (f["size"] as? NSNumber)?.int64Value ?? 0)
        }
        let needShaders = !LocalStoryModel.shadersInstalled
        let total = Double(files.reduce(0) { $0 + $1.1 } + (needShaders ? LocalStoryModel.shadersBytes : 0))
        var done: Int64 = 0

        if needShaders {
            let wheel = try await fetch(LocalStoryModel.shadersWheel, to: StoryModel.folder.appendingPathComponent("mlx-metal.whl.partial")) { n in
                progress(Double(n) / total)
            }
            defer { try? fm.removeItem(at: wheel) }
            let digest = SHA256.hash(data: try Data(contentsOf: wheel, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
            guard digest == LocalStoryModel.shadersWheelSHA256 else { throw Failure(errorDescription: "MLX's shaders didn't match the expected file.") }
            let out = fm.temporaryDirectory.appendingPathComponent("mlx-metal-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: out) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", wheel.path, out.path]
            try p.run()
            p.waitUntilExit()
            let lib = out.appendingPathComponent("mlx/lib/mlx.metallib")
            guard p.terminationStatus == 0, fm.fileExists(atPath: lib.path) else { throw Failure(errorDescription: "MLX's shaders couldn't be unpacked.") }
            try? fm.removeItem(at: LocalStoryModel.shadersURL)
            try fm.moveItem(at: lib, to: LocalStoryModel.shadersURL)
            done += LocalStoryModel.shadersBytes
        }

        // A folder already there (copied by hand, or a model whose shaders were missing) is completed in place.
        let inPlace = fm.fileExists(atPath: m.url.appendingPathComponent("config.json").path)
        let partial = inPlace ? m.url : m.url.appendingPathExtension("partial")
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        for (path, size) in files {
            let dest = partial.appendingPathComponent(path)
            if ((try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64) == size, size > 0 { done += size; continue }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = done
            let file = try await fetch(URL(string: "https://huggingface.co/\(m.repo)/resolve/main/\(path)")!, to: dest.appendingPathExtension("partial")) { n in
                progress(Double(base + n) / total)
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: file, to: dest)
            done += size
        }
        if !inPlace {
            try? fm.removeItem(at: m.url)
            try fm.moveItem(at: partial, to: m.url)
        }
        progress(1)
    }

    /// One file, with the bytes received so far reported every half second.
    private static func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp, let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    cont.resume(throwing: Failure(errorDescription: "Download failed: \(url.lastPathComponent)")); return
                }
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: tmp, to: dest)
                    cont.resume(returning: dest)
                } catch { cont.resume(throwing: error) }
            }
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak task] in
                guard let task else { timer.cancel(); return }
                if task.state == .completed { timer.cancel() } else { progress(task.countOfBytesReceived) }
            }
            timer.resume()
            box.task = task
            task.resume()
            }
        } onCancel: { box.task?.cancel() }
    }

    private final class TaskBox: @unchecked Sendable { var task: URLSessionDownloadTask? }
}

// MARK: - Checking the reader's notes

/// Code checks on what the reader wrote: no real person's name (it becomes a look and an era) and no run of the
/// lyrics' own words (they'd end up painted, and they're the songwriter's text).
enum ReaderCheck {
    /// Names of people in `text`: the artist's, and any NaturalLanguage tags as a personal name; the song's title
    /// is allowed ("Clara Bow").
    static func names(in text: String, artist: String, title: String) -> [String] {
        var out: [String] = []
        let t = title.lowercased()
        let artists = artist.components(separatedBy: CharacterSet(charactersIn: ",&")).flatMap { $0.components(separatedBy: " feat") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 2 }
        for a in artists {
            for part in [a] + a.split(separator: " ").map(String.init) where part.count > 2 {
                if text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: part) + "\\b", options: [.regularExpression, .caseInsensitive]) != nil,
                   !t.contains(part.lowercased()), !out.contains(part) { out.append(part) }
            }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, r in
            let n = String(text[r])
            if tag == .personalName, !t.contains(n.lowercased()), !out.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { out.append(n) }
            return true
        }
        return out
    }

    private static let common: Set<String> = ["i", "you", "me", "my", "the", "a", "an", "and", "to", "of", "it", "in", "on", "is", "s", "t", "m",
                                              "we", "he", "she", "they", "that", "this", "be", "do", "don", "know", "oh", "yeah", "hey", "la", "na"]

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    /// Runs of four words that are also in the lyrics (leaving out the title and runs of only common words).
    static func copied(in text: String, lyrics: [String], title: String) -> [String] {
        func grams(_ w: [String]) -> [[String]] { w.count < 4 ? [] : (0...(w.count - 4)).map { Array(w[$0..<$0 + 4]) } }
        let lyr = Set(lyrics.flatMap { grams(words($0)).map { $0.joined(separator: " ") } })
        let t = words(title).joined(separator: " ")
        var out: [String] = []
        for g in grams(words(text)) {
            let s = g.joined(separator: " ")
            if lyr.contains(s), !g.allSatisfy(common.contains), !(t.count > 3 && (s.contains(t) || t.contains(s))), !out.contains(s) { out.append(s) }
        }
        return out
    }

    static let fixInstructions = """
        You edit notes written for a music video director. Rewrite the text you get keeping exactly the same \
        lines, labels and numbering, and change only what you are asked to: a real person's name becomes their \
        look and era ("a 1970s rock singer with a shawl"), a phrase taken from the lyrics becomes what it means, \
        in plain words. Answer with the rewritten text only.
        """

    /// What to ask the reader to change, or nil when the text is fine.
    static func request(_ text: String, lyrics: [String], artist: String, title: String) -> String? {
        let n = names(in: text, artist: artist, title: title)
        let c = copied(in: text, lyrics: lyrics, title: title)
        guard !n.isEmpty || !c.isEmpty else { return nil }
        var ask: [String] = []
        if !n.isEmpty { ask.append("Remove these names: " + n.joined(separator: ", ") + ".") }
        if !c.isEmpty { ask.append("Replace these phrases from the lyrics: " + c.prefix(12).map { "\"\($0)\"" }.joined(separator: ", ") + ".") }
        return ask.joined(separator: "\n") + "\n\nThe text:\n" + text
    }

    /// Names still there after the rewrite are taken out.
    static func strip(_ text: String, artist: String, title: String) -> String {
        var s = text
        for n in names(in: text, artist: artist, title: title).sorted(by: { $0.count > $1.count }) {
            s = s.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: n) + "('s)?\\b", with: "", options: [.regularExpression, .caseInsensitive])
        }
        return s.replacingOccurrences(of: "[ ]{2,}", with: " ", options: .regularExpression).replacingOccurrences(of: " ,", with: ",")
    }

    /// The reader's answer checked: rewritten once when it has names or lyric phrases, then names stripped.
    static func checked(_ text: String, lyrics: [String], artist: String, title: String) async -> String {
        var s = text
        if let ask = request(s, lyrics: lyrics, artist: artist, title: title),
           let fixed = try? await LiveVideoStory.ask(fixInstructions, ask), !fixed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s = fixed
        }
        return strip(s, artist: artist, title: title)
    }
}
