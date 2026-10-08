import AppIntents
import MusicAmpShared
import SwiftUI
import WidgetKit

// "Now Playing" widget for the desktop and Notification Center. It reads the state MusicAmp writes to
// ~/Library/Application Support/MusicAmp/Widget (the only folder its sandbox may read) and drives the player
// by posting distributed notifications; a tap on the widget opens MusicAmp.

@main
struct MusicAmpWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        MiniTileWidget()
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.kind, provider: Provider()) { entry in
            NowPlayingView(entry: entry)
                .containerBackground(for: .widget) { Theme.background }
                .widgetURL(MusicAmpCommand.open.url)
        }
        .configurationDisplayName("Now Playing")
        .description("The track MusicAmp is playing, with playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: Timeline

struct Entry: TimelineEntry {
    let date: Date
    let state: WidgetState
    let artwork: NSImage?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), state: .sample, artwork: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let e = current()
        completion(context.isPreview && !e.state.hasTrack ? Entry(date: Date(), state: .sample, artwork: nil) : e)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let e = current()
        // MusicAmp reloads the widget on every change; refresh anyway when the track should be over.
        let s = e.state
        let end = s.playing && s.duration > 0 ? s.updated.addingTimeInterval(s.duration - s.elapsed + 1) : nil
        completion(Timeline(entries: [e], policy: end.map { .after($0) } ?? .never))
    }

    private func current() -> Entry {
        let s = WidgetShared.readState() ?? WidgetState()
        let art = s.artwork.flatMap { NSImage(contentsOf: WidgetShared.folder.appendingPathComponent($0)) }
        return Entry(date: Date(), state: s, artwork: art)
    }
}

extension WidgetState {
    static var sample: WidgetState {
        var s = WidgetState()
        s.running = true
        s.hasTrack = true
        s.title = "Llama Whippin' Intro"
        s.artist = "DJ Mike Llama"
        s.album = "Winamp"
        s.playing = true
        s.duration = 5
        return s
    }
}

// MARK: Buttons (run in the extension, act in MusicAmp)

private func post(_ c: MusicAmpCommand) {
    DistributedNotificationCenter.default().postNotificationName(c.notificationName, object: nil, userInfo: nil, deliverImmediately: true)
}

struct WidgetPlayPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Play/Pause"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { post(.playPause); return .result() }
}

struct WidgetNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { post(.next); return .result() }
}

struct WidgetPreviousIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult { post(.previous); return .result() }
}

// MARK: Views

enum Theme {
    /// Winamp's display green, on a dark brushed panel.
    static let lcd = Color(red: 0.0, green: 0.86, blue: 0.0)
    static let dim = Color(red: 0.55, green: 0.62, blue: 0.55)
    static let background = LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.08)],
                                           startPoint: .top, endPoint: .bottom)
}

struct NowPlayingView: View {
    let entry: Entry
    /// Debug renders outside WidgetKit (the environment value can't be set there).
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var envFamily
    private var family: WidgetFamily { familyOverride ?? envFamily }
    private var s: WidgetState { entry.state }

