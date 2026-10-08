import AppIntents
import AppKit

// Shortcuts actions (and Siri / Spotlight phrases). The intents run inside MusicAmp; when it isn't running
// macOS launches it first. Their metadata (Metadata.appintents) is extracted at build time by build-app.sh.

/// Waits for `Ctl.start()` when MusicAmp was launched to run the intent.
@MainActor
private func readyCtl() async -> Ctl {
    let c = Ctl.shared
    for _ in 0..<100 where !c.started { try? await Task.sleep(nanoseconds: 50_000_000) }
    return c
}

@MainActor
private func nowPlayingText(_ c: Ctl) -> String {
    guard let t = c.playlist.currentTrack else { return "Nothing is playing." }
    if t.isStream { return [t.title, t.streamTitle].compactMap { $0 }.joined(separator: " — ") }
    return [t.artist, t.songTitle ?? t.title].compactMap { $0 }.joined(separator: " — ")
}

struct PlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play"
    static var description = IntentDescription("Starts or resumes playback in MusicAmp.")
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        if c.audio.state != .playing { c.play() }
        return .result()
    }
}

struct PauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause"
    static var description = IntentDescription("Pauses MusicAmp.")
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        if c.audio.state == .playing { c.pause() }
        return .result()
    }
}

struct PlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var description = IntentDescription("Pauses MusicAmp if it's playing, otherwise plays.")
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        if c.audio.state == .playing { c.pause() } else { c.play() }
        return .result()
    }
}

struct StopIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop"
    static var description = IntentDescription("Stops playback.")
    @MainActor func perform() async throws -> some IntentResult {
        (await readyCtl()).stop()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description = IntentDescription("Skips to the next track of the playlist.")
    @MainActor func perform() async throws -> some IntentResult {
        (await readyCtl()).next()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description = IntentDescription("Goes back to the previous track of the playlist.")
    @MainActor func perform() async throws -> some IntentResult {
        (await readyCtl()).previous()
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Volume"
    static var description = IntentDescription("Sets MusicAmp's volume (0–100).")
    @Parameter(title: "Volume", default: 50, inclusiveRange: (0, 100)) var level: Int
    static var parameterSummary: some ParameterSummary { Summary("Set MusicAmp volume to \(\.$level)") }
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        c.volume = Double(level)
        c.mainView.needsDisplay = true
        return .result()
    }
}

struct SetShuffleIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Shuffle"
    static var description = IntentDescription("Turns shuffle on or off.")
    @Parameter(title: "Shuffle", default: true) var on: Bool
    static var parameterSummary: some ParameterSummary { Summary("Turn shuffle \(\.$on)") }
    @MainActor func perform() async throws -> some IntentResult {
        (await readyCtl()).shuffle = on
        return .result()
    }
}

struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Current Track"
    static var description = IntentDescription("Returns what MusicAmp is playing as “Artist — Title”.")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = nowPlayingText(await readyCtl())
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

struct PlayFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Files"
    static var description = IntentDescription("Replaces the playlist with audio files, folders, playlists or cue sheets and plays them.")
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Add to Playlist Instead", default: false) var append: Bool
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$files) in MusicAmp") { \.$append } }
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else { throw MusicAmpIntentError.message("Those files can't be opened.") }
        c.handleDrop(urls, toPlaylist: append)
        return .result()
    }
}

struct PlayURLIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Stream URL"
    static var description = IntentDescription("Plays an internet radio stream, an HLS station or a remote audio file.")
    @Parameter(title: "URL") var url: URL
    @Parameter(title: "Name") var name: String?
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$url) in MusicAmp") { \.$name } }
    @MainActor func perform() async throws -> some IntentResult {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MusicAmpIntentError.message("Only http and https streams can be played.") }
        (await readyCtl()).addStream(url, title: name, play: true)
        return .result()
    }
}

struct PlaySearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Search and Play"
    static var description = IntentDescription("Plays the first playlist track whose title, artist, album or file name contains all the words.")
    @Parameter(title: "Search") var query: String
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$query) from the MusicAmp playlist") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let c = await readyCtl()
        let words = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).split(separator: " ")
        let i = c.playlist.tracks.firstIndex { t in
            let hay = [t.title, t.songTitle, t.artist, t.album, t.url.lastPathComponent].compactMap { $0 }.joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            return words.allSatisfy { hay.contains($0) }
        }
        guard let i else { throw MusicAmpIntentError.message("Nothing in the playlist matches “\(query)”.") }
        c.playIndex(i)
        let t = c.playlist.tracks[i]
        return .result(value: [t.artist, t.songTitle ?? t.title].compactMap { $0 }.joined(separator: " — "))
    }
}

struct SleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Stops MusicAmp after some minutes, fading out. 0 turns the timer off.")
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (0, 720)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Stop MusicAmp in \(\.$minutes) minutes") }
    @MainActor func perform() async throws -> some IntentResult {
        _ = await readyCtl()
        if minutes > 0 { Scheduler.shared.startSleep(minutes: Double(minutes)) } else { Scheduler.shared.cancelSleep() }
        return .result()
    }
}

struct SleepAtEndOfTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop at End of Track"
    static var description = IntentDescription("Stops MusicAmp when the current track ends.")
    @MainActor func perform() async throws -> some IntentResult {
        _ = await readyCtl()
        Scheduler.shared.sleepAtEndOfTrack()
        return .result()
    }
}

