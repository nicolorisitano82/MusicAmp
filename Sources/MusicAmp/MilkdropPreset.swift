import Foundation

// Milkdrop .milk presets: an INI-like list of base values ("fDecay=0.98", "zoom=1.01"), equation lines
// (per_frame_init_N, per_frame_N, per_pixel_N) and up to 4 custom waves and 4 custom shapes, each with
// its own values and code. MD2 shader sections (warp_N / comp_N, HLSL) are kept but not run yet.

struct MilkPreset {
    var name: String
    var url: URL?
    var values: [String: Double] = [:]
    var initCode = "", frameCode = "", pixelCode = ""
    var waves: [Part] = Array(repeating: Part(), count: 4)
    var shapes: [Part] = Array(repeating: Part(), count: 4)
    var warpShader = "", compShader = ""

    /// A custom wave or shape: its values and its init / per-frame / per-point code.
    struct Part {
        var values: [String: Double] = [:]
        var initCode = "", frameCode = "", pointCode = ""
        var enabled: Bool { (values["enabled"] ?? 0) != 0 }
    }

    var usesShaders: Bool { !warpShader.isEmpty || !compShader.isEmpty }

    /// Preset file keys → equation variable names.
    static let keyMap: [String: String] = [
        "fdecay": "decay", "fgammaadj": "gamma", "fvideoechozoom": "echo_zoom", "fvideoechoalpha": "echo_alpha",
        "nvideoechoorientation": "echo_orient", "nwavemode": "wave_mode", "badditivewaves": "additivewave",
        "bwavedots": "wave_dots", "bwavethick": "wave_thick", "bmodwavealphabyvolume": "modwavealphabyvolume",
        "bmaximizewavecolor": "wave_brighten", "btexwrap": "wrap", "bdarkencenter": "darken_center",
        "bredbluestereo": "red_blue", "bbrighten": "brighten", "bdarken": "darken", "bsolarize": "solarize",
        "binvert": "invert", "fwavealpha": "wave_a", "fwavescale": "wave_scale", "fwavesmoothing": "wave_smoothing",
        "fwaveparam": "wave_mystery", "fmodwavealphastart": "modwavealphastart", "fmodwavealphaend": "modwavealphaend",
        "fwarpanimspeed": "warpanimspeed", "fwarpscale": "warpscale", "fzoomexponent": "zoomexp", "fshader": "fshader",
        "nmotionvectorsx": "mv_x", "nmotionvectorsy": "mv_y", "fwavesmoothing2": "wave_smoothing",
        // custom waves / shapes
        "bspectrum": "spectrum", "busedots": "usedots", "bdrawthick": "thick", "badditive": "additive",
        "fscaling": "scaling", "fsmoothing": "smoothing", "nsides": "sides", "badditive2": "additive",
        "bthickoutline": "thickoutline", "btextured": "textured", "num_inst": "num_inst",
    ]

    /// Defaults Milkdrop uses for values a preset leaves out.
    static let defaults: [String: Double] = [
        "decay": 0.98, "gamma": 2, "echo_zoom": 2, "echo_alpha": 0, "echo_orient": 0, "wave_mode": 0, "additivewave": 0,
        "wave_dots": 0, "wave_thick": 0, "modwavealphabyvolume": 0, "wave_brighten": 1, "wrap": 1, "darken_center": 0,
        "brighten": 0, "darken": 0, "solarize": 0, "invert": 0, "wave_a": 0.8, "wave_scale": 1, "wave_smoothing": 0.75,
        "wave_mystery": 0, "modwavealphastart": 0.75, "modwavealphaend": 0.95, "warpanimspeed": 1, "warpscale": 1,
        "zoomexp": 1, "zoom": 1, "rot": 0, "cx": 0.5, "cy": 0.5, "dx": 0, "dy": 0, "warp": 1, "sx": 1, "sy": 1,
        "wave_r": 1, "wave_g": 1, "wave_b": 1, "wave_x": 0.5, "wave_y": 0.5,
        "ob_size": 0.01, "ob_r": 0, "ob_g": 0, "ob_b": 0, "ob_a": 0, "ib_size": 0.01, "ib_r": 0.25, "ib_g": 0.25, "ib_b": 0.25, "ib_a": 0,
        "b1n": 0, "b1x": 1, "b2n": 0, "b2x": 1, "b3n": 0, "b3x": 1,
        "mv_x": 12, "mv_y": 9, "mv_dx": 0, "mv_dy": 0, "mv_l": 0.9, "mv_r": 1, "mv_g": 1, "mv_b": 1, "mv_a": 0,
    ]

