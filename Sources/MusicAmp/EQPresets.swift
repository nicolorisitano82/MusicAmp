import AppKit
import UniformTypeIdentifiers

struct EQPreset: Codable, Equatable {
    var name: String
    var bands: [Double]   // 10 values, dB
    var preamp: Double    // dB
}

/// Winamp EQ preset files. `.eqf` (one preset) and `.q1` (a library, e.g. winamp.q1) share one layout:
/// the 31-byte header "Winamp EQ library file v1.1" 0x1A "!--", then per preset a 257-byte NUL-padded name
/// and 11 bytes: 10 band slider positions + preamp, 0x00 = +12 dB (top), 0x1F = 0 dB, 0x3F = -12 dB (bottom),
/// i.e. 31 steps above neutral and 32 below.
enum EQF {
    static let header = Data("Winamp EQ library file v1.1".utf8) + Data([0x1A]) + Data("!--".utf8)

    static func dB(_ pos: UInt8) -> Double {
        let p = Double(min(63, pos))
        let v = p <= 31 ? (31 - p) / 31 * 12 : -(p - 31) / 32 * 12
        return (v * 10).rounded() / 10
    }

    static func pos(_ db: Double) -> UInt8 {
        let v = max(-12, min(12, db))
        let p = v >= 0 ? 31 - v / 12 * 31 : 31 - v / 12 * 32
        return UInt8(max(0, min(63, p.rounded())))
    }

    static func parse(_ data: Data) -> [EQPreset]? {
        guard data.count >= header.count, data.prefix(27) == header.prefix(27) else { return nil }
        var out: [EQPreset] = []
        var o = data.startIndex + header.count
        while o + 257 + 11 <= data.endIndex {
            let nameBytes = data[o..<(o + 257)].prefix { $0 != 0 }
            let name = String(data: Data(nameBytes), encoding: .windowsCP1252) ?? "Preset"
            let v = data[(o + 257)..<(o + 268)].map { $0 }
            out.append(EQPreset(name: name, bands: v[0..<10].map(dB), preamp: dB(v[10])))
            o += 268
        }
        return out.isEmpty ? nil : out
    }

    static func write(_ presets: [EQPreset]) -> Data {
        var d = header
        for p in presets {
            var name = Array((p.name.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()).prefix(256))
            name += [UInt8](repeating: 0, count: 257 - name.count)
            d.append(contentsOf: name)
            d.append(contentsOf: (p.bands.prefix(10) + [p.preamp]).map(pos))
        }
        return d
    }
}

extension Ctl {
    /// Presets the user saved or imported from .eqf/.q1 files, shown in the PRESETS menu.
    var userPresets: [EQPreset] {
        get {
            UserDefaults.standard.data(forKey: "userEQPresets").flatMap { try? JSONDecoder().decode([EQPreset].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "userEQPresets") }
    }

    var currentPreset: EQPreset { EQPreset(name: "", bands: bands, preamp: preamp) }

    func applyEQPreset(_ p: EQPreset) {
        bands = Array(p.bands.prefix(10)) + Array(repeating: 0, count: max(0, 10 - p.bands.count))
        preamp = p.preamp
        eqOn = true
        eqView.needsDisplay = true
        flashMarquee("EQ: \(p.name.uppercased())")
    }

    @objc func applyUserPreset(_ s: NSMenuItem) {
        let list = userPresets
        if list.indices.contains(s.tag) { applyEQPreset(list[s.tag]) }
    }

    @objc func deleteUserPreset(_ s: NSMenuItem) {
        var list = userPresets
        if list.indices.contains(s.tag) { list.remove(at: s.tag) }
        userPresets = list
    }

    private static var eqTypes: [UTType] { ["eqf", "q1"].compactMap { UTType(filenameExtension: $0) } }

    /// .eqf with one preset → applied; a library (.q1) → added to "Your Presets" and the first one applied.
    @objc func loadEQFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = Self.eqTypes
        p.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK else { return }
        var imported: [EQPreset] = []
        for u in p.urls {
            guard let data = try? Data(contentsOf: u), let list = EQF.parse(data) else {
                let a = NSAlert()
                a.messageText = "\(u.lastPathComponent) is not a valid Winamp preset file."
                a.runModal()
                continue
            }
            // A single-preset .eqf often has a generic name inside: prefer the file name.
            imported += list.count == 1 && u.pathExtension.lowercased() == "eqf"
                ? [EQPreset(name: u.deletingPathExtension().lastPathComponent, bands: list[0].bands, preamp: list[0].preamp)]
                : list
        }
        guard let first = imported.first else { return }
        var lib = userPresets
        for p in imported {
            if let i = lib.firstIndex(where: { $0.name == p.name }) { lib[i] = p } else { lib.append(p) }
        }
        userPresets = lib
        applyEQPreset(first)
        if imported.count > 1 { flashMarquee("EQ: IMPORTED \(imported.count) PRESETS") }
    }

    @objc func saveEQFile() {
        let p = NSSavePanel()
        p.allowedContentTypes = Self.eqTypes.prefix(1).map { $0 }
        p.nameFieldStringValue = "Preset.eqf"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        var preset = currentPreset
        preset.name = u.deletingPathExtension().lastPathComponent
        do { try EQF.write([preset]).write(to: u) } catch { NSAlert(error: error).runModal() }
    }

    @objc func exportEQLibrary() {
        let p = NSSavePanel()
        p.allowedContentTypes = Self.eqTypes.suffix(1).map { $0 }
        p.nameFieldStringValue = "MusicAmp.q1"
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        let all = Ctl.presets.map { EQPreset(name: $0.0, bands: $0.1, preamp: 0) }
            + Ctl.artistPresets.map { EQPreset(name: $0.0, bands: $0.1, preamp: $0.2) } + userPresets
        do { try EQF.write(all).write(to: u) } catch { NSAlert(error: error).runModal() }
    }

    @objc func saveUserPreset() {
        let a = NSAlert()
        a.messageText = "Save EQ Preset"
        a.informativeText = "Preset name:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "My Preset"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var preset = currentPreset
        preset.name = name
        var lib = userPresets
        if let i = lib.firstIndex(where: { $0.name == name }) { lib[i] = preset } else { lib.append(preset) }
        userPresets = lib
        flashMarquee("EQ: SAVED \(name.uppercased())")
    }
}
