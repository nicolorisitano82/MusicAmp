import Foundation

/// What MusicAmp and its widget extension share: the commands the widget (and `musicamp://` URLs) send,
/// and the now-playing state the app writes for the widget to read.
public enum MusicAmpCommand: String, CaseIterable, Sendable {
    case play, pause, playPause = "playpause", next, previous, stop, open

    /// Posted by the widget's buttons (a sandboxed extension can post distributed notifications, names only).
    public var notificationName: Notification.Name { Notification.Name("com.genomeup.musicamp.command." + rawValue) }
    public var url: URL { URL(string: "musicamp://" + rawValue)! }
}

public struct WidgetState: Codable, Equatable, Sendable {
    public var running = false
    public var hasTrack = false
    public var title = ""
    public var artist: String?
    public var album: String?
    public var isStream = false
    public var playing = false
    public var paused = false
    /// Seconds into the track at `updated`; the widget extrapolates while playing.
    public var elapsed: Double = 0
    public var duration: Double = 0
    public var updated = Date()
    /// Artwork file name inside the widget folder (changes with the track, so the widget never shows a stale one).
    public var artwork: String?
    public var sleepAt: Date?
    public var sleepEndOfTrack = false
    public var alarm: Date?
    public var ringing = false

    public init() {}

    /// Same content apart from the clock (elapsed time moves on its own).
    public func sameContent(as o: WidgetState) -> Bool {
        var a = self, b = o
        a.updated = .distantPast; b.updated = .distantPast
        a.elapsed = 0; b.elapsed = 0
        return a == b && abs(elapsed - o.elapsed - (playing ? updated.timeIntervalSince(o.updated) : 0)) < 2
    }
}

public enum WidgetShared {
    public static let kind = "MusicAmpNowPlaying"

    /// The real home folder, also from inside the widget's sandbox (where NSHomeDirectory() is the container).
    public static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Application Support/MusicAmp/Widget — the widget's entitlement allows reading only this folder.
    public static var folder: URL { realHome.appendingPathComponent("Library/Application Support/MusicAmp/Widget", isDirectory: true) }
    public static var stateFile: URL { folder.appendingPathComponent("state.json") }

    public static func readState() -> WidgetState? {
        guard let d = try? Data(contentsOf: stateFile) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetState.self, from: d)
    }

    public static func encode(_ s: WidgetState) -> Data? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(s)
    }
}
