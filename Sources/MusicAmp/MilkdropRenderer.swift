import Foundation
import Metal
import simd

// Milkdrop 1.x pipeline on Metal. Each frame:
//  1. warp: the previous frame is drawn through a 48×36 mesh whose texture coordinates come from the
//     zoom/rot/warp/cx/cy/dx/dy/sx/sy values (per-pixel code runs once per vertex), darkened by `decay`;
//  2. motion vectors, custom shapes, custom waves, the main waveform, darken-center and borders are drawn
//     on top, into the same feedback texture (so they get warped on the next frames);
//  3. composite: the feedback texture goes to the screen with video echo, gamma and brighten/darken/
//     solarize/invert.
// Presets switch with a 2.7 s blend of both meshes and their drawings.

final class MilkdropRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipe, colorPipe, colorAddPipe, texPipe, texAddPipe, compPipe: MTLRenderPipelineState
    private let wrapSampler, clampSampler: MTLSamplerState
    private var feedback: [MTLTexture] = []
    private var cur = 0
    private let meshIndex: MTLBuffer
    private let meshIndexCount: Int

    private(set) var runtime: MilkRuntime?
    private var previous: MilkRuntime?
    private var blendStart = 0.0
    let blendDuration = 2.7

    private let start = Date()
    private var lastTime = 0.0
    private var frameNo = 0
    private var fps = 60.0
    private var levels = Levels()
    var lastAudio = MilkAudio()

    static let format: MTLPixelFormat = .bgra8Unorm

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let lib = try device.makeLibrary(source: MilkdropRenderer.shaderSource, options: nil)
            func pipe(_ v: String, _ f: String, blend: Int) throws -> MTLRenderPipelineState {
                let d = MTLRenderPipelineDescriptor()
                d.vertexFunction = lib.makeFunction(name: v)
                d.fragmentFunction = lib.makeFunction(name: f)
                let a = d.colorAttachments[0]!
                a.pixelFormat = MilkdropRenderer.format
                if blend > 0 {
                    a.isBlendingEnabled = true
                    a.rgbBlendOperation = .add
                    a.alphaBlendOperation = .add
                    a.sourceRGBBlendFactor = .sourceAlpha
                    a.destinationRGBBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: d)
            }
            warpPipe = try pipe("warp_v", "warp_f", blend: 0)
            colorPipe = try pipe("col_v", "col_f", blend: 1)
            colorAddPipe = try pipe("col_v", "col_f", blend: 2)
            texPipe = try pipe("tex_v", "tex_f", blend: 1)
            texAddPipe = try pipe("tex_v", "tex_f", blend: 2)
            compPipe = try pipe("comp_v", "comp_f", blend: 0)
        } catch {
            NSLog("Milkdrop shaders: %@", "\(error)")
            return nil
        }
        func sampler(_ mode: MTLSamplerAddressMode) -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.sAddressMode = mode
            d.tAddressMode = mode
            return device.makeSamplerState(descriptor: d)!
        }
        wrapSampler = sampler(.repeat)
        clampSampler = sampler(.clampToEdge)
        var idx: [UInt32] = []
        let c = MilkMesh.cols, r = MilkMesh.rows
        for j in 0..<r {
            for i in 0..<c {
                let a = UInt32(j * (c + 1) + i), b = a + 1, d = a + UInt32(c + 1), e = d + 1
                idx += [a, b, d, b, e, d]
            }
        }
        meshIndexCount = idx.count
        meshIndex = device.makeBuffer(bytes: idx, length: idx.count * 4)!
    }

    // MARK: Presets

    func load(_ preset: MilkPreset, blend: Bool = true) {
        let rt = MilkRuntime(preset)
        if blend, let r = runtime {
            previous = r
            blendStart = now
        } else {
            previous = nil
        }
        runtime = rt
    }

    /// Tests and snapshots drive time themselves (seconds); nil = wall clock.
    var fixedTime: Double?
    private var now: Double { fixedTime ?? Date().timeIntervalSince(start) }

    // MARK: Audio levels (Milkdrop scale: ~1 = average)

    private struct Levels {
        var long: (Double, Double, Double) = (0, 0, 0)
        var avg: (Double, Double, Double) = (0, 0, 0)
        var frames = 0
    }

    func updateAudio(left: [Float], right: [Float], spectrum: [Float], bands: (Float, Float, Float), dt: Double) {
        var a = MilkAudio()
        a.left = left
        a.right = right
        a.spectrumL = spectrum
        a.spectrumR = spectrum
        let imm = (Double(bands.0), Double(bands.1), Double(bands.2))
        let f = max(0.25, min(4, dt * 30))   // rates below are per frame at 30 fps
        levels.frames += 1
        let rl = pow(levels.frames < 50 ? 0.9 : 0.992, f)
        func step(_ l: inout Double, _ av: inout Double, _ v: Double) -> (Double, Double) {
            if l == 0 { l = v }
            l = l * rl + v * (1 - rl)
            let ra = pow(v > av ? 0.2 : 0.5, f)
            av = av * ra + v * (1 - ra)
            guard l > 1e-12 else { return (v > 0 ? 1 : 0, v > 0 ? 1 : 0) }
            return (min(8, v / l), min(8, av / l))
        }
        var long = levels.long, avg = levels.avg
        (a.bass, a.bassAtt) = step(&long.0, &avg.0, imm.0)
        (a.mid, a.midAtt) = step(&long.1, &avg.1, imm.1)
        (a.treb, a.trebAtt) = step(&long.2, &avg.2, imm.2)
        levels.long = long
        levels.avg = avg
        lastAudio = a
    }

    // MARK: Frame

    /// Renders one frame into `target` (a drawable texture or an offscreen one for tests/snapshots).
    func render(into target: MTLTexture, commandBuffer cbExternal: MTLCommandBuffer? = nil) -> MTLCommandBuffer? {
        guard let rt = runtime else { return nil }
        let w = target.width, h = target.height
        ensureFeedback(w, h)
        let t = now
        let dt = max(1.0 / 240, min(0.25, t - lastTime))
        lastTime = t
        fps = fps * 0.9 + (1 / dt) * 0.1
        frameNo += 1
        let aspect = (w > h ? Double(h) / Double(w) : 1, h > w ? Double(w) / Double(h) : 1)
        let audio = lastAudio

        rt.runFrame(time: t, frameNo: frameNo, fps: fps, audio: audio, aspect: aspect, size: (w, h))
        var p = 1.0
        var prev = previous
        if let pr = prev {
            p = min(1, (t - blendStart) / blendDuration)
            p = p * p * (3 - 2 * p)   // smoothstep
            if p >= 1 { previous = nil; prev = nil } else {
                pr.runFrame(time: t, frameNo: frameNo, fps: fps, audio: audio, aspect: aspect, size: (w, h))
            }
        }

        // 1. Warp mesh (blended with the outgoing preset).
        var mesh = warpMesh(rt, time: t, aspect: aspect)
        if let pr = prev {
            let old = warpMesh(pr, time: t, aspect: aspect)
            for i in 0..<mesh.count { mesh[i].z = mesh[i].z * Float(p) + old[i].z * Float(1 - p); mesh[i].w = mesh[i].w * Float(p) + old[i].w * Float(1 - p) }
        }
        func mix(_ k: String) -> Double { prev.map { $0[k] * (1 - p) + rt[k] * p } ?? rt[k] }

        let src = feedback[cur], dst = feedback[1 - cur]
        guard let cb = cbExternal ?? queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(warpPipe)
        mesh.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        var decay = Float(max(0, min(1, mix("decay"))))
        enc.setFragmentBytes(&decay, length: 4, index: 0)
        enc.setFragmentTexture(src, index: 0)
        enc.setFragmentSamplerState(rt["wrap"] != 0 ? wrapSampler : clampSampler, index: 0)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint32, indexBuffer: meshIndex, indexBufferOffset: 0)

        // 2. Drawings on top.
        let px = Float(2.0 / Double(h))   // one pixel in clip units (vertical)
        var drawings: [(MilkRuntime, Float)] = [(rt, Float(p))]
        if let pr = prev { drawings.insert((pr, Float(1 - p)), at: 0) }
        for (r, alpha) in drawings {
            motionVectors(r, mesh: mesh, alpha: alpha, enc: enc, px: px)
            shapes(r, alpha: alpha, enc: enc, src: src, aspect: aspect, px: px)
            customWaves(r, audio: audio, alpha: alpha, enc: enc, px: px)
            mainWave(r, audio: audio, time: t, alpha: alpha, enc: enc, aspect: aspect, px: px)
            if r["darken_center"] != 0 { darkenCenter(alpha: alpha, enc: enc, aspect: aspect) }
            borders(r, alpha: alpha, enc: enc)
        }
        enc.endEncoding()

        // 3. Composite to the target.
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = target
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        guard let ce = cb.makeRenderCommandEncoder(descriptor: cp) else { return nil }
        ce.setRenderPipelineState(compPipe)
        var u = CompUniforms(gamma: Float(max(0.1, mix("gamma"))), echoAlpha: Float(max(0, min(1, mix("echo_alpha")))),
                             echoZoom: Float(max(0.01, mix("echo_zoom"))), echoOrient: Int32(rt["echo_orient"]) & 3,
                             brighten: rt["brighten"] != 0 ? 1 : 0, darken: rt["darken"] != 0 ? 1 : 0,
                             solarize: rt["solarize"] != 0 ? 1 : 0, invert: rt["invert"] != 0 ? 1 : 0)
        ce.setFragmentBytes(&u, length: MemoryLayout<CompUniforms>.stride, index: 0)
        ce.setFragmentTexture(dst, index: 0)
        ce.setFragmentSamplerState(clampSampler, index: 0)
        ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ce.endEncoding()
        cur = 1 - cur
        return cb
    }

    private struct CompUniforms {
        var gamma: Float, echoAlpha: Float, echoZoom: Float, echoOrient: Int32
        var brighten: Int32, darken: Int32, solarize: Int32, invert: Int32
    }

    private func ensureFeedback(_ w: Int, _ h: Int) {
        if let f = feedback.first, f.width == w, f.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkdropRenderer.format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        feedback = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        // Start from black.
        if let cb = queue.makeCommandBuffer() {
            for t in feedback {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = t
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                rp.colorAttachments[0].storeAction = .store
                cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
            }
            cb.commit()
        }
    }

    // MARK: Warp mesh

    /// (clip x, clip y, u, v) per vertex, Milkdrop's warp formula.
    private func warpMesh(_ rt: MilkRuntime, time: Double, aspect: (Double, Double)) -> [SIMD4<Float>] {
        let cols = MilkMesh.cols, rows = MilkMesh.rows
        var out = [SIMD4<Float>](repeating: .zero, count: (cols + 1) * (rows + 1))
        let (ax, ay) = aspect
        let warpTime = time * rt["warpanimspeed"]
        let warpScaleInv = 1 / max(0.001, rt["warpscale"])
        let f0 = 11.68 + 4.0 * cos(warpTime * 1.413 + 10), f1 = 8.77 + 3.0 * cos(warpTime * 1.113 + 7)
        let f2 = 10.54 + 3.0 * cos(warpTime * 1.233 + 3), f3 = 11.49 + 4.0 * cos(warpTime * 0.933 + 5)
        rt.preparePixel()
        let vals = UnsafeMutablePointer<Double>.allocate(capacity: 10)
        defer { vals.deallocate() }
        let frameVals = ["zoom", "zoomexp", "rot", "warp", "cx", "cy", "dx", "dy", "sx", "sy"].map { rt[$0] }
        for j in 0...rows {
            for i in 0...cols {
                let fx = Double(i) / Double(cols) * 2 - 1
                let fy = 1 - Double(j) / Double(rows) * 2   // row 0 at the top
                let x = fx * 0.5 * ax + 0.5, y = -fy * 0.5 * ay + 0.5
                let rad = sqrt(fx * fx * ax * ax + fy * fy * ay * ay) * 0.7071
                let ang = atan2(fy * ay, fx * ax)
                if rt.hasPixelCode {
                    rt.pixelEval(x, y, rad, ang, into: vals)
                } else {
                    for k in 0..<10 { vals[k] = frameVals[k] }
                }
                let zoom = vals[0], zoomexp = vals[1], rot = vals[2], warp = vals[3]
                let cx = vals[4], cy = vals[5], dx = vals[6], dy = vals[7], sx = vals[8], sy = vals[9]
                let zoom2 = pow(max(0.0001, zoom), pow(max(0.0001, zoomexp), rad * 2 - 1))
                let zInv = 1 / (abs(zoom2) < 0.0001 ? 0.0001 : zoom2)
                var u = fx * ax * 0.5 * zInv + 0.5
                var v = -fy * ay * 0.5 * zInv + 0.5
                u = (u - cx) / (sx == 0 ? 1 : sx) + cx
                v = (v - cy) / (sy == 0 ? 1 : sy) + cy
                u += warp * 0.0035 * sin(warpTime * 0.333 + warpScaleInv * (fx * f0 - fy * f3))
                v += warp * 0.0035 * cos(warpTime * 0.375 - warpScaleInv * (fx * f2 + fy * f1))
                u += warp * 0.0035 * cos(warpTime * 0.753 - warpScaleInv * (fx * f1 - fy * f2))
                v += warp * 0.0035 * sin(warpTime * 0.825 + warpScaleInv * (fx * f0 + fy * f3))
                let u2 = u - cx, v2 = v - cy, cr = cos(rot), sr = sin(rot)
                u = u2 * cr - v2 * sr + cx
                v = u2 * sr + v2 * cr + cy
                u -= dx
                v -= dy
                u = (u - 0.5) / ax + 0.5
                v = (v - 0.5) / ay + 0.5
                out[j * (cols + 1) + i] = SIMD4(Float(fx), Float(fy), Float(u), Float(v))
            }
        }
        return out
    }

    // MARK: Geometry helpers

    private struct ColorVertex { var x, y, r, g, b, a: Float }
    private struct TexVertex { var x, y, r, g, b, a, u, v: Float }

    /// Milkdrop coordinates (0…1, y down) → clip space.
    @inline(__always) private func clip(_ x: Double, _ y: Double) -> (Float, Float) { (Float(x * 2 - 1), Float(1 - y * 2)) }

    private func draw(_ v: [ColorVertex], additive: Bool, enc: MTLRenderCommandEncoder) {
        guard !v.isEmpty else { return }
        enc.setRenderPipelineState(additive ? colorAddPipe : colorPipe)
        let bytes = v.count * MemoryLayout<ColorVertex>.stride
        if bytes <= 4096 {
            v.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: bytes, index: 0) }
        } else if let b = device.makeBuffer(bytes: v, length: bytes) {
            enc.setVertexBuffer(b, offset: 0, index: 0)
        } else { return }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
    }

    /// A polyline as quads `width` clip units thick (or dots).
    private func lineVerts(_ pts: [(Float, Float, SIMD4<Float>)], width: Float, dots: Bool, loop: Bool = false) -> [ColorVertex] {
        var out: [ColorVertex] = []
        guard pts.count >= (dots ? 1 : 2) else { return out }
        let hw = width / 2
        func quad(_ a: (Float, Float), _ b: (Float, Float), _ c: (Float, Float), _ d: (Float, Float), _ ca: SIMD4<Float>, _ cb: SIMD4<Float>) {
            out += [ColorVertex(x: a.0, y: a.1, r: ca.x, g: ca.y, b: ca.z, a: ca.w), ColorVertex(x: b.0, y: b.1, r: cb.x, g: cb.y, b: cb.z, a: cb.w),
                    ColorVertex(x: c.0, y: c.1, r: ca.x, g: ca.y, b: ca.z, a: ca.w),
                    ColorVertex(x: b.0, y: b.1, r: cb.x, g: cb.y, b: cb.z, a: cb.w), ColorVertex(x: d.0, y: d.1, r: cb.x, g: cb.y, b: cb.z, a: cb.w),
                    ColorVertex(x: c.0, y: c.1, r: ca.x, g: ca.y, b: ca.z, a: ca.w)]
        }
        if dots {
            for p in pts { quad((p.0 - hw, p.1 - hw), (p.0 + hw, p.1 - hw), (p.0 - hw, p.1 + hw), (p.0 + hw, p.1 + hw), p.2, p.2) }
            return out
        }
        let n = loop ? pts.count : pts.count - 1
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            var dx = b.0 - a.0, dy = b.1 - a.1
            let len = max(1e-6, sqrt(dx * dx + dy * dy))
            dx /= len; dy /= len
            let nx = -dy * hw, ny = dx * hw
            // Extend a little along the segment so joints have no gaps.
            let ex = dx * hw * 0.5, ey = dy * hw * 0.5
            quad((a.0 + nx - ex, a.1 + ny - ey), (b.0 + nx + ex, b.1 + ny + ey), (a.0 - nx - ex, a.1 - ny - ey), (b.0 - nx + ex, b.1 - ny + ey), a.2, b.2)
        }
        return out
    }

    // MARK: Main waveform (modes 0–7)

    private func mainWave(_ rt: MilkRuntime, audio: MilkAudio, time: Double, alpha: Float, enc: MTLRenderCommandEncoder,
                          aspect: (Double, Double), px: Float) {
        var a = rt["wave_a"]
        if rt["modwavealphabyvolume"] != 0 {
            let s = rt["modwavealphastart"], e = rt["modwavealphaend"]
            a *= max(0, min(1, (audio.vol - s) / max(0.0001, e - s)))
        }
        let mode = ((Int(rt["wave_mode"]) % 8) + 8) % 8
        if mode == 3 { a *= max(0, min(1, audio.treb * audio.treb * 0.5)) }
        a = max(0, min(1, a)) * Double(alpha)
        guard a > 0.001 else { return }
        var col = SIMD3(Float(rt["wave_r"]), Float(rt["wave_g"]), Float(rt["wave_b"]))
        col = simd_clamp(col, .zero, SIMD3(repeating: 1))
        if rt["wave_brighten"] != 0, let m = [col.x, col.y, col.z].max(), m > 0.01 { col /= m }
        let c = SIMD4(col, Float(a))
        let scale = rt["wave_scale"], mystery = rt["wave_mystery"], smooth = max(0, min(0.98, rt["wave_smoothing"]))
        let wx = rt["wave_x"], wy = rt["wave_y"]
        func smoothed(_ s: [Float], count n: Int, offset: Int = 0) -> [Double] {
            var o = (0..<n).map { Double(s[min(s.count - 1, $0 + offset)]) * scale }
            for i in 1..<max(1, n) { o[i] = o[i] * (1 - smooth) + o[i - 1] * smooth }
            return o
        }
        let (ax, ay) = aspect
        var pts: [(Float, Float, SIMD4<Float>)] = []
        var loop = false
        switch mode {
        case 0:   // circle
            let n = 256, r = smoothed(audio.right, count: n)
            loop = true
            for i in 0..<n {
                let rad = 0.5 + 0.4 * r[i] + mystery
                let ang = Double(i) / Double(n) * 2 * .pi + time * 0.2
                let p = clip(wx + rad * cos(ang) * ax * 0.5, wy + rad * sin(ang) * ay * 0.5)
                pts.append((p.0, p.1, c))
            }
        case 1:   // x-y spiral
            let n = 256, l = smoothed(audio.left, count: n, offset: 32), r = smoothed(audio.right, count: n)
            for i in 0..<n {
                let rad = 0.53 + 0.43 * r[i] + mystery
                let ang = l[i] * 1.57 + time * 2.3
                let p = clip(wx + rad * cos(ang) * ax * 0.5, wy + rad * sin(ang) * ay * 0.5)
                pts.append((p.0, p.1, c))
            }
        case 2, 3:   // centred spiro (x = right, y = left)
            let n = 512, l = smoothed(audio.left, count: n, offset: 32), r = smoothed(audio.right, count: n)
            for i in 0..<n {
                let p = clip(wx + r[i] * ax * 0.5, wy + l[i] * ay * 0.5)
                pts.append((p.0, p.1, c))
            }
        case 4:   // horizontal derivative line
            let n = 320, l = smoothed(audio.left, count: n)
            for i in 0..<n {
                let x = -0.1 + Double(i) / Double(n - 1) * 1.2 + mystery * 0.1
                let d = i > 0 ? (l[i] - l[i - 1]) * 0.6 : 0
                let p = clip(x, wy - l[i] * 0.47 - d)
                pts.append((p.0, p.1, c))
            }
        case 5:   // explosive hash
            let n = 480, l = smoothed(audio.left, count: n), r = smoothed(audio.right, count: n, offset: 32)
            let cr = cos(time * 0.3), sr = sin(time * 0.3)
            for i in 0..<n {
                let x0 = r[i] * l[min(n - 1, i + 32)] + l[i] * r[i]
                let y0 = r[i] * r[i] - l[min(n - 1, i + 32)] * l[i]
                let p = clip(wx + (x0 * cr - y0 * sr) * ax * 0.5, wy + (x0 * sr + y0 * cr) * ay * 0.5)
                pts.append((p.0, p.1, c))
            }
        default:  // 6: angled line, 7: two lines (left and right)
            let n = 256
            let ang = 1.57 * mystery, ca = cos(ang), sa = sin(ang)
            for (k, src) in (mode == 7 ? [audio.left, audio.right] : [audio.left]).enumerated() {
                let s = smoothed(src, count: n)
                let sep = mode == 7 ? (k == 0 ? -0.08 : 0.08) * (1 + mystery) : 0
                var line: [(Float, Float, SIMD4<Float>)] = []
                for i in 0..<n {
                    let t = Double(i) / Double(n - 1) * 1.4 - 0.7
                    let off = s[i] * 0.25 + sep
                    let p = clip(wx + t * ca - off * sa, wy + t * sa + off * ca)
                    line.append((p.0, p.1, c))
                }
                draw(lineVerts(line, width: px * (rt["wave_thick"] != 0 ? 3 : 1.5), dots: rt["wave_dots"] != 0),
                     additive: rt["additivewave"] != 0, enc: enc)
            }
            return
        }
        let dots = rt["wave_dots"] != 0 || mode == 2 || mode == 3 && rt["wave_dots"] != 0
        draw(lineVerts(pts, width: px * (rt["wave_thick"] != 0 ? 3 : 1.5) * (dots ? 1.5 : 1), dots: dots, loop: loop),
             additive: rt["additivewave"] != 0, enc: enc)
    }

    // MARK: Custom waves and shapes

    private func customWaves(_ rt: MilkRuntime, audio: MilkAudio, alpha: Float, enc: MTLRenderCommandEncoder, px: Float) {
        for w in rt.waves where w.part.enabled {
            let (pts, dots, thick, additive) = w.points(rt, audio)
            let mapped = pts.map { p -> (Float, Float, SIMD4<Float>) in
                let c = clip(Double(p.x), Double(p.y))
                return (c.0, c.1, simd_clamp(SIMD4(p.r, p.g, p.b, p.a * alpha), .zero, SIMD4(repeating: 1)))
            }
            draw(lineVerts(mapped, width: px * (thick ? 3 : 1.5) * (dots ? 1.5 : 1), dots: dots), additive: additive, enc: enc)
        }
    }

    private func shapes(_ rt: MilkRuntime, alpha: Float, enc: MTLRenderCommandEncoder, src: MTLTexture, aspect: (Double, Double), px: Float) {
        let (ax, ay) = aspect
        for s in rt.shapes where s.part.enabled {
            for inst in s.instances(rt) {
                func col(_ c: (Double, Double, Double, Double)) -> SIMD4<Float> {
                    simd_clamp(SIMD4(Float(c.0), Float(c.1), Float(c.2), Float(c.3) * alpha), .zero, SIMD4(repeating: 1))
                }
                let ci = col(inst.inner), co = col(inst.outer)
                let center = clip(inst.x, inst.y)
                var rim: [(Float, Float, Float, Float)] = []   // clip x, y, u, v
                for k in 0...inst.sides {
                    let ang = Double(k) / Double(inst.sides) * 2 * .pi + inst.ang + .pi * 0.25
                    let p = clip(inst.x + inst.rad * cos(ang) * ax, inst.y + inst.rad * sin(ang) * ay)
                    let ta = ang + inst.texAng
                    let u = 0.5 + 0.5 * cos(ta) / max(0.001, inst.texZoom) * ax
                    let v = 0.5 - 0.5 * sin(ta) / max(0.001, inst.texZoom) * ay
                    rim.append((p.0, p.1, Float(u), Float(v)))
                }
                if inst.textured {
                    var v: [TexVertex] = []
                    for k in 0..<inst.sides {
                        let a = rim[k], b = rim[k + 1]
                        v += [TexVertex(x: center.0, y: center.1, r: ci.x, g: ci.y, b: ci.z, a: ci.w, u: 0.5, v: 0.5),
                              TexVertex(x: a.0, y: a.1, r: co.x, g: co.y, b: co.z, a: co.w, u: a.2, v: a.3),
                              TexVertex(x: b.0, y: b.1, r: co.x, g: co.y, b: co.z, a: co.w, u: b.2, v: b.3)]
                    }
                    enc.setRenderPipelineState(inst.additive ? texAddPipe : texPipe)
                    let bytes = v.count * MemoryLayout<TexVertex>.stride
                    if let b = device.makeBuffer(bytes: v, length: bytes) { enc.setVertexBuffer(b, offset: 0, index: 0) }
                    enc.setFragmentTexture(src, index: 0)
                    enc.setFragmentSamplerState(wrapSampler, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: v.count)
                } else {
                    var v: [ColorVertex] = []
                    for k in 0..<inst.sides {
                        let a = rim[k], b = rim[k + 1]
                        v += [ColorVertex(x: center.0, y: center.1, r: ci.x, g: ci.y, b: ci.z, a: ci.w),
                              ColorVertex(x: a.0, y: a.1, r: co.x, g: co.y, b: co.z, a: co.w),
                              ColorVertex(x: b.0, y: b.1, r: co.x, g: co.y, b: co.z, a: co.w)]
                    }
                    draw(v, additive: inst.additive, enc: enc)
                }
                let bc = col(inst.border)
                if bc.w > 0.001 {
                    draw(lineVerts(rim.map { ($0.0, $0.1, bc) }, width: px * (inst.thick ? 3 : 1.5), dots: false), additive: inst.additive, enc: enc)
                }
            }
        }
    }

    // MARK: Extras

    private func motionVectors(_ rt: MilkRuntime, mesh: [SIMD4<Float>], alpha: Float, enc: MTLRenderCommandEncoder, px: Float) {
        let a = Float(max(0, min(1, rt["mv_a"]))) * alpha
        let nx = max(0, min(64, Int(rt["mv_x"]))), ny = max(0, min(48, Int(rt["mv_y"])))
        guard a > 0.001, nx > 0, ny > 0 else { return }
        let c = SIMD4(Float(rt["mv_r"]), Float(rt["mv_g"]), Float(rt["mv_b"]), a)
        let len = Float(rt["mv_l"])
        let cols = MilkMesh.cols, rows = MilkMesh.rows
        var v: [ColorVertex] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let fx = (Float(i) + 0.25) / Float(nx) + Float(rt["mv_dx"]), fy = (Float(j) + 0.25) / Float(ny) + Float(rt["mv_dy"])
                guard fx > 0, fx < 1, fy > 0, fy < 1 else { continue }
                let m = mesh[Int(fy * Float(rows)) * (cols + 1) + Int(fx * Float(cols))]
                // Where this point's colour came from: the vector points back along the flow.
                let sx = fx * 2 - 1, sy = 1 - fy * 2
                let ux = m.z * 2 - 1, uy = 1 - m.w * 2
                let ex = sx + (ux - sx) * len * 8, ey = sy + (uy - sy) * len * 8
                v += lineVerts([(sx, sy, c), (ex, ey, c)], width: px * 1.5, dots: false)
            }
        }
        draw(v, additive: false, enc: enc)
    }

    private func darkenCenter(alpha: Float, enc: MTLRenderCommandEncoder, aspect: (Double, Double)) {
        let n = 24
        var v: [ColorVertex] = []
        let ci = SIMD4<Float>(0, 0, 0, 3.0 / 32 * alpha)
        for k in 0..<n {
            let a0 = Double(k) / Double(n) * 2 * .pi, a1 = Double(k + 1) / Double(n) * 2 * .pi
            let p0 = clip(0.5 + 0.05 * cos(a0) * aspect.0, 0.5 + 0.05 * sin(a0) * aspect.1)
            let p1 = clip(0.5 + 0.05 * cos(a1) * aspect.0, 0.5 + 0.05 * sin(a1) * aspect.1)
            v += [ColorVertex(x: 0, y: 0, r: 0, g: 0, b: 0, a: ci.w), ColorVertex(x: p0.0, y: p0.1, r: 0, g: 0, b: 0, a: 0),
                  ColorVertex(x: p1.0, y: p1.1, r: 0, g: 0, b: 0, a: 0)]
        }
        draw(v, additive: false, enc: enc)
    }

    /// Outer and inner border: frames `ob_size` / `ib_size` of the screen wide.
    private func borders(_ rt: MilkRuntime, alpha: Float, enc: MTLRenderCommandEncoder) {
        var inset: Float = 0
        for pre in ["ob", "ib"] {
            let size = Float(max(0, min(0.5, rt["\(pre)_size"]))) * 2
            let c = SIMD4(Float(rt["\(pre)_r"]), Float(rt["\(pre)_g"]), Float(rt["\(pre)_b"]), Float(rt["\(pre)_a"]) * alpha)
            defer { inset += size }
            guard size > 0, c.w > 0.001 else { continue }
            let o = 1 - inset, i = 1 - inset - size
            func rect(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> [ColorVertex] {
                [ColorVertex(x: x0, y: y0, r: c.x, g: c.y, b: c.z, a: c.w), ColorVertex(x: x1, y: y0, r: c.x, g: c.y, b: c.z, a: c.w),
                 ColorVertex(x: x0, y: y1, r: c.x, g: c.y, b: c.z, a: c.w), ColorVertex(x: x1, y: y0, r: c.x, g: c.y, b: c.z, a: c.w),
                 ColorVertex(x: x1, y: y1, r: c.x, g: c.y, b: c.z, a: c.w), ColorVertex(x: x0, y: y1, r: c.x, g: c.y, b: c.z, a: c.w)]
            }
            draw(rect(-o, i, o, o) + rect(-o, -o, o, -i) + rect(-o, -i, -i, i) + rect(i, -i, o, i), additive: false, enc: enc)
        }
    }

    // MARK: Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; float4 color; };

    struct WarpIn { packed_float2 pos; packed_float2 uv; };
    vertex VOut warp_v(const device WarpIn* v [[buffer(0)]], uint id [[vertex_id]]) {
        VOut o; o.pos = float4(float2(v[id].pos), 0, 1); o.uv = float2(v[id].uv); o.color = float4(1); return o;
    }
    fragment float4 warp_f(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                           constant float& decay [[buffer(0)]]) {
        return float4(t.sample(s, in.uv).rgb * decay, 1);
    }

    struct ColIn { packed_float2 pos; packed_float4 color; };
    vertex VOut col_v(const device ColIn* v [[buffer(0)]], uint id [[vertex_id]]) {
        VOut o; o.pos = float4(float2(v[id].pos), 0, 1); o.uv = float2(0); o.color = float4(v[id].color); return o;
    }
    fragment float4 col_f(VOut in [[stage_in]]) { return in.color; }

    struct TexIn { packed_float2 pos; packed_float4 color; packed_float2 uv; };
    vertex VOut tex_v(const device TexIn* v [[buffer(0)]], uint id [[vertex_id]]) {
        VOut o; o.pos = float4(float2(v[id].pos), 0, 1); o.uv = float2(v[id].uv); o.color = float4(v[id].color); return o;
    }
    fragment float4 tex_f(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
        return float4(t.sample(s, in.uv).rgb * in.color.rgb, in.color.a);
    }

    struct CompU { float gamma; float echoAlpha; float echoZoom; int echoOrient; int brighten; int darken; int solarize; int invert; };
    vertex VOut comp_v(uint id [[vertex_id]]) {
        float2 p = float2((id << 1) & 2, id & 2);
        VOut o; o.pos = float4(p * 2 - 1, 0, 1); o.uv = float2(p.x, 1 - p.y); o.color = float4(1); return o;
    }
    fragment float4 comp_f(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                           constant CompU& u [[buffer(0)]]) {
        float3 c = t.sample(s, in.uv).rgb;
        if (u.echoAlpha > 0.001) {
            float2 e = (in.uv - 0.5) / u.echoZoom + 0.5;
            if (u.echoOrient & 1) e.x = 1 - e.x;
            if (u.echoOrient & 2) e.y = 1 - e.y;
            c = mix(c, t.sample(s, e).rgb, u.echoAlpha);
        }
        c = saturate(c * u.gamma);
        if (u.brighten) c = sqrt(c);
        if (u.darken) c = c * c;
        if (u.solarize) c = c * (1 - c) * 4;
        if (u.invert) c = 1 - c;
        return float4(c, 1);
    }
    """
}
