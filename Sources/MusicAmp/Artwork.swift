import AppKit
import AVFoundation

/// Cover art read from file metadata, cached per URL (Now Playing, notifications, menu bar player).
enum Artwork {
    private static var cache: [URL: NSImage] = [:]
    private static var misses = Set<URL>()

    static func cached(_ url: URL) -> NSImage? { cache[url] }

    @MainActor
    static func load(_ url: URL) async -> NSImage? {
        if let img = cache[url] { return img }
        if misses.contains(url) { return nil }
        // Podcast episodes: the episode image or the show's cover from the feed.
        if let (feed, ep) = PodcastStore.shared.lookup(url),
           let art = URL(string: ep.imageURL ?? feed.artworkURL ?? ""),
           let (data, _) = try? await URLSession.shared.data(from: art), let img = NSImage(data: data) {
            cache[url] = img
            return img
        }
        if !url.isFileURL { misses.insert(url); return nil }   // never pull metadata of a remote stream
        let md = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
        for item in md where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let img = NSImage(data: data) {
                if cache.count > 32 { cache.removeAll() }
                cache[url] = img
                return img
            }
        }
        misses.insert(url)
        return nil
    }
}
