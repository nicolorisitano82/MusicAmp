import Foundation

/// Features built but not released yet. Off by default; turned on per Mac with
/// `defaults write com.genomeup.musicamp feature.<name> -bool YES` (then restart MusicAmp).
enum FeatureFlags {
    /// Music app / Spotify as the source (Controls → Source): AppleScript control and process-tap capture.
    static var bridge: Bool { UserDefaults.standard.bool(forKey: "feature.bridge") }
}
