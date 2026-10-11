import CoreGraphics
import Vision

/// Checks a painted picture against its shot with Apple's Vision (on device): are the people there (or the
/// crowd), is the framing right (a wide shot isn't a face filling the frame), and, when the place is something
/// Vision knows (a stage, a street, a train…), is it in the picture. A picture that fails is painted once more
/// with another seed and the better of the two is kept.
enum LiveVideoCheck {
    struct Result {
        var score = 0
        var max = 0
        var reasons: [String] = []
        var labels: [String] = []
        var people = 0
        var faceArea = 0.0
        /// Hard failures (worth painting again): nobody / no crowd, or a wide shot that came out as a face.
        var hard: [String] = []
        var ok: Bool { hard.isEmpty }
    }

    /// Vision's scene/object vocabulary (lower case), to know which place words it can confirm.
    static let vocabulary: Set<String> = {
        let r = VNClassifyImageRequest()
        return Set(((try? r.supportedIdentifiers()) ?? []).map { $0.lowercased() })
    }()

    static func analyse(_ img: CGImage) -> (labels: [String: Float], people: Int, faceArea: Double) {
        let classify = VNClassifyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        try? handler.perform([classify, humans, faces])
        var labels: [String: Float] = [:]
        for o in classify.results ?? [] where o.confidence > 0.05 { labels[o.identifier.lowercased()] = o.confidence }
        let faceArea = (faces.results ?? []).map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        let people = max(humans.results?.count ?? 0, faces.results?.count ?? 0)
        return (labels, people, faceArea)
    }

    /// Place words Vision can check ("a smoky jazz club stage" → ["stage"]).
    static func placeWords(_ place: String) -> [String] {
        let words = LiveVideoPlan.normalize(place).split(separator: " ").map(String.init)
        var out = words.filter { $0.count > 2 && vocabulary.contains($0) }
        for (a, b) in zip(words, words.dropFirst()) where vocabulary.contains("\(a)_\(b)") { out.append("\(a)_\(b)") }
        return out
    }

    static func check(_ img: CGImage, shot: LiveVideoPlan.Shot) -> Result {
        let a = analyse(img)
        var r = Result(labels: a.labels.sorted { $0.value > $1.value }.prefix(8).map(\.key), people: a.people, faceArea: a.faceArea)
        let who = shot.who.uppercased()
        func rule(_ ok: Bool, _ why: String, hard: Bool = true) { r.max += 1; if ok { r.score += 1 } else { r.reasons.append(why); if hard { r.hard.append(why) } } }
        if who == "CROWD" || shot.framing == "crowd" {
            rule(a.people >= 3 || ["crowd", "people", "audience", "concert", "festival"].contains { a.labels[$0] != nil }, "no crowd")
        } else if who != "NONE" {
            rule(a.people >= 1 || a.labels["people"] != nil || a.labels["person"] != nil, "nobody in it")
        }
        switch shot.framing {
        case "wide", "crowd": rule(a.faceArea < 0.05, "a face fills a wide shot")
        case "medium": rule(a.faceArea < 0.14, "a portrait, not a medium shot")
        case "close-up": if who != "NONE" { rule(a.faceArea > 0.02, "not a close-up", hard: false) }
        default: break
        }
        let place = placeWords(shot.place)
        // The place only weighs in when choosing between two pictures: Vision's labels miss too many settings.
        if !place.isEmpty { rule(place.contains { a.labels[$0] != nil }, "no \(place.joined(separator: "/"))", hard: false) }
        return r
    }
}
