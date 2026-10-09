import CryptoKit
import SwiftUI
import Translation

/// Lyrics translated line by line on this Mac (Apple's Translation framework), shown under each line in the lyrics
/// panel and the karaoke. The song's language is detected; the target is chosen in the panel (default: the app's
/// language). Language packs are downloaded by the system when needed (it asks). Translations are cached on disk.
@MainActor
final class LyricsTranslator: ObservableObject {
    static let shared = LyricsTranslator()

    @Published var enabled = UserDefaults.standard.bool(forKey: "lyrics.translate") {
        didSet { UserDefaults.standard.set(enabled, forKey: "lyrics.translate"); if enabled, let l = current { request(l) } }
    }
    /// Target language code ("it", "en"…).
    @Published var target = UserDefaults.standard.string(forKey: "lyrics.translateTo") ?? LyricsTranslator.defaultTarget {
        didSet { UserDefaults.standard.set(target, forKey: "lyrics.translateTo"); translations = [:]; if let l = current { request(l) } }
    }
    /// Line text → translation, for the lyrics being shown.
    @Published private(set) var translations: [String: String] = [:]
    /// Set to start a translation; `.translationTask` in the views runs it.
    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var busy = false
    @Published private(set) var note: String?

    nonisolated static let targets: [(String, String)] = [("it", "Italiano"), ("en", "English"), ("es", "Español"), ("fr", "Français"),
                                              ("de", "Deutsch"), ("pt", "Português"), ("ja", "日本語"), ("ko", "한국어"), ("zh", "中文")]

    static var defaultTarget: String {
        let app = AppLanguage.current
        return app == "system" ? (Locale.current.language.languageCode?.identifier ?? "en") : app
    }

    private var current: Lyrics?
    private var pending: [String] = []
    private var cacheKey = ""

    static var folder: URL {
        let u = PlayStats.file.deletingLastPathComponent().appendingPathComponent("Lyrics/Translations", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// The lyrics on screen changed (or translation was turned on): translate what isn't cached.
    func request(_ l: Lyrics?) {
        guard l != current || translations.isEmpty else { return }
        current = l
        note = nil
        guard enabled, let l else { translations = [:]; return }
        let lines = Array(Set((l.synced?.map(\.text) ?? (l.plain ?? "").components(separatedBy: .newlines))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
        guard !lines.isEmpty else { translations = [:]; return }
        let joined = lines.joined(separator: "\n")
        guard let source = AI.language(of: joined)?.language else { note = "Couldn't tell the song's language."; return }
        if source.languageCode?.identifier == target {
            translations = [:]
            note = "The lyrics are already in this language."
            return
        }
        cacheKey = SHA256.hash(data: Data((target + "|" + joined).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let file = Self.folder.appendingPathComponent(cacheKey + ".json")
        if let d = try? Data(contentsOf: file), let t = try? JSONDecoder().decode([String: String].self, from: d) {
            translations = t
            return
        }
        translations = [:]
        pending = lines
        busy = true
        let cfg = TranslationSession.Configuration(source: source, target: Locale.Language(identifier: target))
        if configuration == cfg { configuration?.invalidate() } else { configuration = cfg }
    }

    /// Runs inside `.translationTask` (which can ask to download the language).
    func run(_ session: TranslationSession) async {
        let lines = pending
        guard !lines.isEmpty else { busy = false; return }
        do {
            let responses = try await session.translations(from: lines.map { TranslationSession.Request(sourceText: $0) })
            var out: [String: String] = [:]
            for r in responses { out[r.sourceText] = r.targetText }
            translations = out
            if let d = try? JSONEncoder().encode(out) { try? d.write(to: Self.folder.appendingPathComponent(cacheKey + ".json"), options: .atomic) }
        } catch {
            note = "Translation unavailable: \(error.localizedDescription)"
        }
        pending = []
        busy = false
    }

    func translation(_ line: String) -> String? {
        guard enabled else { return nil }
        let t = translations[line.trimmingCharacters(in: .whitespaces)]
        return t == line ? nil : t
    }
}

/// Toolbar control: on/off and the target language.
struct TranslateMenu: View {
    @ObservedObject var translator = LyricsTranslator.shared

    var body: some View {
        Menu {
            Toggle("Show Translation", isOn: $translator.enabled)
            Picker("Translate To", selection: $translator.target) {
                ForEach(LyricsTranslator.targets, id: \.0) { Text($0.1).tag($0.0) }
            }
            if let n = translator.note { Text(n) }
        } label: {
            Image(systemName: translator.busy ? "ellipsis" : "translate")
                .foregroundStyle(translator.enabled ? Color.accentColor : .white.opacity(0.85))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28)
        .help("Translate the lyrics (on this Mac)")
    }
}
