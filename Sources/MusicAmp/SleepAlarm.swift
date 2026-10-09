import AppKit
import SwiftUI

/// Sleep timer (stop after some minutes or at the end of the track, fading out) and alarm (start playback at a
/// time of day, fading in). Fades scale the output through `Ctl.fadeScale`, never the volume setting itself.
/// The alarm needs MusicAmp running and the Mac awake: while it is armed MusicAmp keeps idle sleep away
/// (Settings → Timer, "Keep the Mac awake").
final class Scheduler: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = Scheduler()
    private weak var ctl: Ctl?

    // MARK: Sleep timer

    enum SleepMode: Equatable { case off, at(Date), endOfTrack }
    enum SleepAction: Int, CaseIterable, Identifiable {
        case pause, stop, quit, sleepMac
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .pause: return "Pause"
            case .stop: return "Stop"
            case .quit: return "Quit MusicAmp"
            case .sleepMac: return "Put the Mac to sleep"
            }
        }
    }
    static let sleepPresets = [5, 10, 15, 20, 30, 45, 60, 90, 120]

    @Published private(set) var sleep: SleepMode = .off
    @Published var sleepAction: SleepAction = .pause { didSet { save() } }
    @Published var fadeOut = true { didSet { save() } }
    @Published var fadeOutSeconds: Double = 30 { didSet { save() } }
    private var sleepTrack: Track?

    // MARK: Alarm

    @Published var alarmOn = false { didSet { rearm(); save() } }
    @Published var alarmHour = 7 { didSet { rearm(); save() } }
    @Published var alarmMinute = 30 { didSet { rearm(); save() } }
    /// Calendar weekdays (1 = Sunday … 7 = Saturday); empty = once, at the next occurrence.
    @Published var alarmDays: Set<Int> = [2, 3, 4, 5, 6] { didSet { rearm(); save() } }
    /// What to play: "" = the playlist from its current track, else a URL string (station, file, cue track).
    @Published var alarmSource = "" { didSet { save() } }
    @Published var alarmVolume: Double = 60 { didSet { save() } }
    @Published var alarmFadeIn: Double = 60 { didSet { save() } }
    @Published var keepAwake = true { didSet { updateActivity(); save() } }
    @Published private(set) var nextAlarm: Date?
    @Published private(set) var ringing = false

    /// Missed alarms (the Mac slept through them) still ring if MusicAmp notices within this window.
    static let lateWindow: TimeInterval = 10 * 60
    static let snoozeMinutes = 9

    private var snoozeUntil: Date?
    private var ringStarted: Date?
    private var fadeInStart: Date?
    private var beepTimer: Timer?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var loading = false

    // MARK: Start

    func start(ctl: Ctl) {
        self.ctl = ctl
        load()
        rearm()
        timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: Sleep timer actions

    func startSleep(minutes: Double) {
        sleep = .at(Date().addingTimeInterval(minutes * 60))
        restoreFade()
        updateActivity()
        ctl?.flashMarquee("SLEEP TIMER: \(Int(minutes.rounded())) MIN")
        changed()
    }

    func sleepAtEndOfTrack() {
        sleepTrack = ctl?.playlist.currentTrack
        sleep = .endOfTrack
        restoreFade()
        updateActivity()
        ctl?.flashMarquee("SLEEP AT END OF TRACK")
        changed()
    }

    func cancelSleep(announce: Bool = true) {
        guard sleep != .off else { return }
        sleep = .off
        sleepTrack = nil
        restoreFade()
        updateActivity()
        if announce { ctl?.flashMarquee("SLEEP TIMER OFF") }
        changed()
    }

    /// Seconds until the sleep timer fires (nil when off; for "end of track", the time left in the track).
    var sleepRemaining: Double? {
        switch sleep {
        case .off: return nil
        case .at(let d): return max(0, d.timeIntervalSinceNow)
        case .endOfTrack:
            guard let c = ctl, c.audio.hasSource, c.audio.duration > 0 else { return nil }
            return max(0, c.audio.duration - c.audio.currentTime)
        }
    }

    /// When the sleep timer fires, for countdowns (widget, menu).
    var sleepDate: Date? { sleepRemaining.map { Date().addingTimeInterval($0) } }

    /// Output scale during a fade-out of `fade` seconds with `remaining` seconds to go.
    static func fadeFactor(remaining: Double, fade: Double) -> Double {
        guard fade > 0 else { return remaining > 0 ? 1 : 0 }
        return max(0, min(1, remaining / fade))
    }

    // MARK: Alarm actions

    /// Next time the alarm rings after `date`: today or a later day at hour:minute, on one of `days` (any day when empty).
    static func nextOccurrence(hour: Int, minute: Int, days: Set<Int>, after date: Date, calendar: Calendar = .current) -> Date? {
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let t = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if t > date, days.isEmpty || days.contains(calendar.component(.weekday, from: t)) { return t }
        }
        return nil
    }

    private func rearm(after date: Date = Date()) {
        guard !loading else { return }
        nextAlarm = alarmOn ? Scheduler.nextOccurrence(hour: alarmHour, minute: alarmMinute, days: alarmDays, after: date) : nil
        updateActivity()
        changed()
    }

    func testAlarm() { ring() }

    func snooze() {
        guard ringing else { return }
        stopRinging(pause: true)
        snoozeUntil = Date().addingTimeInterval(Double(Scheduler.snoozeMinutes) * 60)
        ctl?.flashMarquee("SNOOZE \(Scheduler.snoozeMinutes) MIN")
        updateActivity()
        changed()
    }

    func stopAlarm() {
        snoozeUntil = nil
        stopRinging(pause: true)
        updateActivity()
        changed()
    }

    private func ring() {
        guard let c = ctl else { return }
        ringing = true
        ringStarted = Date()
        fadeInStart = Date()
        cancelSleep(announce: false)
        c.volume = alarmVolume
        c.fadeScale = alarmFadeIn > 0 ? 0 : 1
        if !startAlarmSource(c) {
            // Nothing to play: the system alert sound until stopped.
            c.fadeScale = 1
            beepTimer?.invalidate()
            beepTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in NSSound(named: "Glass")?.play() }
            NSSound(named: "Glass")?.play()
        }
        c.flashMarquee("ALARM \(String(format: "%02d:%02d", alarmHour, alarmMinute))", seconds: 5)
        NSApp.activate(ignoringOtherApps: true)
        c.mainWindow.orderFrontRegardless()
        changed()
    }

    /// Starts what the alarm plays; false when there is nothing (empty playlist, missing file).
    private func startAlarmSource(_ c: Ctl) -> Bool {
        if !alarmSource.isEmpty, let url = URL(string: alarmSource) {
            if let i = c.playlist.tracks.firstIndex(where: { $0.url.absoluteString == alarmSource }) {
                c.playIndex(i)
                return true
            }
            if url.isFileURL {
                guard FileManager.default.fileExists(atPath: CueSheet.audioURL(url).path) else { return fallbackPlaylist(c) }
                c.playlist.add([url])
                if let i = c.playlist.tracks.firstIndex(where: { $0.url == url }) { c.playIndex(i); return true }
                return fallbackPlaylist(c)
            }
            c.addStream(url, title: nil, play: true)
            return true
        }
        return fallbackPlaylist(c)
    }

    private func fallbackPlaylist(_ c: Ctl) -> Bool {
        guard !c.playlist.tracks.isEmpty else { return false }
        if c.audio.state != .playing { c.playIndex(c.playlist.current ?? 0) }
        return true
    }

    private func stopRinging(pause: Bool) {
        guard ringing else { return }
        ringing = false
        ringStarted = nil
        fadeInStart = nil
        beepTimer?.invalidate()
        beepTimer = nil
        ctl?.fadeScale = 1
        if pause, ctl?.audio.state == .playing { ctl?.pause() }
    }

    // MARK: Clock

    private func tick() {
        guard let c = ctl else { return }
        let now = Date()

        // Alarm (and snooze).
        if let s = snoozeUntil, now >= s {
            snoozeUntil = nil
            ring()
        } else if let a = nextAlarm, now >= a {
            let late = now.timeIntervalSince(a)
            if alarmDays.isEmpty { alarmOn = false } else { rearm(after: now) }
            if late < Scheduler.lateWindow { ring() }
        }
        if ringing {
            if let f = fadeInStart, beepTimer == nil {
                let k = alarmFadeIn > 0 ? min(1, now.timeIntervalSince(f) / alarmFadeIn) : 1
                c.fadeScale = k
                if k >= 1 { fadeInStart = nil }
            }
            // Paused or stopped by hand (or after 30 minutes): the alarm is over.
            let userStopped = beepTimer == nil && c.audio.state != .playing && now.timeIntervalSince(ringStarted ?? now) > 3
            if userStopped || now.timeIntervalSince(ringStarted ?? now) > 30 * 60 { stopRinging(pause: false); changed() }
        }

        // Sleep timer.
        guard sleep != .off else { return }
        if sleep == .endOfTrack, let t = sleepTrack, c.playlist.currentTrack !== t {
            // Gapless/crossfade already moved on: stop the next track at its start.
            fireSleep(rewind: true)
            return
        }
        if sleep == .endOfTrack, c.playlist.currentTrack?.isStream == true || c.audio.state == .stopped {
            if c.audio.state == .stopped { fireSleep(rewind: false) }
            return
        }
        guard let left = sleepRemaining else { return }
        if fadeOut, c.audio.state == .playing { c.fadeScale = Scheduler.fadeFactor(remaining: left, fade: fadeOutSeconds) }
        if left <= 0.05 { fireSleep(rewind: false) }
    }

    private func fireSleep(rewind: Bool) {
        guard let c = ctl else { return }
        let action = sleepAction
        sleep = .off
        sleepTrack = nil
        switch action {
        case .pause:
            if c.audio.state == .playing { c.pause() }
            if rewind { c.audio.seek(to: 0) }
        case .stop, .sleepMac, .quit:
            c.stop()
        }
        c.fadeScale = 1
        updateActivity()
        changed()
        switch action {
        case .quit: NSApp.terminate(nil)
        case .sleepMac:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            try? p.run()
        default: c.flashMarquee("GOOD NIGHT", seconds: 3)
        }
    }

    private func restoreFade() {
        if !ringing { ctl?.fadeScale = 1 }
    }

    /// Keeps App Nap from delaying the clock while something is armed, and (optionally) idle sleep away for the alarm.
    private func updateActivity() {
        let armed = sleep != .off || nextAlarm != nil || snoozeUntil != nil || ringing
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        guard armed else { return }
        let awake = keepAwake && (nextAlarm != nil || snoozeUntil != nil)
        activity = ProcessInfo.processInfo.beginActivity(
            options: awake ? [.idleSystemSleepDisabled, .userInitiated] : [.userInitiatedAllowingIdleSystemSleep],
            reason: awake ? "MusicAmp alarm" : "MusicAmp sleep timer")
    }

    private func changed() {
        objectWillChange.send()
        WidgetBridge.shared.setNeedsUpdate()
    }

    // MARK: Menu (Controls → Sleep Timer, Options menu)

    func sleepMenu() -> NSMenu {
        let m = NSMenu(title: L("Sleep Timer"))
        m.delegate = self
        menuNeedsUpdate(m)
        return m
    }

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if let left = sleepRemaining {
            m.addItem(withTitle: sleep == .endOfTrack ? "Stops at the end of this track (\(Ctl.mmss(left)))" : "Stops in \(Ctl.hmmss(left))", action: nil, keyEquivalent: "")
            add(m, "Turn Off", #selector(menuCancel))
            m.addItem(.separator())
        }
        for p in Scheduler.sleepPresets {
            let it = add(m, p < 60 ? "\(p) Minutes" : (p == 60 ? "1 Hour" : String(format: "%g Hours", Double(p) / 60)), #selector(menuMinutes(_:)))
            it.tag = p
        }
        add(m, "End of Current Track", #selector(menuEndOfTrack))
        if ringing || snoozeUntil != nil {
            m.addItem(.separator())
            if ringing { add(m, "Snooze \(Scheduler.snoozeMinutes) Minutes", #selector(menuSnooze)) }
            add(m, "Stop Alarm", #selector(menuStopAlarm))
        }
        m.addItem(.separator())
        if let a = nextAlarm {
            m.addItem(withTitle: L("Alarm: ") + Scheduler.describe(a), action: nil, keyEquivalent: "")
        }
        add(m, "Timer and Alarm Settings…", #selector(menuSettings))
    }

    @discardableResult
    private func add(_ m: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let it = m.addItem(withTitle: title, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    @objc private func menuMinutes(_ s: NSMenuItem) { startSleep(minutes: Double(s.tag)) }
    @objc private func menuEndOfTrack() { sleepAtEndOfTrack() }
    @objc private func menuCancel() { cancelSleep() }
    @objc private func menuSnooze() { snooze() }
    @objc private func menuStopAlarm() { stopAlarm() }
    @objc private func menuSettings() { ctl?.openPreferences(tab: .timer) }

    static func describe(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'today' HH:mm" : (Calendar.current.isDateInTomorrow(d) ? "'tomorrow' HH:mm" : "EEE d MMM HH:mm")
        return f.string(from: d)
    }

    // MARK: Persistence

    private func load() {
        let d = UserDefaults.standard
        loading = true
        defer { loading = false }
        sleepAction = SleepAction(rawValue: d.integer(forKey: "sleep.action")) ?? .pause
        fadeOut = d.object(forKey: "sleep.fadeOut") as? Bool ?? true
        fadeOutSeconds = d.object(forKey: "sleep.fadeOutSeconds") as? Double ?? 30
        alarmOn = d.bool(forKey: "alarm.on")
        alarmHour = d.object(forKey: "alarm.hour") as? Int ?? 7
        alarmMinute = d.object(forKey: "alarm.minute") as? Int ?? 30
        alarmDays = Set(d.array(forKey: "alarm.days") as? [Int] ?? [2, 3, 4, 5, 6])
        alarmSource = d.string(forKey: "alarm.source") ?? ""
        alarmVolume = d.object(forKey: "alarm.volume") as? Double ?? 60
        alarmFadeIn = d.object(forKey: "alarm.fadeIn") as? Double ?? 60
        keepAwake = d.object(forKey: "alarm.keepAwake") as? Bool ?? true
    }

    private func save() {
        guard !loading else { return }
        let d = UserDefaults.standard
        d.set(sleepAction.rawValue, forKey: "sleep.action")
        d.set(fadeOut, forKey: "sleep.fadeOut")
        d.set(fadeOutSeconds, forKey: "sleep.fadeOutSeconds")
        d.set(alarmOn, forKey: "alarm.on")
        d.set(alarmHour, forKey: "alarm.hour")
        d.set(alarmMinute, forKey: "alarm.minute")
        d.set(Array(alarmDays).sorted(), forKey: "alarm.days")
        d.set(alarmSource, forKey: "alarm.source")
        d.set(alarmVolume, forKey: "alarm.volume")
        d.set(alarmFadeIn, forKey: "alarm.fadeIn")
        d.set(keepAwake, forKey: "alarm.keepAwake")
    }
}

// MARK: - Settings → Timer

struct TimerTab: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var s = Scheduler.shared
    @State private var minutes: Double = 30
    /// The app speaks English whatever the system language.
    static let days: Calendar = { var c = Calendar(identifier: .gregorian); c.locale = Locale(identifier: "en_US"); return c }()

    var body: some View {
        Form {
            Section("Sleep Timer") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack {
                        if let left = s.sleepRemaining {
                            Image(systemName: "moon.zzz.fill").foregroundStyle(.tint)
                            Text(s.sleep == .endOfTrack ? "At the end of this track (\(Ctl.mmss(left)))" : "In \(Ctl.hmmss(left))").monospacedDigit()
                            Spacer()
                            Button("Turn Off") { s.cancelSleep() }
                        } else {
                            Text("Off").foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                HStack {
                    Text("Duration")
                    Slider(value: $minutes, in: 5...180, step: 5)
                    Text("\(Int(minutes)) min").monospacedDigit().frame(width: 56, alignment: .trailing)
                    Button("Start") { s.startSleep(minutes: minutes) }
                    Button("End of Track") { s.sleepAtEndOfTrack() }
                }
                Picker("When it ends", selection: $s.sleepAction) {
                    ForEach(Scheduler.SleepAction.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Fade out", isOn: $s.fadeOut)
                if s.fadeOut {
                    HStack {
                        Text("Fade length")
                        Slider(value: $s.fadeOutSeconds, in: 5...120, step: 5)
                        Text("\(Int(s.fadeOutSeconds)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Alarm") {
                Toggle("Wake me up with music", isOn: $s.alarmOn)
                DatePicker("Time", selection: alarmTime, displayedComponents: .hourAndMinute)
                HStack {
                    Text("Days")
                    Spacer()
                    // Monday first; weekday numbers are Calendar's (1 = Sunday).
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                        let on = s.alarmDays.contains(d)
                        let toggle = { if on { s.alarmDays.remove(d) } else { s.alarmDays.insert(d) } }
                        Group {
                            if on {
                                Button(TimerTab.days.veryShortStandaloneWeekdaySymbols[d - 1], action: toggle).buttonStyle(.borderedProminent)
                            } else {
                                Button(TimerTab.days.veryShortStandaloneWeekdaySymbols[d - 1], action: toggle).buttonStyle(.bordered)
                            }
                        }
                        .help(TimerTab.days.standaloneWeekdaySymbols[d - 1])
                    }
                }
                Picker("Play", selection: $s.alarmSource) {
                    Text("The playlist, from its current track").tag("")
                    ForEach(sources, id: \.0) { Text($0.1).tag($0.0) }
                    if !s.alarmSource.isEmpty, !sources.contains(where: { $0.0 == s.alarmSource }) {
                        Text(URL(string: s.alarmSource)?.lastPathComponent ?? s.alarmSource).tag(s.alarmSource)
                    }
                }
                HStack {
                    Text("Volume")
                    Slider(value: $s.alarmVolume, in: 5...100, step: 5)
                    Text("\(Int(s.alarmVolume))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Fade in")
                    Slider(value: $s.alarmFadeIn, in: 0...300, step: 15)
                    Text(s.alarmFadeIn == 0 ? "Off" : "\(Int(s.alarmFadeIn)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Toggle("Keep the Mac awake while the alarm is set", isOn: $s.keepAwake)
                HStack {
                    if let a = s.nextAlarm {
                        Text("Next: \(Scheduler.describe(a))\(s.alarmDays.isEmpty ? " (once)" : "")").foregroundStyle(.secondary)
                    } else {
                        Text(s.alarmOn ? "Pick at least one day, or none for a one-time alarm." : "Alarm off").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.ringing {
                        Button("Snooze") { s.snooze() }
                        Button("Stop") { s.stopAlarm() }
                    } else {
                        Button("Test") { s.testAlarm() }
                    }
                }
                Text("MusicAmp must be running and the Mac awake (not asleep, lid open) for the alarm to ring.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Stations, tracks of the playlist worth waking up to.
    private var sources: [(String, String)] {
        var seen = Set<String>()
        return ctl.playlist.tracks.compactMap { t in
            let k = t.url.absoluteString
            guard seen.insert(k).inserted else { return nil }
            return (k, t.isStream ? "Radio: \(t.title)" : t.title)
        }.prefix(300).map { $0 }
    }

    private var alarmTime: Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: s.alarmHour, minute: s.alarmMinute, second: 0, of: Date()) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    s.alarmHour = c.hour ?? 7
                    s.alarmMinute = c.minute ?? 0
                })
    }
}
