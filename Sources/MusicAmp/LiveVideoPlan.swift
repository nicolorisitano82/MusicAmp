import Foundation
import FoundationModels

/// Live Video, second recipe: the small on-device model only *chooses* (who, what, where, framing, light) and the
/// code does the rest.
/// 1. Song structure from the lyrics alone (no AI): stanzas, the chorus and other repeated parts, verses, bridge.
/// 2. Treatment (one AI call): who sings to whom, at most two characters with fixed looks, 3–5 places, the look,
///    and what literally happens in each distinct part.
/// 3. Shot list (one AI call): per distinct part, fields picked from short lists.
/// 4. Prompts built by code in the order Stable Diffusion weighs most, within its ~75 tokens.
/// Repeated parts (the chorus) reuse their picture with another framing, so a song needs 6–8 pictures.
enum LiveVideoPlan {
    static let version = 6
    /// Distinct pictures per song at most (a chorus coming back reuses its own).
    static let maxPictures = 8

    // MARK: 1. Structure

    enum Kind: String, Codable { case intro, verse, chorus, refrain, bridge, outro }

    struct Section: Equatable {
        var lines: ClosedRange<Int>
        var kind: Kind
        /// Same number = same words (a chorus coming back): same picture.
        var part: Int
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Stanzas: split at empty lines, at pauses of 5 s or more, and every 8 lines at most.
    static func stanzas(lines: [String], times: [Double]?) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        var start: Int?
        for i in lines.indices {
            let empty = lines[i].trimmingCharacters(in: .whitespaces).isEmpty
            let pause = times.map { t in i > 0 && t.count == lines.count && t[i] - t[i - 1] >= 5 } ?? false
            if let s = start, empty || pause || i - s >= 8 {
                // An 8-line cut lands on a stanza of its own; a pause or an empty line closes the stanza.
                out.append(s...(i - 1))
                start = empty ? nil : i
            } else if start == nil, !empty {
                start = i
            }
        }
        if let s = start { out.append(s...(lines.count - 1)) }
        // Drop trailing empty lines from each stanza.
        return out.compactMap { r in
            var hi = r.upperBound
            while hi > r.lowerBound, lines[hi].trimmingCharacters(in: .whitespaces).isEmpty { hi -= 1 }
            return lines[hi].trimmingCharacters(in: .whitespaces).isEmpty ? nil : r.lowerBound...hi
        }
    }