    static let waveDefaults: [String: Double] = [
        "enabled": 0, "samples": 512, "sep": 0, "spectrum": 0, "usedots": 0, "thick": 0, "additive": 0,
        "scaling": 1, "smoothing": 0.5, "r": 1, "g": 1, "b": 1, "a": 1,
    ]

    static let shapeDefaults: [String: Double] = [
        "enabled": 0, "sides": 4, "additive": 0, "thickoutline": 0, "textured": 0, "num_inst": 1,
        "x": 0.5, "y": 0.5, "rad": 0.1, "ang": 0, "tex_zoom": 1, "tex_ang": 0,
        "r": 1, "g": 0, "b": 0, "a": 1, "r2": 0, "g2": 1, "b2": 0, "a2": 0,
        "border_r": 1, "border_g": 1, "border_b": 1, "border_a": 0.1,
    ]

    static func load(_ url: URL) -> MilkPreset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var p = parse(text, name: url.deletingPathExtension().lastPathComponent)
        p.url = url
        return p
    }

    static func parse(_ text: String, name: String) -> MilkPreset {
        var p = MilkPreset(name: name)
        var code: [String: [(Int, String)]] = [:]   // section key → numbered lines
        for raw in text.components(separatedBy: .newlines) {
            guard let eq = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = String(raw[raw.index(after: eq)...])
            guard !key.isEmpty, !key.hasPrefix("[") else { continue }
            // Numbered code lines: per_frame_12, wave_0_per_point3, shape_2_init1, warp_7…
            if let (section, n) = codeLine(key) {
                code[section, default: []].append((n, val.trimmingCharacters(in: .whitespaces)))
                continue
            }
            let v = Double(val.trimmingCharacters(in: .whitespaces)) ?? 0
            if key.hasPrefix("wavecode_") || key.hasPrefix("shapecode_") {
                let parts = key.split(separator: "_", maxSplits: 2)
                guard parts.count == 3, let i = Int(parts[1]), i < 4 else { continue }
                let k = keyMap[String(parts[2])] ?? String(parts[2])
                if key.hasPrefix("wave") { p.waves[i].values[k] = v } else { p.shapes[i].values[k] = v }
            } else {
                p.values[keyMap[key] ?? key] = v
            }
        }
        func join(_ k: String) -> String { (code[k] ?? []).sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n") }
        p.initCode = join("per_frame_init")
        p.frameCode = join("per_frame")
        p.pixelCode = join("per_pixel")
        for i in 0..<4 {
            p.waves[i].initCode = join("wave_\(i)_init")
            p.waves[i].frameCode = join("wave_\(i)_per_frame")
            p.waves[i].pointCode = join("wave_\(i)_per_point")
            p.shapes[i].initCode = join("shape_\(i)_init")
            p.shapes[i].frameCode = join("shape_\(i)_per_frame")
        }
        // Shader lines start with a backtick.
        p.warpShader = join("warp").replacingOccurrences(of: "`", with: "")
        p.compShader = join("comp").replacingOccurrences(of: "`", with: "")
        return p
    }

    /// "per_frame_12" → ("per_frame", 12); "wave_0_per_point3" → ("wave_0_per_point", 3).
    private static func codeLine(_ key: String) -> (String, Int)? {
        let prefixes = ["per_frame_init_", "per_frame_", "per_pixel_", "warp_", "comp_"]
        for pre in prefixes where key.hasPrefix(pre) {
            if let n = Int(key.dropFirst(pre.count)) { return (String(pre.dropLast()), n) }
        }
        for kind in ["wave_", "shape_"] where key.hasPrefix(kind) {
            let rest = key.dropFirst(kind.count)
            guard let us = rest.firstIndex(of: "_"), let idx = Int(rest[..<us]) else { continue }
            let tail = rest[rest.index(after: us)...]
            for sec in ["init", "per_frame", "per_point"] where tail.hasPrefix(sec) {
                if let n = Int(tail.dropFirst(sec.count)) { return ("\(kind)\(idx)_\(sec)", n) }
            }
        }
        return nil
    }
}

