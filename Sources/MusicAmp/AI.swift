import AVFoundation
import CoreMedia
import FoundationModels
import NaturalLanguage
import Speech

/// On-device AI shared by the features that use it — nothing leaves the Mac:
/// - Apple's language model (Foundation Models, Apple Intelligence) with guided generation into Swift types:
///   tag clean-up, playlists described in words, podcast summaries, chapters and ads;
/// - speech transcription with word timings (SpeechAnalyzer): podcast transcripts and lyrics synced from the audio.
enum AI {
    // MARK: Availability

    static var languageModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why the language model can't be used, in words for the UI (nil when it can).
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in System Settings to use this."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready (downloading its model). Try again later."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { AI.unavailableReason ?? "Apple Intelligence isn't available." }
    }

    /// A fresh session per task (the context window is small: never let one grow across files or chunks).
    static func session(_ instructions: String) throws -> LanguageModelSession {
        guard languageModelAvailable else { throw Unavailable() }
        return LanguageModelSession(instructions: instructions)
    }

    // MARK: Transcription

    struct Word: Codable, Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    enum TranscriptionError: LocalizedError {
        case language(String), unreadable
        var errorDescription: String? {
            switch self {
            case .language(let l): return "Speech recognition doesn't support \(l) on this Mac."
            case .unreadable: return "This file can't be read for transcription."
            }
        }
    }

    /// Words with their times, from an audio file, on this Mac. Downloads the language's speech model the first
    /// time (system-managed). `progress` reports 0…1 of the file.
    static func transcribe(_ url: URL, locale: Locale, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Word] {
        guard let loc = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.language(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: loc, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let file = try? AVAudioFile(forReading: url) else { throw TranscriptionError.unreadable }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [Word] in
            var out: [Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let r = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let start = r.start.seconds, end = (r.start + r.duration).seconds
                    out.append(Word(start: start, end: end, text: text))
                    if duration > 0 { progress?(min(1, end / duration)) }
                }
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let words = try await collector.value
        progress?(1)
        return words.sorted { $0.start < $1.start }
    }

    /// The language of a text (lyrics, a podcast's description), for the transcriber.
    static func language(of text: String) -> Locale? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let lang = r.dominantLanguage, lang != .undetermined else { return nil }
        return Locale(identifier: lang.rawValue)
    }

    // MARK: Lyrics alignment

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// 0…1 similarity of two words (Levenshtein).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return x == y ? 1 : 0 }
        var prev = Array(0...y.count), cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Plain lyrics (one line per row) timed from a transcription: words are aligned with a global alignment
    /// (Needleman–Wunsch, fuzzy word match), unmatched words are spread between matched neighbours, and each line
    /// starts at its first word. Lines whose words were all missed get times between their neighbours.
    static func align(lyrics plain: String, to words: [Word]) -> [Lyrics.Line] {
        let lines = plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lyricWords: [(line: Int, text: String, key: String)] = lines.enumerated().flatMap { li, l in
            l.split(separator: " ").map { (li, String($0), fold(String($0))) }
        }.filter { !$0.key.isEmpty }
        let heard = words.map { fold($0.text) }
        let n = lyricWords.count, m = heard.count
        guard n > 0, m > 0 else { return [] }
        // Scores: match +2 (fuzzy), mismatch −1, gap −1.
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { score[i][0] = -Double(i) }
        for j in 0...m { score[0][j] = 0 }   // the transcript may start with noise: free leading gaps
        for i in 1...n {
            for j in 1...m {
                let s = similarity(lyricWords[i - 1].key, heard[j - 1])
                let diag = score[i - 1][j - 1] + (s >= 0.6 ? 2 * s : -1)
                score[i][j] = max(diag, score[i - 1][j] - 1, score[i][j - 1] - 0.5)
            }
        }
        var timeOf = [Double?](repeating: nil, count: n)
        var i = n, j = (0...m).max { score[n][$0] < score[n][$1] } ?? m   // free trailing gaps too
        while i > 0, j > 0 {
            let s = similarity(lyricWords[i - 1].key, heard[j - 1])
            if score[i][j] == score[i - 1][j - 1] + (s >= 0.6 ? 2 * s : -1) {
                if s >= 0.6 { timeOf[i - 1] = words[j - 1].start }
                i -= 1; j -= 1
            } else if score[i][j] == score[i - 1][j] - 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        // Fill the gaps by interpolation between known times (or the transcript's ends).
        let first = words.first?.start ?? 0, last = words.last?.end ?? first
        var k = 0
        while k < n {
            if timeOf[k] != nil { k += 1; continue }
            var e = k
            while e < n, timeOf[e] == nil { e += 1 }
            let a = k > 0 ? timeOf[k - 1]! : first, b = e < n ? timeOf[e]! : last
            for x in k..<e { timeOf[x] = a + (b - a) * Double(x - k + 1) / Double(e - k + 1) }
            k = e
        }
        var out: [Lyrics.Line] = []
        for (li, text) in lines.enumerated() {
            let ws = lyricWords.indices.filter { lyricWords[$0].line == li }
            guard let firstWord = ws.first, let t = timeOf[firstWord] else { continue }
            let timed = ws.map { Lyrics.Word(time: timeOf[$0] ?? t, text: lyricWords[$0].text + " ") }
            out.append(Lyrics.Line(time: t, text: text, words: timed))
        }
        // Times must not go backwards.
        for x in 1..<max(1, out.count) where out[x].time < out[x - 1].time { out[x].time = out[x - 1].time }
        return out
    }

    /// No lyrics at all: the transcript itself, split into lines at pauses (≥ 0.7 s) or every ~8 words.
    static func lines(from words: [Word]) -> [Lyrics.Line] {
        var out: [Lyrics.Line] = []
        var cur: [Word] = []
        func flush() {
            guard let f = cur.first else { return }
            out.append(Lyrics.Line(time: f.start, text: cur.map(\.text).joined(separator: " "),
                                   words: cur.map { Lyrics.Word(time: $0.start, text: $0.text + " ") }))
            cur = []
        }
        for w in words {
            if let p = cur.last, w.start - p.end >= 0.7 || cur.count >= 8 { flush() }
            cur.append(w)
        }
        flush()
        return out
    }
}