    /// Sections from repeated lines: runs of two or more lines that come back later in the song are the chorus
    /// (the run repeated most) or refrains; the stretches between them are verses (split at stanza breaks, 8 lines
    /// at most); a verse after the second chorus that isn't the last section is the bridge, the last one the outro.
    static func sections(lines: [String], times: [Double]?) -> [Section] {
        let norm = lines.map(normalize)
        guard norm.contains(where: { !$0.isEmpty }) else { return [] }
        let counts = Dictionary(norm.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
        let repeated = norm.map { !$0.isEmpty && counts[$0, default: 0] >= 2 }
        // Runs of repeated lines (an empty line inside doesn't break them).
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        var last = -1
        for i in lines.indices {
            if repeated[i] { if start == nil { start = i }; last = i }
            else if !norm[i].isEmpty, let s = start { if last - s >= 1 { runs.append(s...last) }; start = nil }
        }
        if let s = start, last - s >= 1 { runs.append(s...last) }
        // Group runs by shared lines: the same chorus coming back.
        var runPart = [Int](repeating: -1, count: runs.count)
        var nextPart = 0
        for i in runs.indices where runPart[i] < 0 {
            runPart[i] = nextPart
            let a = Set(runs[i].map { norm[$0] }.filter { !$0.isEmpty })
            for j in (i + 1)..<runs.count where runPart[j] < 0 {
                let b = Set(runs[j].map { norm[$0] }.filter { !$0.isEmpty })
                if Double(a.intersection(b).count) / Double(max(1, min(a.count, b.count))) >= 0.5 { runPart[j] = nextPart }
            }
            nextPart += 1
        }
        let partCounts = Dictionary(runPart.map { ($0, 1) }, uniquingKeysWith: +)
        let chorusPart = partCounts.filter { $0.value > 1 }.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
        // Verses: the stretches between runs, cut into stanzas.
        var out: [Section] = []
        var cursor = 0
        func verses(_ r: ClosedRange<Int>) {
            for st in stanzas(lines: Array(lines[r]), times: times.map { Array($0[r]) }) {
                out.append(Section(lines: (st.lowerBound + r.lowerBound)...(st.upperBound + r.lowerBound), kind: .verse, part: -1))
            }
        }
        for (k, run) in runs.enumerated() {
            if run.lowerBound > cursor { verses(cursor...(run.lowerBound - 1)) }
            out.append(Section(lines: run, kind: runPart[k] == chorusPart ? .chorus : .refrain, part: runPart[k]))
            cursor = run.upperBound + 1
        }
        if cursor < lines.count { verses(cursor...(lines.count - 1)) }
        // Short verses (under 3 lines or 12 s) join the verse next to them.
        func length(_ r: ClosedRange<Int>) -> Double {
            guard let t = times, t.count == lines.count else { return Double(r.count) * 4 }
            return (r.upperBound + 1 < t.count ? t[r.upperBound + 1] : t[r.upperBound] + 4) - t[r.lowerBound]
        }
        var merged = true
        while merged {
            merged = false
            for i in out.indices where out[i].part < 0 && (out[i].lines.count < 3 || length(out[i].lines) < 12) {
                let j = i + 1 < out.count && out[i + 1].part < 0 ? i + 1 : (i > 0 && out[i - 1].part < 0 ? i - 1 : nil)
                guard let j else { continue }
                let lo = min(out[i].lines.lowerBound, out[j].lines.lowerBound), hi = max(out[i].lines.upperBound, out[j].lines.upperBound)
                out[min(i, j)].lines = lo...hi
                out.remove(at: max(i, j))
                merged = true
                break
            }
        }
        // At most `maxPictures` distinct parts: merge the shortest neighbouring verses.
        while Set(out.map { $0.part < 0 ? 1000 + out.firstIndex(of: $0)! : $0.part }).count > maxPictures {
            var best: Int?
            for i in 0..<(out.count - 1) where out[i].part < 0 && out[i + 1].part < 0 {
                if best == nil || out[i].lines.count + out[i + 1].lines.count < out[best!].lines.count + out[best! + 1].lines.count { best = i }
            }
            guard let b = best else { break }
            out[b].lines = out[b].lines.lowerBound...out[b + 1].lines.upperBound
            out.remove(at: b + 1)
        }
        // Still too many: refrains show the chorus picture, then verses past the limit reuse the previous verse's.
        func distinct() -> Int { Set(out.enumerated().map { $0.element.part < 0 ? 1000 + $0.offset : $0.element.part }).count }
        if distinct() > maxPictures, let cp = chorusPart {
            for i in out.indices where out[i].kind == .refrain { out[i].part = cp }
        }
        var reuse: [Int: Int] = [:]   // section → earlier verse section whose picture it shows
        if distinct() > maxPictures {
            var budget = maxPictures - Set(out.compactMap { $0.part >= 0 ? $0.part : nil }).count
            var lastVerse: Int?
            for i in out.indices where out[i].part < 0 {
                if budget > 0 || lastVerse == nil { budget -= 1; lastVerse = i } else if let l = lastVerse { reuse[i] = l }
            }
        }

        // Each verse is a part of its own; the first verse after the second chorus is the bridge, the last the outro.
        let chorusAt = out.indices.filter { out[$0].kind == .chorus }
        var bridged = false
        for i in out.indices where out[i].part < 0 && reuse[i] == nil {
            out[i].part = nextPart
            nextPart += 1
            if i == out.count - 1, let first = chorusAt.first, i > first { out[i].kind = .outro }
            else if chorusAt.count >= 2, i > chorusAt[1], !bridged { out[i].kind = .bridge; bridged = true }
            else if i == 0, out.count > 3, out[0].lines.count <= 2 { out[i].kind = .intro }
        }
        for (i, from) in reuse { out[i].part = out[from].part }
        return out
    }

    // MARK: 2–3. Treatment and shot list

    struct Character: Codable, Equatable {
        var role: String
        var look: String
        /// What they wear: in action shots the person is drawn from this, not from their face.
        var outfit: String = ""
    }

    struct Shot: Codable, Equatable {
        var who = "A"            // A, B, A+B, crowd, none
        var action = ""
        var place = ""
        var framing = "medium"   // wide, medium, close-up, detail, crowd
        var light = ""
    }

    struct Treatment: Equatable {
        var voice = ""
        var characters: [Character] = []
        var places: [String] = []
        var style = ""
        var mood = ""
        var theme = ""
        var parts: [Int: String] = [:]
    }

    /// The director: from the reader's notes only (never the lyrics), the cast, the places, the look and one shot
    /// per part as fields.
    static let directorInstructions = """
        You are an acclaimed music video director. Your assistant read a song and took notes (you never see the \
        lyrics). Plan a video that tells the song's story through actions, like a short film, not a photo shoot. \
        Cast the main person (A) and, only if another person matters, a second one (B): a woman or a man with age, \
        and an outfit they keep all video long. Choose 3 to 5 concrete places from the notes (with their era if it \
        matters). Choose the look (cinematic for nightlife, fame, cities, drama; watercolor for gentle, nostalgic, \
        countryside; oil for classical, romantic, the past; illustration for playful, dreamy, fantasy).
        Then one shot per part. WHO is A, B, A+B, crowd or none. ACTION is one simple thing a viewer sees happen: one \
        verb and one clear object or place, 3 to 7 words: "runs for the night train", "dances in a club", "sings on \
        a stage", "drives along the coast", "reads a letter in the rain". Never a pose: no standing, looking, gazing, \
        staring, posing, sitting alone, waiting, thinking, feeling, smiling, remembering. PLACE is the number of a \
        place. FRAMING is wide, medium or crowd; one close-up is allowed, in the chorus. LIGHT is at most 5 \
        words. Each shot shows what that part says; when the title is a concrete image (a place, an object, \
        weather) it appears in the chorus. No old people, children or animals unless the notes name them.
        Answer in English, in exactly this layout:
        A: <role> | <a woman or a man, age> | <outfit>
        B: <role> | <a woman or a man, age> | <outfit>
        PLACES: <place>; <place>; <place>
        STYLE: <cinematic or watercolor or oil or illustration>
        1. WHO: A | ACTION: <…> | PLACE: <number> | FRAMING: <…> | LIGHT: <…>
        2. WHO: … (one line per part; leave out the B line if there is no second person)
        """

    /// Poses, not actions: such a shot is sent back to the director once.
    static let staticVerbs: Set<String> = ["stand", "stands", "standing", "look", "looks", "looking", "gaze", "gazes", "gazing", "stare", "stares",
                                           "staring", "pose", "poses", "posing", "sit", "sits", "sitting", "wait", "waits", "waiting", "think",
                                           "thinks", "thinking", "feel", "feels", "feeling", "smile", "smiles", "smiling", "remember", "remembers",
                                           "watch", "watches", "watching", "stays", "lingers", "reflects", "contemplates", "faces", "rises", "glows"]

    static func isPose(_ action: String) -> Bool {
        let w = normalize(action).split(separator: " ").map(String.init)
        guard let first = w.first(where: { !["she", "he", "they", "a", "b", "slowly", "quietly", "alone"].contains($0) }) else { return true }
        return staticVerbs.contains(first) || w.count < 3
    }

    static let fixInstructions = """
        You are a music video director fixing your shot list. These shots show a pose, not an event. Rewrite each \
        ACTION as something a viewer sees happen, with an object or another person, 4 to 10 words, true to its \
        part (e.g. "runs for the last night train", "throws her ring into the river"). Never standing, looking, \
        gazing, staring, posing, sitting, waiting, thinking, feeling, smiling. Answer with one line per shot:
        N. ACTION: <…>
        """

    /// Strips what the model copies from the layout: "look (…)", brackets, "<…>".
    static func clean(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        // "1. neon train station" → "neon train station"
        if let d = v.firstIndex(where: { !$0.isNumber }), d != v.startIndex, [".", ")"].contains(v[d]) { v = String(v[v.index(after: d)...]).trimmingCharacters(in: .whitespaces) }
        for prefix in ["look (", "role (", "look:", "role:"] where v.lowercased().hasPrefix(prefix) { v = String(v.dropFirst(prefix.count)) }
        if v.hasSuffix(")"), !v.contains("(") { v.removeLast() }
        v = v.replacingOccurrences(of: "a woman: ", with: "a woman, ").replacingOccurrences(of: "a man: ", with: "a man, ")
        return v.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "<>\"")))
    }

    /// Reads VOICE / A / B / PLACES / STYLE / MOOD / THEME and the numbered parts.
    static func parseTreatment(_ text: String) -> Treatment {
        var t = Treatment()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let up = line.uppercased()
            func value(_ tag: String) -> String { String(line.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "<>\"-"))) }
            if up.hasPrefix("VOICE:") { if t.voice.isEmpty { t.voice = value("VOICE:") }; continue }
            if up.hasPrefix("PLACES:") {
                if t.places.isEmpty { t.places = value("PLACES:").components(separatedBy: CharacterSet(charactersIn: ";")).map(clean).filter { !$0.isEmpty && !$0.lowercased().hasPrefix("place") }.prefix(5).map { $0 } }
                continue
            }
            if up.hasPrefix("STYLE:") {
                if t.style.isEmpty { t.style = ["cinematic", "watercolor", "oil", "illustration"].first { value("STYLE:").lowercased().hasPrefix($0) } ?? "" }
                continue
            }
            if up.hasPrefix("MOOD:") { if t.mood.isEmpty { t.mood = value("MOOD:") }; continue }
            if up.hasPrefix("THEME:") { if t.theme.isEmpty { t.theme = value("THEME:") }; continue }
            if (up.hasPrefix("A:") || up.hasPrefix("B:")), t.characters.count < 2 {
                let parts = value(String(line.prefix(2))).components(separatedBy: "|").map(clean)
                let look = parts.count > 1 ? parts[1] : parts[0]
                let outfit = parts.count > 2 ? parts[2] : ""
                let lower = look.lowercased()
                if !look.isEmpty, !["none", "n/a", "-"].contains(lower), !lower.contains("leave"), !lower.hasPrefix("age, hair") {
                    t.characters.append(Character(role: parts.count > 1 ? parts[0] : "", look: look, outfit: outfit))
                }
                continue
            }
            // "N. …" written literally: number the parts in order.
            if up.hasPrefix("N.") || up.hasPrefix("N:") {
                let v = clean(String(line.dropFirst(2)))
                if v.count > 6 { t.parts[(t.parts.keys.max() ?? 0) + 1] = v }
                continue
            }
            // "1. …", "Part 1: …", "Part 1 (chorus): …"
            var rest = Substring(line)
            if up.hasPrefix("PART ") { rest = rest.dropFirst(5) }
            let digits = rest.prefix { $0.isNumber }
            guard let n = Int(digits), n >= 1 else { continue }
            var body = rest.dropFirst(digits.count).drop { ".:)- ".contains($0) }
            if body.hasPrefix("("), let close = body.firstIndex(of: ")") { body = body[body.index(after: close)...].drop { ".:)- ".contains($0) } }
            let v = body.trimmingCharacters(in: .whitespaces)
            if v.count > 6, !v.lowercased().contains("at most"), t.parts[n] == nil { t.parts[n] = v }
        }
        return t
    }

    /// Reads "N. WHO: … | ACTION: … | PLACE: … | FRAMING: … | LIGHT: …" lines (fields in any order).
    static func parseShots(_ text: String, places: [String]) -> [Int: Shot] {
        var out: [Int: Shot] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
            let digits = line.prefix { $0.isNumber }
            guard let n = Int(digits), n >= 1 else { continue }
            var shot = Shot()
            var found = false
            let fields = line.dropFirst(digits.count).drop { ".:)- ".contains($0) }.components(separatedBy: "|")
            if !fields.contains(where: { $0.uppercased().contains("WHO:") || $0.uppercased().contains("FRAMING:") }), fields.count >= 3 {
                // No keys: "A: action | place | framing | light".
                let first = fields[0].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if first.count == 2, first[0].count <= 5 { shot.who = first[0].uppercased().replacingOccurrences(of: " ", with: ""); shot.action = first[1] } else { shot.action = first.joined() }
                let rest = fields.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                for f in rest {
                    let fl = f.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                    if let k = Int(f.prefix { $0.isNumber }), places.indices.contains(k - 1), shot.place.isEmpty { shot.place = places[k - 1] }
                    else if let fr = ["wide", "medium", "closeup", "detail", "crowd"].first(where: { fl.hasPrefix($0) }) { shot.framing = fr == "closeup" ? "close-up" : fr }
                    else if shot.light.isEmpty { shot.light = f }
                }
                out[n] = shot
                continue
            }
            for field in fields {
                let kv = field.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".<>\""))) }
                guard kv.count == 2 else { continue }
                var key = kv[0].uppercased().components(separatedBy: " ").last ?? ""
                // "A & B: exchange a glance" with no WHO key: the people, and the action if none follows.
                let whoKey = kv[0].uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "&", with: "+").replacingOccurrences(of: "AND", with: "+")
                if ["A", "B", "A+B", "B+A", "CROWD", "NONE"].contains(whoKey) {
                    shot.who = whoKey; found = true
                    if shot.action.isEmpty { shot.action = kv[1].split(separator: " ").prefix(8).joined(separator: " ") }
                    key = ""
                }
                let v = kv[1]
                switch key {
                case "WHO": shot.who = v.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "&", with: "+").replacingOccurrences(of: "AND", with: "+"); found = true
                case "ACTION": shot.action = v.split(separator: " ").prefix(10).joined(separator: " ")
                case "PLACE":
                    if let k = Int(v.prefix { $0.isNumber }), places.indices.contains(k - 1) { shot.place = places[k - 1] }
                    else { shot.place = places.first { $0.lowercased() == v.lowercased() } ?? v }
                case "FRAMING":
                    let f = v.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
                    shot.framing = ["wide", "medium", "closeup", "detail", "crowd"].first { f.contains($0) }.map { $0 == "closeup" ? "close-up" : $0 } ?? "medium"
                case "LIGHT": shot.light = v.split(separator: " ").prefix(6).joined(separator: " ")
                default: break
                }
            }
            if found || !shot.action.isEmpty { out[n] = shot }
        }
        return out
    }

    // MARK: 4. Prompt

    /// Subject first (Stable Diffusion weighs the first words most), then action, place, framing words,
    /// light, the look and the mood, cut to ~60 words so nothing important falls past its 75 tokens.
    static let clothing = ["dress", "gown", "coat", "jacket", "shirt", "t-shirt", "jeans", "suit", "sweater", "hoodie", "skirt", "boots",
                           "uniform", "blazer", "trench", "cardigan", "overalls", "scarf", "hat", "sequin", "leather", "denim", "top", "pants", "trousers"]

    /// "a young woman in a red trench coat": who (gender and age only) and what they wear, never their face.
    static func short(_ c: Character?, fallback: String) -> String {
        guard let c else { return fallback }
        let text = (c.role + " " + c.look).lowercased()
        let noun = text.range(of: "\\bwoman\\b", options: .regularExpression) != nil ? "woman" : (text.range(of: "\\bman\\b", options: .regularExpression) != nil ? "man" : nil)
        let age = text.contains("thirties") ? "" : "young "
        var outfit = c.outfit
        if outfit.isEmpty {
            // The clothes in the looks ("long dark hair, red coat" → "red coat").
            let pieces = c.look.replacingOccurrences(of: "\\s+(and|with|wearing|in)\\s+", with: ",", options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: CharacterSet(charactersIn: ",;")).map { $0.trimmingCharacters(in: .whitespaces) }
            outfit = pieces.filter { p in clothing.contains { p.lowercased().contains($0) } }.joined(separator: " and ")
        }
        let person = noun.map { "a \(age)\($0)" } ?? fallback
        return outfit.isEmpty ? person : "\(person) in \(outfit)"
    }

    /// The event first (who in their clothes, doing what, where), then the framing, the light and the look: Stable
    /// Diffusion weighs the first words most, and a face described first becomes a portrait.
    static func prompt(_ s: Shot, characters: [Character], style: LiveVideoStyle, mood: String) -> String {
        let a = short(characters.first, fallback: "a young woman")
        let b = short(characters.count > 1 ? characters[1] : nil, fallback: "a young man")
        let who: String
        switch s.who.uppercased() {
        case "B": who = b
        case "A+B", "B+A", "AB": who = "\(a) and \(b)"
        case "CROWD": who = "a crowd of people"
        case "NONE": who = ""
        default: who = a
        }
        let place = s.place.isEmpty ? "" : "in \(s.place)"
        let event: String
        let framing: String
        switch s.framing {
        case "close-up":
            // The face is allowed once, with the person's looks.
            let look = s.who.uppercased() == "B" ? (characters.count > 1 ? characters[1].look : b) : (characters.first?.look ?? a)
            event = ["close-up of \(look)", s.action, place].filter { !$0.isEmpty }.joined(separator: " ")
            framing = "close-up, emotional expression"
        case "crowd":
            event = [who.isEmpty || s.who.uppercased() == "CROWD" ? "a crowd of people" : who, s.action, place, s.who.uppercased() == "CROWD" ? "" : "among a crowd"].filter { !$0.isEmpty }.joined(separator: " ")
            framing = "wide shot, many people"
        case "wide":
            event = [who, s.action, place].filter { !$0.isEmpty }.joined(separator: " ")
            framing = "wide shot, full body"
        default:
            event = [who, s.action, place].filter { !$0.isEmpty }.joined(separator: " ")
            framing = "medium shot"
        }
        // The look right after the event, so it holds for the whole picture (placed last it got lost).
        var parts = [event, style.prompt, framing, s.light, mood]
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var words = 0
        var kept: [String] = []
        for p in parts {
            let n = p.split(separator: " ").count
            if words + n > 60, !kept.isEmpty { break }
            kept.append(p)
            words += n
        }
        return kept.joined(separator: ", ")
    }

    /// Negative prompt suited to the framing.
    static func negative(_ framing: String, allowOld: Bool = false) -> String {
        var base = LiveVideoEngine.negative
        if !allowOld { base += ", elderly, old person, wrinkles, grey hair" }
        switch framing {
        case "close-up": return base + ", full body, tiny figure"
        default: return base + ", portrait, posing, looking at camera, headshot, abstract, geometric pattern"
        }
    }

    /// What makes Stable Diffusion paint old people, and its young counterpart; lyrics about age keep them.
    static let olderToYoung: [(String, String)] = [
        ("silver-haired", "dark-haired"), ("grey-haired", "dark-haired"), ("gray-haired", "dark-haired"), ("white-haired", "dark-haired"),
        ("silver hair", "dark hair"), ("grey hair", "dark hair"), ("gray hair", "dark hair"), ("white hair", "dark hair"),
        ("in her fifties", "in her twenties"), ("in her sixties", "in her twenties"), ("in her seventies", "in her twenties"),
        ("in his fifties", "in his twenties"), ("in his sixties", "in his twenties"), ("in his seventies", "in his twenties"),
        ("middle-aged", "young"), ("elderly", "young"), ("older", "young"), ("old", "young"), ("aged", "young"), ("wrinkled", ""),
        ("grandmother", "young woman"), ("grandfather", "young man"),
    ]
    static let agingWords = ["old man", "old woman", "old lady", "grow old", "growing old", "getting old", "grey hair", "gray hair", "grandma", "grandpa",
                             "grandmother", "grandfather", "nonna", "nonno", "vecchio", "vecchia", "anziano", "anziana", "invecchiare"]

    /// Casts young unless the lyrics are about age: "a woman in her sixties with silver hair" → "a woman in her
    /// twenties with dark hair".
    static func youthful(_ look: String) -> String {
        var l = look
        for (old, young) in olderToYoung {
            l = l.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: old) + "\\b", with: young, options: [.regularExpression, .caseInsensitive])
        }
        l = l.replacingOccurrences(of: "young young", with: "young").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        let lower = l.lowercased()
        if !["twenties", "thirties", "young", "teen"].contains(where: { lower.contains($0) }) {
            if lower.range(of: "\\bwoman\\b", options: .regularExpression) != nil { l = l.replacingOccurrences(of: "\\bwoman\\b", with: "woman in her twenties", options: [.regularExpression, .caseInsensitive]) }
            else if lower.range(of: "\\bman\\b", options: .regularExpression) != nil { l = l.replacingOccurrences(of: "\\bman\\b", with: "man in his twenties", options: [.regularExpression, .caseInsensitive]) }
        }
        return l
    }

    // MARK: The plan

    /// The reader's answer through ReaderCheck (names out, lyric phrases rewritten). A rewrite that lost notes or
    /// parts isn't kept: the original is used with the names stripped.
    static func checked(_ raw: String, lines: [String], artist: String, title: String, parts: Bool) async -> String {
        guard !raw.isEmpty else { return raw }
        let fixed = await ReaderCheck.checked(raw, lyrics: lines, artist: artist, title: title)
        let a = LiveVideoStory.parse(raw), b = LiveVideoStory.parse(fixed)
        let lost = parts ? b.parts.count < a.parts.count
            : [\LiveVideoStory.Parsed.voice, \.characters, \.setting, \.theme].contains { !a[keyPath: $0].isEmpty && b[keyPath: $0].isEmpty }
        return lost ? ReaderCheck.strip(raw, artist: artist, title: title) : fixed
    }

    /// The storyboard for a song: sections on the timeline, one picture per distinct part.
    static func make(key: String, title: String, artist: String, lines: [String], times: [Double]?, style chosen: LiveVideoStyle) async throws -> LiveVideoBoard {
        let song = "Song: \"\(title)\"\(artist.isEmpty ? "" : " by \(artist)")."
        var secs = sections(lines: lines, times: times)
        if secs.isEmpty {
            // No lyrics: four parts from the title.
            secs = (0..<4).map { Section(lines: -1 ... -1, kind: .verse, part: $0) }
        }
        // Distinct parts in order of first appearance.
        var order: [Int] = []
        for s in secs where !order.contains(s.part) { order.append(s.part) }
        let debug = ProcessInfo.processInfo.environment["MUSICAMP_BOARD_DEBUG"] == "1"

        // 2. The reader: the song's notes (whole lyrics), then what each distinct part says.
        let full = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        let briefRaw = (try? await LiveVideoStory.ask(LiveVideoStory.briefInstructions,
            lines.isEmpty ? "\(song) Its lyrics aren't available: imagine its video from the title." : "\(song)\nThe lyrics:\n\n\(full)")) ?? ""
        var notes = LiveVideoStory.parse(await checked(briefRaw, lines: lines, artist: artist, title: title, parts: false))
        let header = [notes.voice.isEmpty ? "" : "Who speaks: \(notes.voice)", notes.characters.isEmpty ? "" : "People: \(notes.characters)",
                      notes.setting.isEmpty ? "" : "World: \(notes.setting)", notes.theme.isEmpty ? "" : "Meaning: \(notes.theme)"]
            .filter { !$0.isEmpty }.joined(separator: "\n")
        let partText = order.enumerated().map { n, p -> String in
            let s = secs.first { $0.part == p }!
            let words = s.lines.lowerBound < 0 ? "(no lyrics: a moment suggested by the title)" : lines[s.lines].filter { !$0.isEmpty }.joined(separator: "\n")
            return "Group \(n + 1) (\(s.kind.rawValue)):\n\(words)"
        }.joined(separator: "\n\n")
        let partsRaw = (try? await LiveVideoStory.ask(LiveVideoStory.partsInstructions, "\(song)\n\(header)\n\nThe lyrics, in \(order.count) groups. Write exactly \(order.count) numbered lines.\n\n\(partText)")) ?? ""
        notes.parts = LiveVideoStory.parse(await checked(partsRaw, lines: lines, artist: artist, title: title, parts: true)).parts
            .filter { !LiveVideoStory.isPlaceholder($0.value) }
        if debug { print("--- reader\n\(header)\nMood: \(notes.mood)\n\(partsRaw)\n---") }

        // 3. The director: cast, places, look and the shots, from the notes only.
        let directorPrompt = """
            \(song)
            Your assistant's notes:
            \(header)
            Mood: \(notes.mood)
            Parts:
            \(order.enumerated().map { n, p in "\(n + 1). (\(secs.first { $0.part == p }!.kind.rawValue)) \(notes.parts[n + 1] ?? notes.theme)" }.joined(separator: "\n"))

            Plan it: A, B, PLACES, STYLE, then exactly \(order.count) numbered shot lines.
            """
        let directorRaw = (try? await LiveVideoStory.ask(directorInstructions, directorPrompt)) ?? ""
        if debug { print("--- director\n\(directorRaw)\n---") }
        var t = parseTreatment(directorRaw)
        t.parts = [:]
        let allowOld = lines.contains { l in let n = " " + normalize(l) + " "; return agingWords.contains { n.contains(" " + $0 + " ") } }
        if !allowOld { t.characters = t.characters.map { Character(role: youthful($0.role), look: youthful($0.look), outfit: $0.outfit) } }
        t.mood = notes.mood
        t.theme = notes.theme.isEmpty ? "the feeling of the song \"\(title)\"" : notes.theme
        if t.places.isEmpty { t.places = notes.setting.components(separatedBy: CharacterSet(charactersIn: ",;")).map(clean).filter { !$0.isEmpty }.prefix(5).map { $0 } }
        if t.places.isEmpty { t.places = ["a city street at night", "a small bedroom", "a stage with lights"] }
        var shots = parseShots(directorRaw, places: t.places)
        let framings = ["wide", "medium", "close-up", "wide", "detail", "medium", "crowd"]
        for n in 1...max(1, order.count) where shots[n] == nil || shots[n]?.place.isEmpty == true {
            var s = shots[n] ?? Shot()
            if s.place.isEmpty { s.place = t.places[(n - 1) % t.places.count] }
            if shots[n] == nil { s.framing = framings[(n - 1) % framings.count]; s.action = notes.parts[n].map { String($0.split(separator: " ").prefix(6).joined(separator: " ")) } ?? "" }
            shots[n] = s
        }

        // Framing by code: wide and medium shots tell the story; one close-up is kept (in the chorus when there is
        // one), others become medium shots. The first shot opens wide.
        let chorusShot = order.firstIndex { p in secs.first { $0.part == p }?.kind == .chorus }.map { $0 + 1 }
        var closeUp = false
        for n in 1...max(1, order.count) {
            guard var s = shots[n] else { continue }
            if s.framing == "detail" { s.framing = "close-up" }
            if s.framing == "close-up" {
                if closeUp || n == 1 || (chorusShot != nil && n != chorusShot) { s.framing = "medium" } else { closeUp = true }
            }
            if n == 1, s.framing == "medium" { s.framing = "wide" }
            shots[n] = s
        }
        // Poses sent back to the director once, to become events.
        let poses = (1...max(1, order.count)).filter { shots[$0].map { isPose($0.action) } ?? false }
        let posesBefore = poses.map { "\($0). \(shots[$0]?.action ?? "")" }
        if !poses.isEmpty {
            let ask = poses.map { n in "\(n). (part: \(notes.parts[n] ?? notes.theme)) ACTION was: \(shots[n]?.action ?? "")" }.joined(separator: "\n")
            let fixed = (try? await LiveVideoStory.ask(fixInstructions, "\(song)\n\(header)\n\n\(ask)")) ?? ""
            if debug { print("--- fixes\n\(fixed)\n---") }
            for line in fixed.components(separatedBy: .newlines) {
                let l = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                guard let n = Int(l.prefix { $0.isNumber }), poses.contains(n), let r = l.range(of: "ACTION:", options: .caseInsensitive) else { continue }
                let action = l[r.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"<>.")))
                if !action.isEmpty, !isPose(action) { shots[n]?.action = action.split(separator: " ").prefix(10).joined(separator: " ") }
            }
        }

        // 4. Prompts, by code.
        let look = chosen == .auto ? (LiveVideoStyle(rawValue: t.style.trimmingCharacters(in: .punctuationCharacters)) ?? .cinematic) : chosen
        let shotList = order.indices.map { shots[$0 + 1] ?? Shot() }
        let prompts = shotList.map { prompt($0, characters: t.characters, style: look == .auto ? .cinematic : look, mood: t.mood) }

        // Timeline: one scene per section; a repeated part shows its picture again, framed differently.
        var seen: [Int: Int] = [:]
        let scenes = secs.map { s -> LiveVideoScene in
            let img = order.firstIndex(of: s.part) ?? 0
            let v = seen[img, default: 0]
            seen[img] = v + 1
            return LiveVideoScene(firstLine: s.lines.lowerBound, lastLine: s.lines.upperBound, prompt: prompts[img], image: img, variation: v,
                                  framing: shotList[img].framing, kind: s.kind.rawValue)
        }
        let reasoning = LiveVideoReasoning(
            voice: notes.voice, people: notes.characters, world: notes.setting, mood: notes.mood, theme: t.theme,
            meanings: order.indices.map { notes.parts[$0 + 1] ?? "" },
            sections: order.map { p in secs.first { $0.part == p }?.kind.rawValue ?? "" },
            cast: t.characters.enumerated().map { i, c in "\(i == 0 ? "A" : "B"): \(c.role) — \(c.look)\(c.outfit.isEmpty ? "" : " — " + c.outfit)" },
            places: t.places, look: look.rawValue, posesFixed: posesBefore)
        return LiveVideoBoard(key: key, theme: t.theme, style: look.rawValue, characters: t.characters.map(\.look).joined(separator: "; "),
                              mood: t.mood, scenes: scenes, shots: prompts, negatives: shotList.map { negative($0.framing, allowOld: allowOld) }, shotInfo: shotList,
                              reasoning: reasoning)
    }
}