// MARK: Runtime

/// Audio levels in Milkdrop's scale: ~1 on average, above 1 on hits.
struct MilkAudio {
    var bass = 1.0, mid = 1.0, treb = 1.0
    var bassAtt = 1.0, midAtt = 1.0, trebAtt = 1.0
    var left = [Float](repeating: 0, count: 576), right = [Float](repeating: 0, count: 576)
    var spectrumL = [Float](repeating: 0, count: 512), spectrumR = [Float](repeating: 0, count: 512)
    var vol: Double { (bass + mid + treb) / 3 }
}

/// One preset ready to run: its compiled programs and variable contexts.
final class MilkRuntime {
    let preset: MilkPreset
    let frame: EELContext
    let pixel: EELContext
    private let initProg, frameProg, pixelProg: EELProgram
    private var qAfterInit = [Double](repeating: 0, count: 32)
    private var userVars: [Int] = []
    let waves: [WaveRuntime]
    let shapes: [ShapeRuntime]
    var hasPixelCode: Bool { !pixelProg.isEmpty }

    static let qNames = (1...32).map { "q\($0)" }
    static let builtins = ["time", "fps", "frame", "progress", "bass", "mid", "treb", "bass_att", "mid_att", "treb_att",
                           "meshx", "meshy", "aspectx", "aspecty", "pixelsx", "pixelsy", "rand_start", "rand_preset"]

    init(_ p: MilkPreset) {
        preset = p
        let g = EELGlobal()
        frame = EELContext(global: g)
        pixel = EELContext(global: g)
        for (k, v) in MilkPreset.defaults { frame[k] = v }
        for (k, v) in p.values { frame[k] = v }
        initProg = EEL.compile(p.initCode, frame)
        frameProg = EEL.compile(p.frameCode, frame)
        pixelProg = EEL.compile(p.pixelCode, pixel)
        waves = p.waves.map { WaveRuntime($0, global: g) }
        shapes = p.shapes.map { ShapeRuntime($0, global: g) }
        _ = initProg.run()
        qAfterInit = MilkRuntime.qNames.map { frame[$0] }
    }

    /// Values a frame starts from: the preset's base values, q as left by the init code.
    private func resetFrame(time: Double, frameNo: Int, fps: Double, audio: MilkAudio, aspect: (Double, Double), size: (Int, Int)) {
        for (k, v) in MilkPreset.defaults where preset.values[k] == nil { frame[k] = v }
        for (k, v) in preset.values { frame[k] = v }
        for (i, q) in MilkRuntime.qNames.enumerated() { frame[q] = qAfterInit[i] }
        frame["time"] = time; frame["frame"] = Double(frameNo); frame["fps"] = fps; frame["progress"] = 0.5
        frame["bass"] = audio.bass; frame["mid"] = audio.mid; frame["treb"] = audio.treb
        frame["bass_att"] = audio.bassAtt; frame["mid_att"] = audio.midAtt; frame["treb_att"] = audio.trebAtt
        frame["meshx"] = Double(MilkMesh.cols); frame["meshy"] = Double(MilkMesh.rows)
        frame["aspectx"] = aspect.0; frame["aspecty"] = aspect.1
        frame["pixelsx"] = Double(size.0); frame["pixelsy"] = Double(size.1)
    }

    func runFrame(time: Double, frameNo: Int, fps: Double, audio: MilkAudio, aspect: (Double, Double), size: (Int, Int)) {
        resetFrame(time: time, frameNo: frameNo, fps: fps, audio: audio, aspect: aspect, size: size)
        _ = frameProg.run()
    }

