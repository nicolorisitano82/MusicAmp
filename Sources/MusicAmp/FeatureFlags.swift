import Foundation

/// Features built but not released yet. Off by default; turned on per Mac with
/// `defaults write com.genomeup.musicamp feature.<name> -bool YES` (then restart MusicAmp).
enum FeatureFlags {
    /// Music app / Spotify as the source (Controls → Source): AppleScript control and process-tap capture.
    static var bridge: Bool { UserDefaults.standard.bool(forKey: "feature.bridge") }
    /// Live Video: pictures made on this Mac from the song (storyboard by Apple Intelligence, Stable Diffusion),
    /// its window, settings, the TV version and the storyboard export.
    static var liveVideo: Bool { UserDefaults.standard.bool(forKey: "feature.liveVideo") }
}