// MARK: - Guided generation types

@Generable
struct AITagGuess {
    @Guide(description: "The performing artist, properly capitalised, without 'feat.' guests unless they are in the name. Empty if unknown.")
    var artist: String
    @Guide(description: "The song title, properly capitalised, without track numbers, artist name, file extension or junk like 'copy', '(1)', 'official video', '320kbps'.")
    var title: String
    @Guide(description: "The album name if it can be told from the folder or the existing tags, else empty.")
    var album: String
}

@Generable
enum AIRuleField: String {
    case title, artist, album, genre, year, lengthMinutes, rating, plays, bpm, key, mood, style, lastPlayedDaysAgo, addedDaysAgo
}

@Generable
enum AIRuleOp: String {
    case contains, notContains, equals, notEquals, greaterThan, lessThan, withinLastDays, notWithinLastDays, mixesWellWith
}

@Generable
struct AIRule {
    var field: AIRuleField
    var op: AIRuleOp
    @Guide(description: "Text value for text fields (genre, artist, mood, style, key like 'Am'), empty otherwise")
    var text: String
    @Guide(description: "Number for numeric fields (year, BPM, minutes, stars 0-5, plays, days), 0 otherwise")
    var number: Double
}

@Generable
enum AIOrder: String {
    case random, mostPlayed, leastPlayed, highestRated, recentlyPlayed, recentlyAdded, year, bpm, artist, album, title
}

@Generable
struct AIPlaylistSpec {
    @Guide(description: "A short, catchy playlist name in the user's language")
    var name: String
    @Guide(description: "true if every rule must match, false if any rule is enough")
    var matchAll: Bool
    @Guide(description: "1 to 5 rules", .count(1...5))
    var rules: [AIRule]
    @Guide(description: "Maximum number of tracks, 0 for no limit")
    var limit: Int
    var order: AIOrder
}

@Generable
struct AIChunkInsight {
    @Guide(description: "A chapter title of 2 to 7 words for this part of the episode, in the episode's language")
    var chapterTitle: String
    @Guide(description: "One or two sentences summarising this part, in the episode's language")
    var summary: String
    @Guide(description: "Numbers of the sentences that are advertisements, sponsor reads or promotions (empty if none)")
    var adSentences: [Int]
}

@Generable
struct AIEpisodeSummary {
    @Guide(description: "A summary of the whole episode in 3 to 5 sentences, in the episode's language")
    var summary: String
    @Guide(description: "3 to 6 short key points", .count(3...6))
    var keyPoints: [String]
}
