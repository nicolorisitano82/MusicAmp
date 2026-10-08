import FoundationModels
import SwiftUI

/// Smart playlists described in words ("calm acoustic songs from the 70s", "brani tristi ma ballabili"): Apple's
/// on-device model writes the rules, constrained to MusicAmp's fields; the user sees the rules and the track count
/// before adding the playlist, and can edit it like any other.
enum SmartPlaylistAI {
    /// What the model gets to know about this library: its genres (most common first), moods and instruments.
    static func context(pool: [SmartItem]) -> String {
        var genres: [String: Int] = [:]
        for it in pool { if let g = it.stats.genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty { genres[g, default: 0] += 1 } }
        let top = genres.sorted { $0.value > $1.value }.prefix(30).map(\.key)
        let styles = Set(SonicAnalyzer.styleNames.values).sorted()
        return """
            Genres in this library: \(top.isEmpty ? "unknown" : top.joined(separator: ", ")).
            Moods (field mood, op equals): \(SonicFeatures.moods.joined(separator: ", ")).
            Instruments (field style, op contains): \(styles.joined(separator: ", ")).
            This year is \(Calendar.current.component(.year, from: Date())).
            """
    }

    static let instructions = """
        You turn a description of a playlist into rules over a music library. Fields: title, artist, album, genre \
        (text), year (number), lengthMinutes, rating (0-5 stars), plays, bpm (tempo), key (musical key like Am, C, F#), \
        mood (one of the listed moods), style (an instrument or voice from the list), lastPlayedDaysAgo and \
        addedDaysAgo (days). Decades become two year rules (e.g. the 80s: year greaterThan 1979 and year lessThan 1990). \
        "Fast" or "for running" means bpm greaterThan about 120; "slow" bpm lessThan about 95. "Sad", "chill", \
        "energetic" and similar words map to mood; "acoustic" to style Acoustic Guitar; "instrumental" to style not \
        containing Vocals. Use genre only with genres of this library. Prefer few, precise rules. Use limit 0 unless \
        the user asks for a number of tracks or a duration (about 4 minutes per track). matchAll is true: every \
        rule must hold. Only add a rule for something the user actually asked for; never negate what they asked.

        Examples:
        "calm acoustic songs" → matchAll true; mood equals Calm; style contains Acoustic Guitar.
        "energetic tracks for running, about an hour" → matchAll true; mood equals Energetic; bpm greaterThan 120; limit 15; order random.
        "Taylor Swift songs I never played" → matchAll true; artist contains Taylor Swift; plays equals 0.
        "80s rock" → matchAll true; genre contains Rock; year greaterThan 1979; year lessThan 1990.
        "sad but danceable" → matchAll true; mood equals Melancholic; bpm greaterThan 105.
        "my favourites" → matchAll true; rating greaterThan 3; order highestRated.
        "instrumental piano" → matchAll true; style contains Piano; style notContains Vocals.
        "songs in A minor or C major" → matchAll false; key equals Am; key equals C.
        "pop songs from 2020" → matchAll true; genre contains Pop; year equals 2020.
        "two hours of jazz" → matchAll true; genre contains Jazz; limit 30. A duration is always a limit (minutes ÷ 4), never a lengthMinutes rule.
        """

    static func generate(_ description: String, pool: [SmartItem]) async throws -> SmartPlaylist {
        let session = try AI.session(instructions + "\n" + context(pool: pool))
        let spec = try await session.respond(to: "Playlist: \(description)", generating: AIPlaylistSpec.self).content
        var p = convert(spec)
        // "Any rule" only when the user said "or": otherwise one loose rule lets the whole library in.
        let words = Set(description.lowercased().split { !$0.isLetter }.map(String.init))
        if !p.matchAll, words.isDisjoint(with: ["or", "o", "oppure", "either"]) { p.matchAll = true }
        // Decades and years are easy to miss for the model and easy to read by rule.
        if !p.rules.contains(where: { $0.field == .year }) { p.rules += yearRules(description) }
        return p
    }

    /// "80s", "'80s", "1980s", "anni '80", "anni 80" → 1980…1989; "del 2020", "from 2020" → 2020.
    static func yearRules(_ text: String) -> [SmartRule] {
        let t = text.lowercased()
        if let r = t.range(of: #"(19|20)?\d0'?s\b|anni\s*'?\d0\b"#, options: .regularExpression) {
            let digits = t[r].filter(\.isNumber)
            var start: Int?
            if digits.count == 4 { start = Int(digits) }
            else if digits.count == 2, let d = Int(digits) { start = d >= 30 ? 1900 + d : 2000 + d }
            if let s = start {
                return [SmartRule(field: .year, op: .greater, number: Double(s - 1)), SmartRule(field: .year, op: .less, number: Double(s + 10))]
            }
        }
        if let r = t.range(of: #"\b(19[5-9]\d|20[0-4]\d)\b"#, options: .regularExpression), let y = Int(t[r]) {
            return [SmartRule(field: .year, op: .numEquals, number: Double(y))]
        }
        return []
    }

    static func convert(_ s: AIPlaylistSpec) -> SmartPlaylist {
        var p = SmartPlaylist()
        p.name = s.name.isEmpty ? "New Smart Playlist" : s.name
        p.matchAll = s.matchAll
        p.limit = max(0, min(1000, s.limit))
        p.order = order(s.order)
        p.rules = s.rules.compactMap(rule)
        if p.rules.isEmpty { p.rules = [SmartRule()] }
        return p
    }

