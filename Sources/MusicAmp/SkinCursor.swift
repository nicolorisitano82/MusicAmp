import AppKit

/// A skin cursor: one frame for .cur, several for animated .ani (RIFF "ACON") files.
struct SkinCursor {
    let frames: [NSCursor]
    let delays: [TimeInterval]

    static func load(_ url: URL) -> SkinCursor? {
        guard let data = try? Data(contentsOf: url), data.count > 12 else { return nil }
        if data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("ACON".utf8) { return parseANI(data) }
        return cursor(fromIcon: data).map { SkinCursor(frames: [$0], delays: [0]) }
    }

    /// ICO/CUR payload; for CUR (type 2) the hotspot lives in the planes/bitcount fields.
    static func cursor(fromIcon data: Data) -> NSCursor? {
        guard data.count > 22, let img = NSImage(data: data), img.isValid else { return nil }
        let isCur = data[2] == 2
        let hx = isCur ? Int(data[10]) | Int(data[11]) << 8 : 0
        let hy = isCur ? Int(data[12]) | Int(data[13]) << 8 : 0
        return NSCursor(image: img, hotSpot: NSPoint(x: hx, y: hy))
    }

    /// RIFF ACON: 'anih' header (frames, steps, default rate in 1/60 s), optional 'rate'/'seq ', LIST 'fram' of 'icon' chunks.
    static func parseANI(_ d: Data) -> SkinCursor? {
        func u32(_ o: Int) -> Int {
            guard o + 4 <= d.count else { return 0 }
            return Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 | Int(d[d.startIndex + o + 2]) << 16 | Int(d[d.startIndex + o + 3]) << 24
        }
        func tag(_ o: Int) -> String { String(decoding: d[(d.startIndex + o)..<(d.startIndex + o + 4)], as: UTF8.self) }

        var icons: [NSCursor] = []
        var steps = 0, defaultRate = 10
        var rates: [Int] = [], seq: [Int] = []

        func walk(_ start: Int, _ end: Int) {
            var o = start
            while o + 8 <= end {
                let id = tag(o), size = u32(o + 4), body = o + 8
                guard body + size <= d.count else { return }
                switch id {
                case "anih":
                    steps = u32(body + 8)
                    let r = u32(body + 28)
                    if r > 0 { defaultRate = r }
                case "rate": rates = (0..<(size / 4)).map { u32(body + $0 * 4) }
                case "seq ": seq = (0..<(size / 4)).map { u32(body + $0 * 4) }
                case "LIST": walk(body + 4, body + size)   // skip list type ("fram"/"INFO")
                case "icon":
                    if let c = cursor(fromIcon: d.subdata(in: (d.startIndex + body)..<(d.startIndex + body + size))) { icons.append(c) }
                default: break
                }
                o = body + size + (size & 1)
            }
        }
        walk(12, d.count)
        guard !icons.isEmpty else { return nil }
        let n = max(steps, seq.count, 1)
        var frames: [NSCursor] = [], delays: [TimeInterval] = []
        for i in 0..<n {
            let idx = i < seq.count ? seq[i] : i
            frames.append(icons[min(max(0, idx), icons.count - 1)])
            delays.append(Double(i < rates.count ? rates[i] : defaultRate) / 60)
        }
        return SkinCursor(frames: frames, delays: delays)
    }
}

/// Plays the frames of the cursor currently shown over a skin window.
final class CursorAnimator {
    static let shared = CursorAnimator()
    private var current: [NSCursor] = []
    private var delays: [TimeInterval] = []
    private var index = 0
    private var timer: Timer?

    func show(_ c: SkinCursor?) {
        guard let c else { stop(); NSCursor.arrow.set(); return }
        if c.frames == current {
            current[index].set()
            return
        }
        stop()
        current = c.frames
        delays = c.delays
        index = 0
        c.frames[0].set()
        if c.frames.count > 1 { schedule() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        current = []
    }

    private func schedule() {
        let t = Timer(timeInterval: max(0.02, delays[index]), repeats: false) { [weak self] _ in
            guard let self, !self.current.isEmpty else { return }
            self.index = (self.index + 1) % self.current.count
            if NSApp.isActive { self.current[self.index].set() }
            self.schedule()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