    /// Per-vertex warp. Without per-pixel code every vertex uses the per-frame values.
    func runPixel(x: Double, y: Double, rad: Double, ang: Double) -> (zoom: Double, zoomexp: Double, rot: Double, warp: Double,
                                                                      cx: Double, cy: Double, dx: Double, dy: Double, sx: Double, sy: Double) {
        let f = frame
        guard hasPixelCode else {
            return (f["zoom"], f["zoomexp"], f["rot"], f["warp"], f["cx"], f["cy"], f["dx"], f["dy"], f["sx"], f["sy"])
        }
        let p = pixel
        p["x"] = x; p["y"] = y; p["rad"] = rad; p["ang"] = ang
        return (p["zoom"], p["zoomexp"], p["rot"], p["warp"], p["cx"], p["cy"], p["dx"], p["dy"], p["sx"], p["sy"])
    }

    /// Copies the frame values the per-pixel code can read, once per frame (fast path for the vertex loop).
    func preparePixel() {
        guard hasPixelCode else { return }
        for k in ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"] + MilkRuntime.builtins + MilkRuntime.qNames {
            pixel[k] = frame[k]
        }
        pixelSlots = ["x", "y", "rad", "ang", "zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"].map { pixel.slot($0) }
        pixelFrameValues = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"].map { frame[$0] }
    }
    private var pixelSlots: [Int] = []
    private var pixelFrameValues: [Double] = []

    /// Fast per-vertex evaluation through raw slots (resets the warp values each vertex, like Milkdrop).
    @inline(__always) func pixelEval(_ x: Double, _ y: Double, _ rad: Double, _ ang: Double, into out: UnsafeMutablePointer<Double>) {
        let m = pixel.mem, s = pixelSlots
        m[s[0]] = x; m[s[1]] = y; m[s[2]] = rad; m[s[3]] = ang
        for i in 0..<10 { m[s[4 + i]] = pixelFrameValues[i] }
        _ = pixelProg.run()
        for i in 0..<10 { out[i] = m[s[4 + i]] }
    }

    subscript(_ k: String) -> Double { frame[k] }

    /// Sends q1…q32 and the audio/time values to a custom wave or shape context.
    func share(to ctx: EELContext) {
        for k in MilkRuntime.qNames + MilkRuntime.builtins { ctx[k] = frame[k] }
    }
}

final class WaveRuntime {
    let part: MilkPreset.Part
    let ctx: EELContext
    private let initProg, frameProg, pointProg: EELProgram
    private var tAfterInit = [Double](repeating: 0, count: 8)
    private var slots: [Int] = []

    init(_ p: MilkPreset.Part, global: EELGlobal) {
        part = p
        ctx = EELContext(global: global)
        for (k, v) in MilkPreset.waveDefaults { ctx[k] = v }
        for (k, v) in p.values { ctx[k] = v }
        initProg = EEL.compile(p.initCode, ctx)
        frameProg = EEL.compile(p.frameCode, ctx)
        pointProg = EEL.compile(p.pointCode, ctx)
        _ = initProg.run()
        tAfterInit = (1...8).map { ctx["t\($0)"] }
        slots = ["sample", "value1", "value2", "x", "y", "r", "g", "b", "a"].map { ctx.slot($0) }
    }

    struct Point { var x, y, r, g, b, a: Float }

