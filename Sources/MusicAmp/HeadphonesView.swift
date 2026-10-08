import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Headphones: parametric EQ with AutoEq headphone profiles.
struct HeadphonesTab: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var catalog: AutoEqCatalog
    @State private var choosing = false

    /// Numbers always as 1234.5: the app is English whatever the system region.
    static let numbers = Locale(identifier: "en_US_POSIX")

    var body: some View {
        // The whole tab scrolls (16 bands don't fit the Settings window); no nested scroll view for the bands.
        ScrollView(.vertical) {
            content
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .sheet(isPresented: $choosing) { HeadphonePicker(ctl: ctl, catalog: catalog, isPresented: $choosing) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle("Parametric EQ", isOn: ctl.binding(\.peqEnabled)).toggleStyle(.switch)
                Spacer(minLength: 8)
                Text(ctl.peqProfile.name).font(.headline).lineLimit(1).truncationMode(.middle)
                    .help(ctl.peqProfile.name)
            }
            HStack {
                Button("Choose Headphones…") { choosing = true }
                Button("Import…", action: importProfile)
                Button("Export…", action: exportProfile).disabled(ctl.peqProfile.filters.isEmpty)
                Button("Reset") { ctl.peqProfile = PEQProfile() }
                Spacer()
            }
            ResponseGraph(profile: ctl.peqProfile, active: ctl.peqEnabled)
                .frame(height: 140)
            HStack(spacing: 8) {
                Text("Preamp")
                Slider(value: Binding(get: { ctl.peqProfile.preamp }, set: { ctl.peqProfile.preamp = ($0 * 10).rounded() / 10 }), in: -24...12)
                    .frame(width: 220)
                Text(String(format: "%+.1f dB", ctl.peqProfile.preamp)).monospacedDigit().frame(width: 64, alignment: .trailing)
                Button("Auto") { ctl.peqProfile.preamp = (ctl.peqProfile.safePreamp * 10).rounded(.down) / 10 }
                    .help("Lowest preamp that keeps the loudest boost from clipping")
                Spacer()
            }
            filterTable
            Divider()
            HStack {
                Picker("Crossfeed", selection: ctl.binding(\.crossfeed)) {
                    ForEach(CrossfeedAU.Preset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .frame(maxWidth: 360)
                Spacer()
            }
            Text("Crossfeed lets each ear hear a little of the other channel's lows, slightly later, as with speakers: old stereo records with instruments hard left or right stop sounding inside one ear.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Headphone profiles: AutoEq by Jaakko Pasanen (MIT), measurements by oratory1990, crinacle and others. The parametric EQ runs after the Winamp equalizer.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var filterTable: some View {
        VStack(spacing: 4) {
            HStack {
                Text("On").frame(width: 28)
                Text("Type").frame(width: 110, alignment: .leading)
                Text("Frequency (Hz)").frame(width: 110, alignment: .leading)
                Text("Gain (dB)").frame(width: 90, alignment: .leading)
                Text("Q").frame(width: 70, alignment: .leading)
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 4) {
                    ForEach($ctl.peqProfile.filters) { $f in
                        HStack {
                            Toggle("", isOn: $f.enabled).labelsHidden().frame(width: 28)
                            Picker("", selection: $f.kind) {
                                ForEach(PEQFilter.Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden().frame(width: 110)
                            TextField("", value: $f.frequency, format: .number.grouping(.never).precision(.fractionLength(0)).locale(Self.numbers)).frame(width: 110)
                            TextField("", value: $f.gain, format: .number.precision(.fractionLength(1)).locale(Self.numbers)).frame(width: 90)
                            TextField("", value: $f.q, format: .number.precision(.fractionLength(2)).locale(Self.numbers)).frame(width: 70)
                            Button { ctl.peqProfile.filters.removeAll { $0.id == f.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                            Spacer()
                        }
                        .textFieldStyle(.roundedBorder)
                    }
            }
            HStack {
                Button("Add Band") {
                    if ctl.peqProfile.name.isEmpty { ctl.peqProfile.name = "Custom" }
                    ctl.peqProfile.filters.append(PEQFilter())
                }
                .disabled(ctl.peqProfile.filters.count >= PEQProfile.maxBands)
                Spacer()
                Text("\(ctl.peqProfile.filters.count)/\(PEQProfile.maxBands) bands").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func importProfile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.plainText, .text]
        guard p.runModal() == .OK, let u = p.url, let t = try? String(contentsOf: u),
              let prof = PEQProfile.parse(t, name: u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ParametricEQ", with: "")) else { return }
        ctl.peqProfile = prof
        ctl.peqEnabled = true
    }

    private func exportProfile() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(ctl.peqProfile.name) ParametricEQ.txt"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? ctl.peqProfile.text.write(to: u, atomically: true, encoding: .utf8)
    }
}

/// Frequency response of the profile, 20 Hz – 20 kHz on a log axis, ±15 dB.
struct ResponseGraph: View {
    let profile: PEQProfile
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / log10(1000)) * size.width }
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(db / 15) * size.height / 2 }
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.25)))
            var grid = Path()
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] { grid.move(to: CGPoint(x: x(f), y: 0)); grid.addLine(to: CGPoint(x: x(f), y: size.height)) }
            for db in [-10.0, -5, 5, 10] { grid.move(to: CGPoint(x: 0, y: y(db))); grid.addLine(to: CGPoint(x: size.width, y: y(db))) }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: y(0))); zero.addLine(to: CGPoint(x: size.width, y: y(0)))
            ctx.stroke(zero, with: .color(.secondary.opacity(0.6)), lineWidth: 0.8)
            for (f, label) in [(100.0, "100"), (1000, "1k"), (10000, "10k")] {
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x(f) + 10, y: size.height - 7))
            }
            for db in [-10.0, 0, 10] {
                ctx.draw(Text(db == 0 ? "0 dB" : String(format: "%+.0f dB", db)).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 6, y: y(db) - 7), anchor: .leading)
            }
            guard !profile.filters.isEmpty || profile.preamp != 0 else { return }
            var curve = Path()
            let steps = Int(size.width)
            for i in 0...steps {
                let f = 20 * pow(1000, Double(i) / Double(steps))
                let p = CGPoint(x: CGFloat(i), y: y(max(-15, min(15, profile.response(at: f)))))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            ctx.stroke(curve, with: .color(active ? .accentColor : .secondary), lineWidth: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Searchable list of the AutoEq profiles.
struct HeadphonePicker: View {
    @ObservedObject var ctl: Ctl
    @ObservedObject var catalog: AutoEqCatalog
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selection: AutoEqCatalog.Entry.ID?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Headphones").font(.headline)
            TextField("Search headphones or earphones (e.g. HD 600, AirPods Pro)", text: $query).textFieldStyle(.roundedBorder)
            let results = catalog.search(query)
            List(results, selection: $selection) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.name)
                    Text("Measured by \(e.source)").font(.caption).foregroundStyle(.secondary)
                }
                .tag(e.id)
            }
            .frame(minHeight: 300)
            .overlay {
                if catalog.loading { ProgressView("Downloading the AutoEq list…") }
                else if let err = catalog.error { Text(err).foregroundStyle(.secondary).padding() }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                if let m = message { Text(m).font(.caption).foregroundStyle(.secondary) }
                Text("\(catalog.entries.count) profiles").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Use Profile") { use(results.first { $0.id == selection }) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil || busy)
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .task { await catalog.load() }
    }

    private func use(_ e: AutoEqCatalog.Entry?) {
        guard let e else { return }
        busy = true
        message = nil
        Task { @MainActor in
            do {
                var p = try await catalog.profile(e)
                p.name = e.name + " (\(e.source))"
                ctl.peqProfile = p
                ctl.peqEnabled = true
                busy = false
                isPresented = false
            } catch {
                busy = false
                message = "Download failed: \(error.localizedDescription)"
            }
        }
    }
}
