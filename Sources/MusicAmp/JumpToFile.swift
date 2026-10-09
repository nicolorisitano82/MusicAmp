import AppKit
import SwiftUI

/// Winamp's "Jump to file" (J): type to filter the playlist, Return plays, ⌘Return queues, Esc closes.
final class JumpModel: ObservableObject {
    @Published var query = "" { didSet { highlighted = 0 } }
    @Published var highlighted = 0
    let ctl: Ctl

    init(ctl: Ctl) { self.ctl = ctl }

    /// Every word must appear in the title or file name, ignoring case and accents.
    var matches: [(index: Int, title: String)] {
        let words = query.lowercased().folding(options: .diacriticInsensitive, locale: nil).split(separator: " ")
        return ctl.playlist.tracks.enumerated().compactMap { i, t in
            let hay = (t.title + " " + t.url.lastPathComponent).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return words.allSatisfy { hay.contains($0) } ? (i, "\(i + 1). \(t.title)") : nil
        }
    }

    func move(_ d: Int) {
        let n = matches.count
        guard n > 0 else { return }
        highlighted = max(0, min(n - 1, highlighted + d))
    }

    func play() {
        let m = matches
        guard m.indices.contains(highlighted) else { NSSound.beep(); return }
        ctl.playIndex(m[highlighted].index)
        ctl.closeJumpToFile()
    }

    func enqueue() {
        let m = matches
        guard m.indices.contains(highlighted) else { NSSound.beep(); return }
        let i = m[highlighted].index
        if ctl.playlist.queuePosition(ctl.playlist.tracks[i]) == nil {
            ctl.playlist.toggleQueue([i])
            ctl.invalidateTransition()
        }
        ctl.flashMarquee("QUEUED: \(ctl.playlist.queue.count)", seconds: 1.2)
        move(1)
    }
}

struct JumpView: View {
    @ObservedObject var model: JumpModel
    @FocusState private var focused: Bool

    var body: some View {
        let m = model.matches
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search the playlist", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { model.play() }
                .accessibilityLabel("Search the playlist")
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(m.enumerated()), id: \.element.index) { pos, item in
                        Text(item.title).lineLimit(1)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(pos == model.highlighted ? Color.accentColor.opacity(0.25) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.highlighted = pos; model.play() }
                            .onTapGesture { model.highlighted = pos }
                            .id(pos)
                            .accessibilityAddTraits(pos == model.highlighted ? .isSelected : [])
                    }
                }
                .listStyle(.plain)
                .onChange(of: model.highlighted) { proxy.scrollTo($1) }
            }
            HStack {
                Text("\(m.count) of \(model.ctl.playlist.tracks.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Queue") { model.enqueue() }.keyboardShortcut(.return, modifiers: .command)
                Button("Play") { model.play() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 420, height: 380)
        .onAppear { focused = true }
    }
}

extension Ctl {
    @objc func showJumpToFile() {
        if jumpPanelRef == nil {
            let model = JumpModel(ctl: self)
            let panel = NSPanel(contentViewController: NSHostingController(rootView: JumpView(model: model)))
            panel.title = L("Jump to File")
            panel.styleMask = [.titled, .closable, .utilityWindow]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            jumpPanelRef = panel
            jumpModelRef = model
            jumpKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let p = self.jumpPanelRef, p.isKeyWindow, let m = self.jumpModelRef else { return e }
                switch e.keyCode {
                case 125: m.move(1); return nil        // ↓
                case 126: m.move(-1); return nil       // ↑
                case 121: m.move(10); return nil       // page down
                case 116: m.move(-10); return nil      // page up
                case 53: self.closeJumpToFile(); return nil   // Esc
                default: return e
                }
            }
        }
        jumpModelRef?.query = ""
        if let p = jumpPanelRef {
            let f = mainWindow.frame
            p.setFrameTopLeftPoint(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY - 8))
            p.level = alwaysOnTop ? .floating : .normal
        }
        NSApp.activate(ignoringOtherApps: true)
        jumpPanelRef?.makeKeyAndOrderFront(nil)
    }

    func closeJumpToFile() { jumpPanelRef?.orderOut(nil) }
}