    /// Points of this wave for the frame (empty when disabled).
    func points(_ rt: MilkRuntime, _ audio: MilkAudio) -> (pts: [Point], dots: Bool, thick: Bool, additive: Bool) {
        guard part.enabled else { return ([], false, false, false) }
        for (k, v) in MilkPreset.waveDefaults where part.values[k] == nil { ctx[k] = v }
        for (k, v) in part.values { ctx[k] = v }
        for i in 0..<8 { ctx["t\(i + 1)"] = tAfterInit[i] }
        rt.share(to: ctx)
        _ = frameProg.run()
        let spectrum = ctx["spectrum"] != 0
        let n = max(2, min(512, Int(ctx["samples"])))
        let sep = Int(ctx["sep"]), scale = ctx["scaling"], smooth = max(0, min(0.9, ctx["smoothing"]))
        let srcL = spectrum ? audio.spectrumL : audio.left, srcR = spectrum ? audio.spectrumR : audio.right
        // Resample + smooth like Milkdrop (one-pole both ways).
        func series(_ src: [Float], offset: Int) -> [Double] {
            var out = (0..<n).map { i -> Double in
                let j = min(src.count - 1, max(0, (i * (src.count - 1 - max(0, sep))) / max(1, n - 1) + offset))
                return Double(src[j]) * scale
            }
            if smooth > 0 && n > 2 {
                for i in 1..<n { out[i] = out[i] * (1 - smooth) + out[i - 1] * smooth }
                for i in stride(from: n - 2, through: 0, by: -1) { out[i] = out[i] * (1 - smooth) + out[i + 1] * smooth }
            }
            return out
        }
        let v1 = series(srcL, offset: 0), v2 = series(srcR, offset: max(0, sep))
        let base = (r: ctx["r"], g: ctx["g"], b: ctx["b"], a: ctx["a"])
        let m = ctx.mem, s = slots
        var pts: [Point] = []
        pts.reserveCapacity(n)
        for i in 0..<n {
            m[s[0]] = Double(i) / Double(n - 1); m[s[1]] = v1[i]; m[s[2]] = v2[i]
            m[s[3]] = 0.5 + v1[i]; m[s[4]] = 0.5 + v2[i]
            m[s[5]] = base.r; m[s[6]] = base.g; m[s[7]] = base.b; m[s[8]] = base.a
            _ = pointProg.run()
            pts.append(Point(x: Float(m[s[3]]), y: Float(m[s[4]]), r: Float(m[s[5]]), g: Float(m[s[6]]), b: Float(m[s[7]]), a: Float(m[s[8]])))
        }
        return (pts, ctx["usedots"] != 0, ctx["thick"] != 0, ctx["additive"] != 0)
    }
}

final class ShapeRuntime {
    let part: MilkPreset.Part
    let ctx: EELContext
    private let initProg, frameProg: EELProgram
    private var tAfterInit = [Double](repeating: 0, count: 8)

    init(_ p: MilkPreset.Part, global: EELGlobal) {
        part = p
        ctx = EELContext(global: global)
        for (k, v) in MilkPreset.shapeDefaults { ctx[k] = v }
        for (k, v) in p.values { ctx[k] = v }
        initProg = EEL.compile(p.initCode, ctx)
        frameProg = EEL.compile(p.frameCode, ctx)
        _ = initProg.run()
        tAfterInit = (1...8).map { ctx["t\($0)"] }
    }

    struct Instance {
        var x, y, rad, ang: Double
        var sides: Int
        var additive, thick, textured: Bool
        var texZoom, texAng: Double
        var inner: (Double, Double, Double, Double), outer: (Double, Double, Double, Double), border: (Double, Double, Double, Double)
    }

    func instances(_ rt: MilkRuntime) -> [Instance] {
        guard part.enabled else { return [] }
        let count = max(1, min(1024, Int(part.values["num_inst"] ?? 1)))
        var out: [Instance] = []
        for inst in 0..<count {
            for (k, v) in MilkPreset.shapeDefaults where part.values[k] == nil { ctx[k] = v }
            for (k, v) in part.values { ctx[k] = v }
            for i in 0..<8 { ctx["t\(i + 1)"] = tAfterInit[i] }
            rt.share(to: ctx)
            ctx["instance"] = Double(inst)
            _ = frameProg.run()
            out.append(Instance(x: ctx["x"], y: ctx["y"], rad: ctx["rad"], ang: ctx["ang"],
                                sides: max(3, min(100, Int(ctx["sides"]))),
                                additive: ctx["additive"] != 0, thick: ctx["thickoutline"] != 0, textured: ctx["textured"] != 0,
                                texZoom: ctx["tex_zoom"], texAng: ctx["tex_ang"],
                                inner: (ctx["r"], ctx["g"], ctx["b"], ctx["a"]), outer: (ctx["r2"], ctx["g2"], ctx["b2"], ctx["a2"]),
                                border: (ctx["border_r"], ctx["border_g"], ctx["border_b"], ctx["border_a"])))
        }
        return out
    }
}

enum MilkMesh {
    static let cols = 48, rows = 36
}