    var body: some View {
        // Closed, MusicAmp still shows its last track: the buttons launch it hidden in the Dock.
        if !s.hasTrack {
            idle
        } else {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    // Not running, or nothing loaded.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer()
            Text(s.running ? "Nothing playing" : "MusicAmp isn't running").font(.headline).foregroundStyle(.white)
            Text(s.running ? "Add music to the playlist." : "Click to open it.").font(.caption).foregroundStyle(Theme.dim)
            Spacer()
            if s.running { controls(size: 15) } else {
                Link(destination: MusicAmpCommand.play.launchURL) {
                    Label("Play", systemImage: "play.fill").font(.caption.bold())
                }
                .foregroundStyle(Theme.lcd)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                cover(56)
                Spacer()
                playPause(size: 20)
            }
            Spacer(minLength: 2)
            Text(s.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            if let a = s.artist { Text(a).font(.caption).foregroundStyle(Theme.dim).lineLimit(1) }
            progress.padding(.top, 2)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            cover(118)
            VStack(alignment: .leading, spacing: 3) {
                header
                Text(s.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                if let a = s.artist { Text(a).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(1) }
                if let al = s.album { Text(al).font(.caption).foregroundStyle(Theme.dim.opacity(0.8)).lineLimit(1) }
                Spacer(minLength: 2)
                progress
                controls(size: 15)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack {
                Spacer()
                cover(190)
                Spacer()
            }
            Text(s.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
            Text([s.artist, s.album].compactMap { $0 }.joined(separator: " — ")).font(.subheadline).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 0)
            progress
            controls(size: 19)
        }
    }

    /// "MUSICAMP ▶" plus the sleep timer / alarm when set.
    private var header: some View {
        HStack(spacing: 6) {
            Text("MUSICAMP").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.lcd).tracking(1)
            if s.hasTrack {
                Image(systemName: s.playing ? "play.fill" : (s.paused ? "pause.fill" : "stop.fill"))
                    .font(.system(size: 7)).foregroundStyle(Theme.lcd)
            }
            Spacer(minLength: 0)
            if let d = s.sleepAt, d > entry.date {
                Label { Text(d, style: .timer).monospacedDigit() } icon: { Image(systemName: "moon.zzz.fill") }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.dim)
            } else if s.sleepEndOfTrack {
                Image(systemName: "moon.zzz.fill").font(.system(size: 9)).foregroundStyle(Theme.dim)
            }
            if s.ringing {
                Image(systemName: "alarm.waves.left.and.right.fill").font(.system(size: 9)).foregroundStyle(Theme.lcd)
            } else if let a = s.alarm {
                Label { Text(a, style: .time) } icon: { Image(systemName: "alarm.fill") }
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.dim)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder private func cover(_ side: CGFloat) -> some View {
        Group {
            if let img = entry.artwork {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.22), Color(white: 0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: s.isStream ? "dot.radiowaves.left.and.right" : "music.note")
                        .font(.system(size: side * 0.36)).foregroundStyle(Theme.lcd.opacity(0.7))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.08))
        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
    }

    /// Elapsed time and progress; the clock runs on its own while playing. Live radio shows "LIVE".
    @ViewBuilder private var progress: some View {
        if s.isStream {
            Text("● LIVE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.lcd)
        } else if s.duration > 0 {
            let start = s.updated.addingTimeInterval(-s.elapsed)
            let end = start.addingTimeInterval(s.duration)
            VStack(spacing: 2) {
                if s.playing, end > entry.date {
                    ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .progressViewStyle(.linear).tint(Theme.lcd)
                } else {
                    ProgressView(value: min(1, max(0, s.elapsed / s.duration))).progressViewStyle(.linear).tint(Theme.lcd)
                }
                if family != .systemSmall {
                    HStack {
                        if s.playing, end > entry.date {
                            Text(timerInterval: start...end, countsDown: false).monospacedDigit()
                        } else {
                            Text(Self.mmss(s.elapsed)).monospacedDigit()
                        }
                        Spacer()
                        Text(Self.mmss(s.duration)).monospacedDigit()
                    }
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private func controls(size: CGFloat) -> some View {
        HStack(spacing: size * 1.4) {
            command(.previous, WidgetPreviousIntent()) { Image(systemName: "backward.fill") }
            playPause(size: size * 1.25)
            command(.next, WidgetNextIntent()) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.system(size: size))
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    private func playPause(size: CGFloat) -> some View {
        command(.playPause, WidgetPlayPauseIntent()) {
            Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.lcd)
        }
        .buttonStyle(.plain)
    }

    /// Running: the intent (no launch, no focus change). Closed: a link that starts MusicAmp hidden in the Dock.
    @ViewBuilder private func command<I: AppIntent, L: View>(_ c: MusicAmpCommand, _ intent: I, @ViewBuilder label: () -> L) -> some View {
        if s.running {
            Button(intent: intent, label: label)
        } else {
            Link(destination: (c == .playPause ? MusicAmpCommand.play : c).launchURL, label: label)
        }
    }

    static func mmss(_ t: Double) -> String {
        let t = max(0, Int(t))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Mini Tile widget

/// The mini tile as a widget: the cover edge to edge, the waveform green up to the playhead, a play sign when
/// paused; a tap anywhere plays or pauses. The progress moves through timeline entries every 5 seconds.
struct MiniTileWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetShared.tileKind, provider: TileProvider()) { entry in
            MiniTileView(entry: entry)
                .containerBackground(for: .widget) { MiniTileView.background(entry) }
        }
        .configurationDisplayName("Mini Tile")
        .description("The cover and the waveform of what MusicAmp is playing. Tap to play or pause.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

struct TileProvider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), state: .sample, artwork: nil) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        let s = WidgetShared.readState() ?? WidgetState()
        completion(context.isPreview && !s.hasTrack ? Entry(date: Date(), state: .sample, artwork: nil) : entry(s, Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let s = WidgetShared.readState() ?? WidgetState()
        let now = Date()
        guard s.playing, s.duration > 0, !s.isStream else {
            completion(Timeline(entries: [entry(s, now)], policy: .never))
            return
        }
        // An entry every 5 s until the track ends (at most 10 minutes); MusicAmp reloads on every change anyway.
        let left = max(0, s.duration - s.elapsed - now.timeIntervalSince(s.updated))
        let count = min(120, Int(left / 5) + 1)
        let entries = (0..<count).map { entry(s, now.addingTimeInterval(Double($0) * 5)) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(min(left, 600) + 1))))
    }

    private func entry(_ s: WidgetState, _ d: Date) -> Entry {
        Entry(date: d, state: s, artwork: s.artwork.flatMap { NSImage(contentsOf: WidgetShared.folder.appendingPathComponent($0)) })
    }
}

struct MiniTileView: View {
    let entry: Entry
    private var s: WidgetState { entry.state }

    /// Seconds into the track at this entry's time.
    private var progress: Double {
        guard s.duration > 0 else { return 0 }
        let t = s.elapsed + (s.playing ? entry.date.timeIntervalSince(s.updated) : 0)
        return min(1, max(0, t / s.duration))
    }

    @ViewBuilder static func background(_ entry: Entry) -> some View {
        if let img = entry.artwork {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Theme.background
                Image(systemName: entry.state.isStream ? "dot.radiowaves.left.and.right" : "music.note")
                    .font(.system(size: 48)).foregroundStyle(Theme.lcd.opacity(0.6))
            }
        }
    }

    var body: some View {
        if s.running {
            Button(intent: WidgetPlayPauseIntent()) { tile }.buttonStyle(.plain)
        } else {
            // Closed: a tap launches MusicAmp hidden in the Dock and plays the last track.
            Link(destination: MusicAmpCommand.play.launchURL) { tile }
        }
    }

    private var tile: some View {
            ZStack {
                if !s.hasTrack {
                    Color.black.opacity(0.4)
                    Text(s.running ? "Nothing playing" : "MusicAmp isn't running").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    VStack(spacing: 0) {
                        Spacer()
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                            strip.padding(.horizontal, 12).padding(.bottom, 12)
                        }
                    }
                    if !s.playing {
                        Color.black.opacity(0.3)
                        Image(systemName: "play.fill").font(.system(size: 40, weight: .bold)).foregroundStyle(.white.opacity(0.92))
                            .shadow(radius: 4).offset(y: -12)
                    }
                }
            }
    }

    @ViewBuilder private var strip: some View {
        if s.isStream {
            HStack {
                Text("● LIVE").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.lcd)
                Spacer()
            }
        } else if let w = s.waveform, !w.isEmpty {
            GeometryReader { g in
                HStack(alignment: .center, spacing: 1) {
                    ForEach(0..<w.count, id: \.self) { i in
                        let played = Double(i) / Double(w.count) < progress
                        RoundedRectangle(cornerRadius: 1)
                            .fill(played ? Theme.lcd : Color.white.opacity(0.5))
                            .frame(height: max(2, CGFloat(w[i]) * g.size.height))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 26)
        } else {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(Theme.lcd).frame(width: g.size.width * progress)
                }
            }
            .frame(height: 4)
        }
    }
}
