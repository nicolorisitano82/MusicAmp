import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `MusicAmp --test-livevideo [frame.png]`: Live Video's grouping of lyric lines into scenes, cache keys, scene
/// timing, the frame drawn over a picture, and the installed models. With MUSICAMP_TEST_SD=1 it also writes a
/// storyboard with Apple Intelligence and paints one picture with the installed model (slow: ~20 s with SDXL).
@MainActor
enum LiveVideoTest {
    private static var fails = 0

    private static func check(_ ok: Bool, _ what: String) {
        print(ok ? "OK  " : "FAIL", what)
        if !ok { fails += 1 }
    }

    /// An original test text (not a real song).
    static let lines = [
        "Ho lasciato la città quando il sole era basso", "una valigia leggera e il rumore del mare in tasca",
        "sul treno della notte contavo le stazioni", "ogni luce nel buio sembrava una promessa",
        "e al mattino il paese era bianco di sale", "mia nonna alla finestra con il pane sul tavolo",
        "ho capito che casa non è un posto ma un ritorno", "e ballavamo in piazza fino a tardi sotto le lanterne",
    ]

    private static func picture(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        return ctx.makeImage()
    }

    static func run() async -> Int32 {
        // Grouping: synced lines every 4 s → a scene every ~18 s; a long break starts a new one.
        let times = (0..<20).map { Double($0) * 4 + 10 }
        let g = LiveVideoStory.groups(times: times, count: 20)
        check(g.first?.lowerBound == 0 && g.last?.upperBound == 19 && zip(g, g.dropFirst()).allSatisfy { $0.upperBound + 1 == $1.lowerBound },
              "groups cover every line once, in order: \(g.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " "))")
        check(g.dropLast().allSatisfy { times[$0.upperBound] + 4 - times[$0.lowerBound] >= 18 }, "a picture every ~18 s of singing")
        var broken = times
        for i in 3..<20 { broken[i] += 30 }   // 30 s instrumental after line 2
        check(LiveVideoStory.groups(times: broken, count: 20).first?.upperBound == 2, "an instrumental break starts a new picture")
        let long = LiveVideoStory.groups(times: (0..<200).map { Double($0) * 3 }, count: 200)
        check(long.count <= LiveVideoStory.maxScenes && long.last?.upperBound == 199, "a long song: at most \(LiveVideoStory.maxScenes) pictures (\(long.count))")
        let plain = LiveVideoStory.groups(times: nil, count: 10)
        check(plain.map(\.count) == [4, 4, 2], "plain lyrics: about four lines per picture")
        check(LiveVideoStory.groups(times: nil, count: 0).isEmpty, "no lyrics: no line groups")

        // Song structure (original test text): verse, chorus, verse, chorus, bridge, chorus.
        let chorus = ["we are the lights of the harbour", "burning bright until the morning", "nobody can turn us off tonight"]
        let song = ["walking home along the river", "the city sleeping in the rain", "my old coat and your umbrella", ""] + chorus + [""] +
            ["the bus is late again tonight", "we share the last cigarette", "you laugh at every stupid joke", ""] + chorus + [""] +
            ["and when the summer ends", "we will still remember this", ""] + chorus
        let secs = LiveVideoPlan.sections(lines: song, times: nil)
        check(secs.map(\.kind) == [.verse, .chorus, .verse, .chorus, .bridge, .chorus], "structure: verse, chorus, verse, chorus, bridge, chorus (\(secs.map(\.kind.rawValue).joined(separator: ", ")))")
        check(Set(secs.filter { $0.kind == .chorus }.map(\.part)).count == 1 && Set(secs.map(\.part)).count == 4, "the chorus is one picture: 4 distinct parts for 6 sections")
        var gapped = (0..<12).map { Double($0) * 3 }
        for k in 6..<12 { gapped[k] += 10 }
        check(LiveVideoPlan.stanzas(lines: (0..<12).map { "line \($0)" }, times: gapped).map(\.count) == [6, 6], "stanzas split at a 10 s pause")

        // Treatment and shot list parsing (format slips included).
        let treatment = LiveVideoPlan.parseTreatment("""
            VOICE: a girl to her best friend
            A: the narrator | a young woman, short black hair, yellow raincoat
            B: her friend | a young man with curly hair and a denim jacket
            PLACES: a rainy riverside path at night; a bus stop; a small kitchen
            STYLE: Watercolor
            MOOD: blue rain, warm street lamps
            THEME: friendship that outlasts the summer
            1. They walk home by the river in the rain.
            Part 2: They sing on the bus stop bench.
            """)
        check(treatment.characters.count == 2 && treatment.places.count == 3 && treatment.style == "watercolor" && treatment.parts[1] != nil && treatment.parts[2] != nil,
              "treatment: two characters, three places, style, numbered parts")
        let shots = LiveVideoPlan.parseShots("""
            1. WHO: A+B | ACTION: walk under one umbrella | PLACE: 1 | FRAMING: wide | LIGHT: street lamps in rain
            2. **WHO:** crowd | ACTION: sing together | PLACE: 2 | FRAMING: Close up | LIGHT: neon
            """, places: treatment.places)
        check(shots[1]?.place == "a rainy riverside path at night" && shots[1]?.who == "A+B" && shots[2]?.framing == "close-up", "shot list: fields, place by number, framing normalised")
        if let s1 = shots[1] {
            let p = LiveVideoPlan.prompt(s1, characters: treatment.characters, style: .watercolor, mood: treatment.mood)
            check(p.hasPrefix("a young woman in yellow raincoat and a young man in a denim jacket walk under one umbrella in a rainy riverside path") && p.split(separator: " ").count <= 62,
                  "prompt by code: the event first (people by their clothes, action, place), within ~60 words: \(p)")
            check(LiveVideoPlan.negative("wide").contains("portrait") && !LiveVideoPlan.negative("close-up").contains("posing") && LiveVideoPlan.negative("wide").contains("nude"),
                  "negative prompt fits the framing and always excludes nudity")
        }
        check(LiveVideoPlan.isPose("stands by the window") && LiveVideoPlan.isPose("she gazes at the city") && !LiveVideoPlan.isPose("runs for the last night train"),
              "poses are told apart from actions")
        do {
        }
        check(LiveVideoPlan.youthful("a woman in her sixties with silver hair, bold red coat") == "a woman in her twenties with dark hair, bold red coat",
              "cast kept young unless the song is about age: \(LiveVideoPlan.youthful("a woman in her sixties with silver hair, bold red coat"))")
        let juno = (0..<40).map { "line \($0 % 20 < 4 ? $0 % 4 : $0)" }
        check(Set(LiveVideoPlan.sections(lines: juno, times: nil).map(\.part)).count <= LiveVideoPlan.maxPictures, "at most \(LiveVideoPlan.maxPictures) pictures per song")
        check(LiveVideoCheck.vocabulary.count > 500, "Vision knows \(LiveVideoCheck.vocabulary.count) scene/object labels")
        print("     place words Vision can check in 'a crowded concert stage, a train station': " + (LiveVideoCheck.placeWords("a crowded concert stage") + LiveVideoCheck.placeWords("a train station")).joined(separator: ", "))

        // Cache key: same song and settings → same pictures; another style → others.
        let m = LiveVideoModel(url: URL(fileURLWithPath: "/m/coreml-stable-diffusion-xl-base-ios_split_einsum_compiled"), isXL: true)
        let k1 = LiveVideo.key(model: m, style: .watercolor, title: "T", artist: "A", lines: lines)
        check(k1 == LiveVideo.key(model: m, style: .watercolor, title: "t", artist: "a", lines: lines) && k1 != LiveVideo.key(model: m, style: .oil, title: "T", artist: "A", lines: lines),
              "cache key: stable for the song, changes with the style")
        check(m.computeUnits == .cpuAndNeuralEngine && m.size == 768 && m.label.hasPrefix("SDXL"), "SDXL split_einsum model runs on the Neural Engine at 768 px")

        // Timing: scenes start on their first line; the first from the top.
        let live = LiveVideo.shared
        let synced = Lyrics(plain: nil, synced: lines.enumerated().map { Lyrics.Line(time: 12 + Double($0.offset) * 5, text: $0.element) }, source: "test")
        let board = LiveVideoBoard(key: "test", theme: "", scenes: [
            LiveVideoScene(firstLine: 0, lastLine: 1, prompt: "a"), LiveVideoScene(firstLine: 2, lastLine: 3, prompt: "b"),
            LiveVideoScene(firstLine: 4, lastLine: 5, prompt: "c"), LiveVideoScene(firstLine: 6, lastLine: 7, prompt: "d"),
        ])
        let red = picture(0.8, 0.1, 0.1), blue = picture(0.1, 0.2, 0.9)
        live.setForTesting(board: board, images: [0: red!, 1: blue!])
        check(live.sceneStart(0, lyrics: synced, duration: 60) == 0 && live.sceneStart(2, lyrics: synced, duration: 60) == 32, "scene starts: 0 s, then on its first line (32 s)")
        check(live.scene(at: 25, lyrics: synced, duration: 60)?.index == 1 && live.scene(at: 50, lyrics: synced, duration: 60)?.index == 3, "the scene on screen follows the song")
        check(live.sceneStart(2, lyrics: nil, duration: 80) == 40, "untimed lyrics: scenes spread over the track")
        check(live.image(upTo: 3).map { $0.0 } == 1, "a scene still being painted shows the latest picture")

        // Frame: the picture fills the frame, the sung line is drawn over it.
        var state = TVKaraoke.State(lyrics: synced, now: 25.5, title: "Test Song", artist: "Test Artist", cover: nil, backdrop: nil,
                                    status: "", pulse: 0, kick: 0, translate: { _ in nil })
        var input = live.input(state)
        check(input.picture != nil && input.scene == 1 && input.fade == 1, "frame input: scene 1's picture, fade done")
        state.now = 22.4
        input = live.input(state)
        check(input.previous != nil && input.fade < 1, String(format: "cross-fade at a scene change (%.2f)", input.fade))
        state.now = 25.5
        let r = ImageRenderer(content: LiveVideoFrame(input: live.input(state)).frame(width: 1280, height: 720))
        r.proposedSize = ProposedViewSize(width: 1280, height: 720)
        if let img = r.cgImage, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) {
            func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) { let o = y * img.bytesPerRow + x * 4; return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2])) }
            let mid = pixel(640, 200)
            check(mid.2 > mid.0 + 60, "the picture (blue) fills the frame: \(mid)")
            var white = 0
            for y in stride(from: 560, to: 700, by: 2) { for x in stride(from: 100, to: 1180, by: 3) { let c = pixel(x, y); if c.0 > 220, c.1 > 220, c.2 > 220 { white += 1 } } }
            check(white > 300, "the sung line is drawn at the bottom (\(white) white pixels)")
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--test-livevideo"), i + 1 < args.count, args[i + 1].hasSuffix(".png"),
               let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
            }
        } else {
            check(false, "frame renders")
        }
        live.setForTesting(board: nil, images: [:])

        // Installed models.
        let models = LiveVideoModel.installed()
        print("     models: " + (models.isEmpty ? "none" : models.map(\.label).joined(separator: ", ")))

        if ProcessInfo.processInfo.environment["MUSICAMP_TEST_SD"] == "1", let model = models.first {
            var t = Date()
            do {
                let groups = LiveVideoStory.groups(times: nil, count: lines.count)
                let b = try await LiveVideoStory.make(key: "test", title: "Ritorno", artist: "", lines: lines, groups: groups)
                check(b.scenes.count == groups.count && b.scenes.allSatisfy { !$0.prompt.isEmpty },
                      String(format: "storyboard by Apple Intelligence: %d scenes in %.1f s", b.scenes.count, Date().timeIntervalSince(t)))
                for s in b.scenes { print("     [\(s.firstLine)-\(s.lastLine)] \(s.prompt)") }
                print("     characters: \(b.characters)\n     mood: \(b.mood)")
                t = Date()
                if ProcessInfo.processInfo.environment["MUSICAMP_TEST_SD_ALL"] == "1" {
                    // Every scene, saved for a look.
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-livevideo", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    for (i, s) in b.scenes.enumerated() {
                        let prompt = [s.prompt, LiveVideoStyle.cinematic.prompt, b.mood].filter { !$0.isEmpty }.joined(separator: ", ")
                        if let img = try await live.paintRawForTesting(prompt, model: model) { LiveVideo.save(img, dir.appendingPathComponent("scene\(i).jpg")) }
                    }
                    print("     all scenes in \(dir.path)")
                }
                let img = try await live.paintForTesting(b.scenes[0].prompt, model: model)
                check(img?.width == model.size, String(format: "%@ painted a %dpx picture in %.1f s (model load included)", model.label, img?.width ?? 0, Date().timeIntervalSince(t)))
                if let img { LiveVideo.save(img, FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-livevideo.jpg")) }
            } catch {
                check(false, "storyboard and picture: \(error)")
            }
        }
        print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        return fails == 0 ? 0 : 1
    }
}
