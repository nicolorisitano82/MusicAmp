import AppKit
import AVFoundation
import MediaPlayer

/// Media keys / AirPods / Control Center via MPRemoteCommandCenter, and the "Now Playing" widget.
/// The system extrapolates elapsed time from the playback rate, so updates happen only on transport changes.
final class NowPlaying {
    private let ctl: Ctl
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    init(ctl: Ctl) {
        self.ctl = ctl
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            guard let c = self?.ctl else { return .commandFailed }
            if c.audio.state != .playing { c.play() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let c = self?.ctl else { return .commandFailed }
            if c.audio.state == .playing { c.pause() }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let c = self?.ctl else { return .commandFailed }
            if c.audio.state == .stopped { c.play() } else { c.pause() }
            return .success
        }
        cc.stopCommand.addTarget { [weak self] _ in
            self?.ctl.stop()
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let c = self?.ctl, !c.playlist.tracks.isEmpty else { return .noSuchContent }
            c.next()
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let c = self?.ctl, !c.playlist.tracks.isEmpty else { return .noSuchContent }
            c.previous()
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let c = self?.ctl, let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            c.audio.seek(to: e.positionTime)
            return .success
        }
        cc.skipForwardCommand.isEnabled = false
        cc.skipBackwardCommand.isEnabled = false
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        let a = ctl.audio
        guard let i = ctl.playlist.current, a.file != nil else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let t = ctl.playlist.tracks[i]
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.songTitle ?? t.title,
            MPMediaItemPropertyPlaybackDuration: a.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: a.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: a.state == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: i,
            MPNowPlayingInfoPropertyPlaybackQueueCount: ctl.playlist.tracks.count,
        ]
        if let artist = t.artist { info[MPMediaItemPropertyArtist] = artist }
        if let album = t.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if artworkURL == t.url, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        switch a.state {
        case .playing: center.playbackState = .playing
        case .paused: center.playbackState = .paused
        case .stopped: center.playbackState = .stopped
        }
        if artworkURL != t.url { loadArtwork(t.url) }
    }

    private func loadArtwork(_ url: URL) {
        artworkURL = url
        artwork = nil
        Task {
            let md = (try? await AVURLAsset(url: url).load(.commonMetadata)) ?? []
            var data: Data?
            for item in md where item.commonKey == .commonKeyArtwork {
                data = try? await item.load(.dataValue)
                if data != nil { break }
            }
            await MainActor.run { [data] in
                guard self.artworkURL == url, let data, let img = NSImage(data: data) else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                self.update()
            }
        }
    }
}
