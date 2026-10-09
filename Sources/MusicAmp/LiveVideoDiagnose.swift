import Foundation
import FoundationModels

/// `MusicAmp --livevideo-diagnose`: runs Live Video's storyboard on the lyrics cached on this Mac and reports, per
/// song, the line and group counts, the outcome (or the exact error) and the time. Lyrics are never printed.
@MainActor
enum LiveVideoDiagnose {
    private struct Cached: Codable { var lyrics: Lyrics? }

    static func run() async -> Int32 {
        let dir = LyricsService.shared.cacheDir
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
        var ok = 0, failed = 0
        for (n, f) in files.enumerated() {
            guard let d = try? Data(contentsOf: f), let c = try? JSONDecoder().decode(Cached.self, from: d), let l = c.lyrics else { continue }
            let synced = l.synced ?? []
            let lines = synced.isEmpty ? (l.plain ?? "").components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : synced.map(\.text)
            guard !lines.isEmpty else { continue }
            let groups = LiveVideoStory.groups(times: synced.isEmpty ? nil : synced.map(\.time), count: lines.count)
            let lang = AI.language(of: lines.joined(separator: "\n"))?.language.languageCode?.identifier ?? "?"
            let t = Date()
            do {
                let b = try await LiveVideoStory.make(key: "diag", title: "Song \(n)", artist: "", lines: lines, groups: groups)
                ok += 1
                let words = b.scenes.map { $0.prompt.split(separator: " ").count }
                let fallbacks = b.scenes.filter { $0.prompt.contains(", mood of ") }.count
                print(String(format: "song %2d  %@  %3d lines  %2d groups  OK    %2d scenes (%d fallback)  %5.1f s  words %d–%d  characters: %@", n, lang, lines.count, groups.count, b.scenes.count, fallbacks, Date().timeIntervalSince(t), words.min() ?? 0, words.max() ?? 0, b.characters.isEmpty ? "-" : "yes"))
            } catch {
                failed += 1
                print(String(format: "song %2d  %@  %3d lines  %2d groups  FAIL  %5.1f s  %@", n, lang, lines.count, groups.count, Date().timeIntervalSince(t), describe(error)))
            }
        }
        print("ok \(ok), failed \(failed)")
        return 0
    }

    /// `--livevideo-board <lyrics cache file> <title> <artist>`: the storyboard for one song (prompts only, no lyrics).
    static func board(file: String, title: String, artist: String) async -> Int32 {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: file)), let l = (try? JSONDecoder().decode(Cached.self, from: d))?.lyrics else { print("can't read"); return 1 }
        let synced = l.synced ?? []
        let lines = synced.map(\.text)
        let groups = LiveVideoStory.groups(times: synced.map(\.time), count: lines.count)
        let t = Date()
        do {
            let b = try await LiveVideoStory.make(key: "diag", title: title, artist: artist, lines: lines, groups: groups)
            print(String(format: "%.1f s", Date().timeIntervalSince(t)))
            print("STYLE:", b.style); print("THEME:", b.theme); print("CHARACTERS:", b.characters); print("MOOD:", b.mood)
            for s in b.scenes { print("\(s.firstLine)-\(s.lastLine): \(s.prompt)") }
            if let out = ProcessInfo.processInfo.environment["MUSICAMP_BOARD_OUT"] { try? JSONEncoder().encode(b).write(to: URL(fileURLWithPath: out)) }
        } catch {
            print("FAIL", describe(error))
        }
        return 0
    }

    /// `--livevideo-paint <board.json> <out dir>`: every scene of a storyboard with the installed model and style.
    static func paint(board file: String, out: String) async -> Int32 {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: file)), let b = try? JSONDecoder().decode(LiveVideoBoard.self, from: d),
              let model = LiveVideo.shared.model else { print("no board or no model"); return 1 }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        for (i, s) in b.scenes.enumerated() {
            let st = LiveVideo.shared.style
            let look = st == .auto ? (LiveVideoStyle(rawValue: b.style) ?? .cinematic) : st
            let prompt = [s.prompt, look.prompt, b.mood].filter { !$0.isEmpty }.joined(separator: ", ")
            let t = Date()
            do {
                // A first refresh of Live Video (window closed) may cancel the first picture: try once more.
                var painted = try await LiveVideo.shared.paintRawForTesting(prompt, model: model)
                if painted == nil { painted = try await LiveVideo.shared.paintRawForTesting(prompt, model: model) }
                if let img = painted {
                    LiveVideo.save(img, URL(fileURLWithPath: out).appendingPathComponent("scene\(i).jpg"))
                    print(String(format: "scene %d: %.1f s", i, Date().timeIntervalSince(t)))
                } else {
                    print("scene \(i): no image (cancelled)")
                }
            } catch {
                print(String(format: "scene %d: FAILED after %.1f s: ", i, Date().timeIntervalSince(t)) + "\(error)")
            }
        }
        return 0
    }

    static func describe(_ e: Error) -> String {
        if let g = e as? LanguageModelSession.GenerationError {
            switch g {
            case .exceededContextWindowSize: return "context window exceeded"
            case .guardrailViolation: return "guardrail violation"
            case .unsupportedLanguageOrLocale: return "unsupported language"
            case .decodingFailure: return "decoding failure"
            case .refusal: return "refusal"
            case .rateLimited: return "rate limited"
            case .concurrentRequests: return "concurrent requests"
            case .assetsUnavailable: return "assets unavailable"
            case .unsupportedGuide: return "unsupported guide"
            @unknown default: return "\(g)"
            }
        }
        return "\(type(of: e)): \(e.localizedDescription)"
    }
}
