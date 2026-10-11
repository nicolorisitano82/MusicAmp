import AppKit
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
            _ = groups
            let b = try await LiveVideo.makeBoard(LiveVideo.Song(title: title, artist: artist, lines: lines, times: synced.map(\.time)), key: "diag", style: LiveVideo.shared.style)
            print(String(format: "%.1f s, %d scenes, %d pictures", Date().timeIntervalSince(t), b.scenes.count, b.imageCount))
            print("STYLE:", b.style); print("THEME:", b.theme); print("CHARACTERS:", b.characters); print("MOOD:", b.mood)
            for s in b.scenes { print("\(s.firstLine)-\(s.lastLine) \(s.kind) [img \(b.imageIndex(b.scenes.firstIndex(of: s) ?? 0)) v\(s.variation)]: \(s.prompt)") }
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
        let live = LiveVideo.shared
        let seed: UInt32 = 4242
        var passed = 0
        for i in 0..<b.imageCount {
            let t = Date()
            do {
                // A first refresh of Live Video (window closed) may cancel the first picture: try once more.
                var r = try await live.paint(b, image: i, seed: seed, model: model, style: live.style)
                if r == nil { r = try await live.paint(b, image: i, seed: seed, model: model, style: live.style) }
                guard let (img, check) = r else { print("scene \(i): no image"); continue }
                LiveVideo.save(img, URL(fileURLWithPath: out).appendingPathComponent("scene\(i).jpg"))
                if check?.ok != false { passed += 1 }
                let c = check.map { "check \($0.score)/\($0.max)\($0.ok ? "" : " (" + $0.reasons.joined(separator: ", ") + ")") people \($0.people) face \(String(format: "%.2f", $0.faceArea)) labels \($0.labels.prefix(4).joined(separator: ","))" } ?? ""
                print(String(format: "image %d: %.1f s ", i, Date().timeIntervalSince(t)) + c)
            } catch {
                print(String(format: "image %d: FAILED after %.1f s: ", i, Date().timeIntervalSince(t)) + "\(error)")
            }
        }
        print("pictures passing the Vision check: \(passed)/\(b.imageCount)")
        return 0
    }

    /// `--livevideo-bench <count> <out dir>`: songs played on this Mac with synced lyrics in the cache, one per
    /// artist; for each, the previous recipe (reader + director prompts) and the plan (structure + fields + code
    /// prompts + Vision check): storyboard time, pictures, Vision passes, and a grid (top: before, bottom: after).
    static func bench(count: Int, out: String) async -> Int32 {
        guard let model = LiveVideo.shared.model else { print("no model"); return 1 }
        let dir = LyricsService.shared.cacheDir
        var picked: [(title: String, artist: String, lyrics: Lyrics)] = []
        var artists = Set<String>()
        let entries = PlayStats.shared.entries.values.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        for e in entries {
            guard let title = e.title, let artist = e.artist, !artists.contains(artist.lowercased()) else { continue }
            for d in [e.duration ?? 0, 0] {
                let q = LyricsService.Query(artist: artist, title: title, album: nil, duration: d, file: nil)
                let f = dir.appendingPathComponent(LyricsService.cacheKey(q) + ".json")
                if let data = try? Data(contentsOf: f), let l = (try? JSONDecoder().decode(Cached.self, from: data))?.lyrics, (l.synced?.count ?? 0) > 10 {
                    picked.append((title, artist, l)); artists.insert(artist.lowercased()); break
                }
            }
            if picked.count >= count { break }
        }
        print("songs: " + picked.map { "\($0.title) — \($0.artist)" }.joined(separator: "; "))
        let live = LiveVideo.shared
        for (n, song) in picked.enumerated() {
            let lines = song.lyrics.synced!.map(\.text), times = song.lyrics.synced!.map(\.time)
            var rows: [[CGImage]] = []
            print("\n== \(n + 1). \(song.title) — \(song.artist)")
            for director in (ProcessInfo.processInfo.environment["MUSICAMP_BENCH_AFTER_ONLY"] == "1" ? [false] : [true, false]) {
                let t = Date()
                guard let b = try? await LiveVideo.makeBoard(LiveVideo.Song(title: song.title, artist: song.artist, lines: lines, times: times), key: "bench", style: .auto, director: director) else {
                    print("  \(director ? "before" : "after "): storyboard failed"); rows.append([]); continue
                }
                let st = Date().timeIntervalSince(t)
                var imgs: [CGImage] = []
                var pass = 0, checked = 0, retries = 0
                let t2 = Date()
                for i in 0..<b.imageCount {
                    var r = try? await live.paint(b, image: i, seed: 4242, model: model, style: .auto)
                    if r == nil { r = try? await live.paint(b, image: i, seed: 4242, model: model, style: .auto) }
                    guard let (img, check) = r ?? nil else { continue }
                    imgs.append(img)
                    if let c = check { checked += 1; if c.ok { pass += 1 } else { retries += 1 } }
                }
                print(String(format: "  %@: storyboard %.0f s, %d scenes, %d pictures in %.0f s, style %@%@", director ? "before" : "after ", st, b.scenes.count, b.imageCount,
                             Date().timeIntervalSince(t2), b.style.isEmpty ? "-" : b.style, checked > 0 ? ", Vision ok \(pass)/\(checked)" : ""))
                if !director { print("  sections: " + b.scenes.map { "\($0.kind)\($0.variation > 0 ? "↺" : "")" }.joined(separator: " ")) }
                rows.append(imgs)
            }
            grid(rows, title: "\(song.title) — \(song.artist)", to: URL(fileURLWithPath: out).appendingPathComponent(String(format: "%02d.jpg", n + 1)))
        }
        return 0
    }

    /// Two rows of thumbnails (before / after) with a title.
    static func grid(_ rows: [[CGImage]], title: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let w = 220, cols = max(1, rows.map(\.count).max() ?? 1), top = 40, label = 70
        let size = NSSize(width: label + cols * (w + 6), height: top + rows.count * (w + 6))
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.08, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
        (title as NSString).draw(at: NSPoint(x: 10, y: size.height - 30), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white])
        for (r, row) in rows.enumerated() {
            let y = Int(size.height) - top - (r + 1) * (w + 6)
            ((r == 0 ? "before" : "after") as NSString).draw(at: NSPoint(x: 8, y: y + w / 2), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
            for (c, cg) in row.enumerated() {
                NSImage(cgImage: cg, size: NSSize(width: w, height: w)).draw(in: NSRect(x: label + c * (w + 6), y: y, width: w, height: w))
            }
        }
        img.unlockFocus()
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) { try? d.write(to: url) }
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
