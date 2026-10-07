import AppKit
import Carbon.HIToolbox

struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt   // NSEvent.ModifierFlags raw value
    var display: String

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    static func make(_ keyCode: Int, _ flags: NSEvent.ModifierFlags, _ key: String) -> HotKey {
        HotKey(keyCode: UInt32(keyCode), modifiers: flags.rawValue, display: symbols(flags) + key)
    }

    static func symbols(_ f: NSEvent.ModifierFlags) -> String {
        (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    }

    static func keyName(_ e: NSEvent) -> String {
        switch Int(e.keyCode) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Space: return "Spazio"
        case kVK_Return: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default:
            if let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
                .firstIndex(of: Int(e.keyCode)) { return "F\(f + 1)" }
            return (e.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

enum HotKeyAction: String, CaseIterable, Codable, Identifiable {
    case playPause, stop, next, previous, volumeUp, volumeDown, seekForward, seekBack, showHide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playPause: return "Play / Pausa"
        case .stop: return "Stop"
        case .next: return "Brano successivo"
        case .previous: return "Brano precedente"
        case .volumeUp: return "Volume su"
        case .volumeDown: return "Volume giù"
        case .seekForward: return "Avanti 5 secondi"
        case .seekBack: return "Indietro 5 secondi"
        case .showHide: return "Mostra / nascondi MusicAmp"
        }
    }

    static let mods: NSEvent.ModifierFlags = [.control, .option, .command]

    var defaultKey: HotKey {
        switch self {
        case .playPause: return .make(kVK_ANSI_P, Self.mods, "P")
        case .stop: return .make(kVK_ANSI_S, Self.mods, "S")
        case .next: return .make(kVK_RightArrow, Self.mods, "→")
        case .previous: return .make(kVK_LeftArrow, Self.mods, "←")
        case .volumeUp: return .make(kVK_UpArrow, Self.mods, "↑")
        case .volumeDown: return .make(kVK_DownArrow, Self.mods, "↓")
        case .seekForward: return .make(kVK_RightArrow, Self.mods.union(.shift), "→")
        case .seekBack: return .make(kVK_LeftArrow, Self.mods.union(.shift), "←")
        case .showHide: return .make(kVK_ANSI_M, Self.mods, "M")
        }
    }
}

/// System-wide shortcuts through Carbon RegisterEventHotKey (no accessibility permission needed).
final class HotKeys: ObservableObject {
    static let shared = HotKeys()

    @Published private(set) var bindings: [HotKeyAction: HotKey] = [:]
    /// Combinations another app already owns.
    @Published private(set) var failed = Set<HotKeyAction>()
    @Published var enabled = true { didSet { apply(); save() } }
    var onAction: ((HotKeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private let order = HotKeyAction.allCases

    private init() {
        let d = UserDefaults.standard
        // Initialise the wrappers directly: assigning in init would run didSet (apply + save) too early.
        _enabled = Published(initialValue: d.object(forKey: "hotKeysEnabled") as? Bool ?? true)
        // Saved as action -> key or null (removed); a missing action falls back to its default.
        let saved = d.data(forKey: "hotKeys").flatMap { try? JSONDecoder().decode([String: HotKey?].self, from: $0) } ?? [:]
        var b: [HotKeyAction: HotKey] = [:]
        for a in HotKeyAction.allCases {
            if let entry = saved[a.rawValue] { b[a] = entry } else { b[a] = a.defaultKey }
        }
        _bindings = Published(initialValue: b)
    }

    func set(_ action: HotKeyAction, _ key: HotKey?) {
        // One combination drives one action.
        if let key { for (a, k) in bindings where k == key && a != action { bindings[a] = nil } }
        bindings[action] = key
        apply()
        save()
    }

    func resetDefaults() {
        for a in order { bindings[a] = a.defaultKey }
        apply()
        save()
    }

    /// Suspended while the preferences record a new combination, so the old one doesn't fire.
    func suspend() { unregisterAll() }
    func resume() { apply() }

    func apply() {
        unregisterAll()
        guard enabled else { failed = []; return }
        installHandler()
        var bad = Set<HotKeyAction>()
        for (i, a) in order.enumerated() {
            guard let k = bindings[a] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D416D70), id: UInt32(i))   // 'MAmp'
            let status = RegisterEventHotKey(k.keyCode, Self.carbon(k.flags), id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { bad.insert(a) }
            if Self.debug { NSLog("hotkey \(a.rawValue) \(k.display) code=\(k.keyCode) mods=\(Self.carbon(k.flags)) status=\(status)") }
        }
        failed = bad
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(enabled, forKey: "hotKeysEnabled")
        let dict: [String: HotKey?] = Dictionary(uniqueKeysWithValues: order.map { ($0.rawValue, bindings[$0]) })
        d.set(try? JSONEncoder().encode(dict), forKey: "hotKeys")
    }

    static let debug = ProcessInfo.processInfo.environment["MUSICAMP_DEBUG_HOTKEYS"] != nil

    fileprivate func fire(_ index: Int) {
        if Self.debug { NSLog("hotkey fired \(index)") }
        guard order.indices.contains(index) else { return }
        onAction?(order[index])
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let index = Int(hk.id)
            DispatchQueue.main.async { HotKeys.shared.fire(index) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}