    static func rule(_ r: AIRule) -> SmartRule? {
        let field: SmartRule.Field
        switch r.field {
        case .title: field = .title
        case .artist: field = .artist
        case .album: field = .album
        case .genre: field = .genre
        case .year: field = .year
        case .lengthMinutes: field = .duration
        case .rating: field = .rating
        case .plays: field = .plays
        case .bpm: field = .bpm
        case .key: field = .key
        case .mood: field = .mood
        case .style: field = .style
        case .lastPlayedDaysAgo: field = .lastPlayed
        case .addedDaysAgo: field = .added
        }
        var out = SmartRule(field: field, op: .contains, text: r.text.trimmingCharacters(in: .whitespaces), number: r.number)
        switch field.kind {
        case .text:
            switch r.op {
            case .notContains: out.op = .notContains
            case .equals: out.op = .equals
            case .notEquals: out.op = .notEquals
            default: out.op = .contains
            }
            if field == .mood {
                // Moods are a closed list: normalise the word, and match it exactly.
                guard let m = SonicFeatures.moods.first(where: { $0.caseInsensitiveCompare(out.text) == .orderedSame }) else { return nil }
                out.text = m
                out.op = r.op == .notEquals || r.op == .notContains ? .notEquals : .equals
            }
            if out.text.isEmpty { return nil }
        case .number:
            switch r.op {
            case .greaterThan: out.op = .greater
            case .lessThan: out.op = .less
            case .notEquals: out.op = .numNotEquals
            default: out.op = .numEquals
            }
            // Values outside what the field can hold say nothing (BPM > 1, year < 100…).
            let range: ClosedRange<Double>
            switch field {
            case .bpm: range = 40...250
            case .year: range = 1900...2100
            case .rating: range = 0...5
            case .duration: range = 0.5...120
            default: range = 0...1_000_000
            }
            if !range.contains(out.number) { return nil }
        case .date:
            switch r.op {
            case .withinLastDays, .lessThan: out.op = .inLast
            case .notWithinLastDays, .greaterThan: out.op = .notInLast
            default: out.op = .inLast
            }
            if out.number <= 0 { out.number = 30 }
        case .key:
            switch r.op {
            case .equals: out.op = .keyIs
            case .notEquals: out.op = .keyIsNot
            default: out.op = .keyCompatible
            }
            if SmartRule.parseKey(out.text) == nil { return nil }
        }
        return out
    }

    static func order(_ o: AIOrder) -> SmartPlaylist.Order {
        switch o {
        case .random: return .random
        case .mostPlayed: return .mostPlayed
        case .leastPlayed: return .leastPlayed
        case .highestRated: return .highestRated
        case .recentlyPlayed: return .recentlyPlayed
        case .recentlyAdded: return .recentlyAdded
        case .year: return .year
        case .bpm: return .bpm
        case .artist: return .artist
        case .album: return .album
        case .title: return .title
        }
    }

    /// Human-readable rules, for the preview.
    static func describe(_ p: SmartPlaylist) -> String {
        let rules = p.rules.map { r -> String in
            let value: String
            switch r.field.kind {
            case .text, .key: value = "“\(r.text)”"
            case .number: value = r.number == r.number.rounded() ? String(Int(r.number)) : String(format: "%.1f", r.number)
            case .date: value = "\(Int(r.number)) days"
            }
            return "\(r.field.label) \(r.op.label) \(value)"
        }
        var s = rules.joined(separator: p.matchAll ? "\nand " : "\nor ")
        if p.limit > 0 { s += "\nlimit \(p.limit), \(p.order.label.lowercased())" } else { s += "\norder: \(p.order.label.lowercased())" }
        return s
    }
}

struct DescribePlaylistView: View {
    let store: SmartPlaylistStore
    @Binding var isPresented: Bool
    let added: (SmartPlaylist) -> Void
    @State private var text = ""
    @State private var result: SmartPlaylist?
    @State private var count = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "apple.intelligence").foregroundStyle(.tint)
                Text("Describe a Playlist").font(.headline)
            }
            TextField("e.g. calm acoustic songs from the 70s · energetic tracks for running · brani tristi ma ballabili", text: $text, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
                .onSubmit(generate)
            if busy { ProgressView("Writing the rules…").controlSize(.small) }
            if let e = error ?? (AI.languageModelAvailable ? nil : AI.unavailableReason) { Text(e).foregroundStyle(.red).font(.callout) }
            if let p = result {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.name).font(.title3.bold())
                        Text(SmartPlaylistAI.describe(p)).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(count == 0 ? "No tracks match yet." : "\(count) tracks match.").font(.callout)
                        if p.rules.contains(where: { $0.field.sonic }) {
                            Text("Uses Sonic Mix analysis (BPM, key, mood or instruments): tracks not analysed yet are analysed when the playlist opens.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Text("Made on this Mac with Apple Intelligence. You can edit the rules afterwards.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                if let p = result {
                    Button("Try Again", action: generate).disabled(busy)
                    Button("Add Playlist") { store.playlists.append(p); added(p); isPresented = false }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Create", action: generate).keyboardShortcut(.defaultAction)
                        .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty || !AI.languageModelAvailable)
                }
            }
        }
        .padding(16)
        .frame(width: 560)
    }

    private func generate() {
        let d = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task { @MainActor in
            do {
                let pool = SmartPlaylistStore.pool()
                let p = try await SmartPlaylistAI.generate(d, pool: pool)
                result = p
                count = p.evaluate(pool).count
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