struct SetAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Alarm"
    static var description = IntentDescription("Wakes you with music at a time of day (once, or keeping the days set in Settings → Timer).")
    @Parameter(title: "Time") var time: Date
    @Parameter(title: "Only Once", default: false) var once: Bool
    static var parameterSummary: some ParameterSummary { Summary("Wake me with MusicAmp at \(\.$time)") { \.$once } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        _ = await readyCtl()
        let s = Scheduler.shared
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        s.alarmHour = c.hour ?? 7
        s.alarmMinute = c.minute ?? 0
        if once { s.alarmDays = [] }
        s.alarmOn = true
        return .result(value: s.nextAlarm.map(Scheduler.describe) ?? "")
    }
}

struct TurnOffAlarmIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off Alarm"
    static var description = IntentDescription("Turns the alarm off (and stops it if it's ringing).")
    @MainActor func perform() async throws -> some IntentResult {
        _ = await readyCtl()
        Scheduler.shared.stopAlarm()
        Scheduler.shared.alarmOn = false
        return .result()
    }
}

struct RateTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Rate Current Track"
    static var description = IntentDescription("Gives the playing track 1–5 stars (0 clears the rating).")
    @Parameter(title: "Stars", default: 5, inclusiveRange: (0, 5)) var stars: Int
    static var parameterSummary: some ParameterSummary { Summary("Rate the current track \(\.$stars) stars") }
    @MainActor func perform() async throws -> some IntentResult {
        let c = await readyCtl()
        guard let t = c.playlist.currentTrack, PlayStats.key(t.url) != nil else { throw MusicAmpIntentError.message("No local track is playing.") }
        PlayStats.shared.setRating(t.url, stars)
        c.playlist.touch()
        return .result()
    }
}

/// A smart playlist, for the "Play Smart Playlist" action's picker.
struct SmartPlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Smart Playlist"
    static var defaultQuery = SmartPlaylistQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SmartPlaylistQuery: EntityQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SmartPlaylistEntity] {
        SmartPlaylistStore.shared.playlists.filter { identifiers.contains($0.id) }.map { SmartPlaylistEntity(id: $0.id, name: $0.name) }
    }
    @MainActor func suggestedEntities() async throws -> [SmartPlaylistEntity] {
        SmartPlaylistStore.shared.playlists.map { SmartPlaylistEntity(id: $0.id, name: $0.name) }
    }
}

struct PlaySmartPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Smart Playlist"
    static var description = IntentDescription("Replaces the playlist with a smart playlist and plays it.")
    @Parameter(title: "Smart Playlist") var playlist: SmartPlaylistEntity
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$playlist) in MusicAmp") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        _ = await readyCtl()
        guard let p = SmartPlaylistStore.shared.playlists.first(where: { $0.id == playlist.id }) else {
            throw MusicAmpIntentError.message("That smart playlist no longer exists.")
        }
        let n = SmartPlaylistStore.shared.play(p)
        if n == 0 { throw MusicAmpIntentError.message("“\(p.name)” is empty.") }
        return .result(value: n)
    }
}

struct PlaySonicRadioIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Sonic Radio"
    static var description = IntentDescription("Plays a mix of tracks that sound like the current one (timbre, tempo, key, energy). Tracks not analysed yet are analysed first.")
    @Parameter(title: "Tracks", default: 25, inclusiveRange: (5, 100)) var count: Int
    static var parameterSummary: some ParameterSummary { Summary("Play \(\.$count) tracks that sound like the current one") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let c = await readyCtl()
        guard let t = c.playlist.currentTrack, !t.isStream else { throw MusicAmpIntentError.message("Play a local track first.") }
        let model = SonicMixModel.shared
        let items = model.pool
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in SonicStore.shared.analyze(items.map(\.url)) { k.resume() } }
        let space = SonicSpace(items: items)
        guard let seed = space.track(t.url) else { throw MusicAmpIntentError.message("This track can't be analysed.") }
        let urls = space.radio(from: seed, count: count).map(\.item.url)
        guard urls.count > 1 else { throw MusicAmpIntentError.message("Not enough analysed tracks for a mix.") }
        c.startMix(urls, title: "Sonic Radio")   // the current track keeps playing; the mix follows it
        return .result(value: urls.count)
    }
}

enum MusicAmpIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)
    var localizedStringResource: LocalizedStringResource {
        switch self { case .message(let m): return LocalizedStringResource(stringLiteral: m) }
    }
}

/// Ready-made shortcuts: they show up in Shortcuts and Spotlight without any setup, and Siri understands the phrases.
struct MusicAmpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Play or pause \(.applicationName)", "Pause \(.applicationName)"],
                    shortTitle: "Play/Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Next track in \(.applicationName)", "Skip in \(.applicationName)"],
                    shortTitle: "Next Track", systemImageName: "forward.fill")
        AppShortcut(intent: NowPlayingIntent(), phrases: ["What's playing in \(.applicationName)"],
                    shortTitle: "Current Track", systemImageName: "music.note")
        AppShortcut(intent: SleepTimerIntent(), phrases: ["Set a \(.applicationName) sleep timer", "\(.applicationName) sleep timer"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz.fill")
        AppShortcut(intent: SetAlarmIntent(), phrases: ["Set a \(.applicationName) alarm"],
                    shortTitle: "Alarm", systemImageName: "alarm.fill")
        AppShortcut(intent: PlaySonicRadioIntent(), phrases: ["Play something like this in \(.applicationName)", "Start \(.applicationName) sonic radio"],
                    shortTitle: "Sonic Radio", systemImageName: "waveform.circle.fill")
        AppShortcut(intent: PlaySmartPlaylistIntent(), phrases: ["Play \(\.$playlist) in \(.applicationName)", "Play a smart playlist in \(.applicationName)"],
                    shortTitle: "Smart Playlist", systemImageName: "gearshape.2.fill")
    }
}
