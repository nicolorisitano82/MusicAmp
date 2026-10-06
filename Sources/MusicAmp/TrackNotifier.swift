import AppKit
import UserNotifications

/// Posts a notification (title, artist · album, cover) when a new track starts playing.
final class TrackNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let ctl: Ctl
    private var lastTrack: Track?
    private var authorized: Bool?

    init(ctl: Ctl) {
        self.ctl = ctl
        super.init()
        // UNUserNotificationCenter needs a bundled app; an unbundled debug binary would crash here.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Called on every transport change; notifies once per track when it is actually playing.
    func transportChanged() {
        guard let t = ctl.playlist.currentTrack, ctl.audio.state == .playing, t !== lastTrack else { return }
        lastTrack = t
        guard ctl.notifyTrackChange, Bundle.main.bundleIdentifier != nil else { return }
        if ctl.notifyOnlyInBackground, NSApp.isActive { return }
        withAuthorization { self.post(t) }
    }

    private func withAuthorization(_ then: @escaping () -> Void) {
        if authorized == true { then(); return }
        if authorized == false { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { ok, _ in
            DispatchQueue.main.async {
                self.authorized = ok
                if ok { then() }
            }
        }
    }

    private func post(_ t: Track) {
        Task { @MainActor in
            let c = UNMutableNotificationContent()
            c.title = t.songTitle ?? t.title
            c.body = [t.artist, t.album].compactMap { $0 }.joined(separator: " · ")
            if c.body.isEmpty, let d = t.duration { c.body = Ctl.mmss(d) }
            c.threadIdentifier = "musicamp.track"
            if let img = await Artwork.load(t.url), let file = Self.writePNG(img) {
                if let att = try? UNNotificationAttachment(identifier: "cover", url: file) { c.attachments = [att] }
            }
            let center = UNUserNotificationCenter.current()
            center.removeAllDeliveredNotifications()
            try? await center.add(UNNotificationRequest(identifier: "musicamp.track", content: c, trigger: nil))
        }
    }

    private static func writePNG(_ img: NSImage) -> URL? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-cover-\(UUID().uuidString).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(ctl.notifyOnlyInBackground ? [] : [.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        ctl.mainWindow?.makeKeyAndOrderFront(nil)
        completionHandler()
    }
}
