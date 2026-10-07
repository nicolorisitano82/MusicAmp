import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

// Milkdrop on Metal. Each frame:
//  1. warp: the previous frame is drawn through a 48×36 mesh whose texture coordinates come from the
//     zoom/rot/warp/cx/cy/dx/dy/sx/sy values (per-pixel code runs once per vertex). Milkdrop 1 presets
//     darken it by `decay`; Milkdrop 2 presets run their own warp shader (HLSL translated to Metal);
//  2. motion vectors, custom shapes, custom waves, the main waveform, darken-center and borders are drawn
//     on top, into the same feedback texture (so they get warped on the next frames);
//  3. blur1/2/3 (½, ¼, ⅛ size) are made from it when a shader reads them;
//  4. composite to the screen: the preset's comp shader, or video echo + gamma + brighten/darken/solarize/invert.
// Presets switch with a 2.7 s cross-fade: both presets draw every pass, the new one blended in with a
// constant blend factor.

/// A preset ready to draw: its equations plus its compiled Milkdrop 2 shaders (nil = fixed pipeline).
final class MilkPrepared {
    let runtime: MilkRuntime
    var warp: MTLRenderPipelineState?
    var comp: MTLRenderPipelineState?
    var warpUser: [MTLTexture] = []
    var compUser: [MTLTexture] = []
    var usesBlur = false
    var notes: [String] = []
    let randPreset = SIMD4<Float>(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
    let rotAxes: [SIMD3<Float>] = (0..<24).map { _ in simd_normalize(SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) + 0.001) }
    let rotPhase: [Float] = (0..<24).map { _ in Float.random(in: 0...(2 * .pi)) }
    init(_ rt: MilkRuntime) { runtime = rt }
    var name: String { runtime.preset.name }
}

final class MilkdropRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let warpPipe, colorPipe, colorAddPipe, texPipe, texAddPipe, compPipe: MTLRenderPipelineState
    private let samplers: [MTLSamplerState]   // linear wrap, linear clamp, point wrap, point clamp
    private var wrapSampler: MTLSamplerState { samplers[0] }
    private var clampSampler: MTLSamplerState { samplers[1] }
    private var feedback: [MTLTexture] = []
    private var blur: [MTLTexture] = [], blurTmp: [MTLTexture] = []
    private let noiseLQ, noiseMQ, noiseHQ, volLQ, volHQ, black: MTLTexture
    private lazy var mpsScale = MPSImageBilinearScale(device: device)
    private lazy var mpsBlur = MPSImageGaussianBlur(device: device, sigma: 1.6)
    private var userTextureCache: [String: MTLTexture] = [:]
    private let cacheLock = NSLock()
    private var cur = 0
    private let meshIndex: MTLBuffer
    private let meshIndexCount: Int

    private(set) var current: MilkPrepared?
    private var previous: MilkPrepared?
    var runtime: MilkRuntime? { current?.runtime }
    private var blendStart = 0.0
    private var installedAt = 0.0
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
                try MilkdropRenderer.pipeline(device, lib, v, f, blend: blend)
            }
            warpPipe = try pipe("warp_v", "warp_f", blend: 3)
            colorPipe = try pipe("col_v", "col_f", blend: 1)
            colorAddPipe = try pipe("col_v", "col_f", blend: 2)
            texPipe = try pipe("tex_v", "tex_f", blend: 1)
            texAddPipe = try pipe("tex_v", "tex_f", blend: 2)
            compPipe = try pipe("comp_v", "comp_f", blend: 3)
        } catch {
            NSLog("Milkdrop shaders: %@", "\(error)")
            return nil
        }
        samplers = [(MTLSamplerMinMagFilter.linear, MTLSamplerAddressMode.repeat), (.linear, .clampToEdge), (.nearest, .repeat), (.nearest, .clampToEdge)].map { f, a in
            let d = MTLSamplerDescriptor()
            d.minFilter = f
            d.magFilter = f
            d.sAddressMode = a
            d.tAddressMode = a
            d.rAddressMode = a
            return device.makeSamplerState(descriptor: d)!
        }
        noiseLQ = MilkdropRenderer.noise2D(device, grid: 256)
        noiseMQ = MilkdropRenderer.noise2D(device, grid: 64)
        noiseHQ = MilkdropRenderer.noise2D(device, grid: 32)
        volLQ = MilkdropRenderer.noise3D(device, grid: 32)
        volHQ = MilkdropRenderer.noise3D(device, grid: 8)
        black = MilkdropRenderer.noise2D(device, grid: 1, size: 1, value: 0)
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

    /// blend: 0 opaque, 1 alpha, 2 additive, 3 constant factor (cross-fade between presets).
    static func pipeline(_ device: MTLDevice, _ lib: MTLLibrary, _ v: String, _ f: String, blend: Int) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let a = d.colorAttachments[0]!
        a.pixelFormat = MilkdropRenderer.format
        if blend > 0 {
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            switch blend {
            case 3:
                a.sourceRGBBlendFactor = .blendAlpha
                a.destinationRGBBlendFactor = .oneMinusBlendAlpha
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .zero
            default:
                a.sourceRGBBlendFactor = .sourceAlpha
                a.destinationRGBBlendFactor = blend == 1 ? .oneMinusSourceAlpha : .one
                a.sourceAlphaBlendFactor = .one
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
        }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Presets

    /// Compiles the preset's equations and shaders. Thread-safe: call it off the main thread.
    func prepare(_ preset: MilkPreset) -> MilkPrepared {
        let pr = MilkPrepared(MilkRuntime(preset))
        func build(_ src: String, _ stage: HLSLTranslator.Stage) -> (MTLRenderPipelineState, [MTLTexture])? {
            guard src.contains("shader_body") else { return nil }
            let label = stage == .warp ? "warp" : "comp"
            do {
                let tr = HLSLTranslator(stage: stage)
                let msl = try tr.translate(src, entry: "md_main")
                let opts = MTLCompileOptions()
                opts.fastMathEnabled = true
                let lib = try device.makeLibrary(source: MDShaderPrelude.source + msl, options: opts)
                let p = try MilkdropRenderer.pipeline(device, lib, stage == .warp ? "md_warp_v" : "md_comp_v", "md_main", blend: 3)
                if tr.usesBlur { pr.usesBlur = true }
                return (p, tr.userTextures.map { userTexture($0, near: preset.url) })
            } catch {
                let msg = "\(error)".components(separatedBy: .newlines).first { $0.contains("error") } ?? "\(error)".components(separatedBy: .newlines).first ?? ""
                pr.notes.append("shader \(label): \(msg.prefix(160))")
                return nil
            }
        }
        if let (p, u) = build(preset.warpShader, .warp) { pr.warp = p; pr.warpUser = u }
        if let (p, u) = build(preset.compShader, .comp) { pr.comp = p; pr.compUser = u }
        return pr
    }

    func install(_ pr: MilkPrepared, blend: Bool = true) {
        if blend, let c = current {
            previous = c
            blendStart = now
        } else {
            previous = nil
        }
        current = pr
        installedAt = now
    }

    func load(_ preset: MilkPreset, blend: Bool = true) { install(prepare(preset), blend: blend) }

    /// A preset's own texture (sampler_clouds → clouds.jpg next to the preset or in Milkdrop/textures), else noise.
    private func userTexture(_ name: String, near: URL?) -> MTLTexture {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let t = userTextureCache[name] { return t }
        var dirs = [MilkdropLibrary.folder.appendingPathComponent("textures"), MilkdropLibrary.folder]
        if let near { dirs.insert(near.deletingLastPathComponent(), at: 0); dirs.insert(near.deletingLastPathComponent().appendingPathComponent("textures"), at: 1) }
        let loader = MTKTextureLoader(device: device)
        for d in dirs {
            guard let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.deletingPathExtension().lastPathComponent.lowercased() == name.lowercased()
                && ["jpg", "jpeg", "png", "bmp", "tga", "tif", "tiff", "gif"].contains(f.pathExtension.lowercased()) {
                if let t = try? loader.newTexture(URL: f, options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]) {
                    userTextureCache[name] = t
                    return t
                }
            }
        }
        return noiseHQ
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
        guard let curP = current else { return nil }
        let w = target.width, h = target.height
        ensureFeedback(w, h)
        let t = now
        let dt = max(1.0 / 240, min(0.25, t - lastTime))
        lastTime = t
        fps = fps * 0.9 + (1 / dt) * 0.1
        frameNo += 1
        let aspect = (w > h ? Double(h) / Double(w) : 1, h > w ? Double(w) / Double(h) : 1)
        let audio = lastAudio

        curP.runtime.runFrame(time: t, frameNo: frameNo, fps: fps, audio: audio, aspect: aspect, size: (w, h))
        var p = 1.0
        var layers: [(MilkPrepared, Float)] = [(curP, 1)]
        if let pr = previous {
            p = min(1, (t - blendStart) / blendDuration)
            p = p * p * (3 - 2 * p)   // smoothstep
            if p >= 1 { previous = nil } else {
                pr.runtime.runFrame(time: t, frameNo: frameNo, fps: fps, audio: audio, aspect: aspect, size: (w, h))
                layers = [(pr, 1), (curP, Float(p))]
            }
        }
        let meshes = layers.map { warpMesh($0.0.runtime, time: t, aspect: aspect) }

        let src = feedback[cur], dst = feedback[1 - cur]
        guard let cb = cbExternal ?? queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = dst
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }

        // 1. Warp: each layer through its own mesh and warp shader, the new preset faded in on top.
        for (i, (pr, alpha)) in layers.enumerated() {
            let rt = pr.runtime
            enc.setBlendColor(red: 0, green: 0, blue: 0, alpha: alpha)
            guard let mb = meshes[i].withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count) }) else { continue }
            enc.setVertexBuffer(mb, offset: 0, index: 0)
            if let wp = pr.warp {
                enc.setRenderPipelineState(wp)
                var u = uniforms(pr, time: t, size: (w, h), aspect: aspect, audio: audio, user: pr.warpUser)
                enc.setFragmentBytes(&u, length: u.count * 16, index: 0)
                bindShaderResources(enc, main: src, user: pr.warpUser)
            } else {
                enc.setRenderPipelineState(warpPipe)
                var decay = Float(max(0, min(1, rt["decay"])))
                enc.setFragmentBytes(&decay, length: 4, index: 0)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentSamplerState(rt["wrap"] != 0 ? wrapSampler : clampSampler, index: 0)
            }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount, indexType: .uint32, indexBuffer: meshIndex, indexBufferOffset: 0)
        }

        // 2. Drawings on top (the outgoing preset fades out, the new one in).
        let px = Float(2.0 / Double(h))   // one pixel in clip units (vertical)
        for (i, (pr, _)) in layers.enumerated() {
            let r = pr.runtime
            let alpha = layers.count == 1 ? 1 : (i == 0 ? Float(1 - p) : Float(p))
            motionVectors(r, mesh: meshes[i], alpha: alpha, enc: enc, px: px)
            shapes(r, alpha: alpha, enc: enc, src: src, aspect: aspect, px: px)
            customWaves(r, audio: audio, alpha: alpha, enc: enc, px: px)
            mainWave(r, audio: audio, time: t, alpha: alpha, enc: enc, aspect: aspect, px: px)
            if r["darken_center"] != 0 { darkenCenter(alpha: alpha, enc: enc, aspect: aspect) }
            borders(r, alpha: alpha, enc: enc)
        }
        enc.endEncoding()

        // 3. Blur pyramid for shaders that read it.
        if layers.contains(where: { $0.0.usesBlur }) { encodeBlur(cb, from: dst) }

        // 4. Composite to the target.
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = target
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        guard let ce = cb.makeRenderCommandEncoder(descriptor: cp) else { return nil }
        for (pr, alpha) in layers {
            let rt = pr.runtime
            ce.setBlendColor(red: 0, green: 0, blue: 0, alpha: alpha)
            if let c = pr.comp {
                ce.setRenderPipelineState(c)
                var u = uniforms(pr, time: t, size: (w, h), aspect: aspect, audio: audio, user: pr.compUser)
                ce.setFragmentBytes(&u, length: u.count * 16, index: 0)
                bindShaderResources(ce, main: dst, user: pr.compUser)
            } else {
                ce.setRenderPipelineState(compPipe)
                var u = CompUniforms(gamma: Float(max(0.1, rt["gamma"])), echoAlpha: Float(max(0, min(1, rt["echo_alpha"]))),
                                     echoZoom: Float(max(0.01, rt["echo_zoom"])), echoOrient: Int32(rt["echo_orient"]) & 3,
                                     brighten: rt["brighten"] != 0 ? 1 : 0, darken: rt["darken"] != 0 ? 1 : 0,
                                     solarize: rt["solarize"] != 0 ? 1 : 0, invert: rt["invert"] != 0 ? 1 : 0)
                ce.setFragmentBytes(&u, length: MemoryLayout<CompUniforms>.stride, index: 0)
                ce.setFragmentTexture(dst, index: 0)
                ce.setFragmentSamplerState(clampSampler, index: 0)
            }
            ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        ce.endEncoding()
        cur = 1 - cur
        return cb
    }

    private struct CompUniforms {
        var gamma: Float, echoAlpha: Float, echoZoom: Float, echoOrient: Int32
        var brighten: Int32, darken: Int32, solarize: Int32, invert: Int32
    }

    // MARK: Milkdrop 2 shader environment

    private func bindShaderResources(_ enc: MTLRenderCommandEncoder, main: MTLTexture, user: [MTLTexture]) {
        enc.setFragmentTexture(main, index: 0)
        for i in 0..<3 { enc.setFragmentTexture(i < blur.count ? blur[i] : black, index: 1 + i) }
        enc.setFragmentTexture(noiseLQ, index: 4)
        enc.setFragmentTexture(noiseMQ, index: 5)
        enc.setFragmentTexture(noiseHQ, index: 6)
        enc.setFragmentTexture(volLQ, index: 7)
        enc.setFragmentTexture(volHQ, index: 8)
        for i in 0..<8 { enc.setFragmentTexture(i < user.count ? user[i] : noiseHQ, index: 9 + i) }
        for (i, s) in samplers.enumerated() { enc.setFragmentSamplerState(s, index: i) }
    }

    /// The `U.v[]` block of MDUniforms for one preset and stage.
    private func uniforms(_ pr: MilkPrepared, time t: Double, size: (Int, Int), aspect: (Double, Double), audio: MilkAudio, user: [MTLTexture]) -> [SIMD4<Float>] {
        let rt = pr.runtime
        var v = [SIMD4<Float>](repeating: .zero, count: MDUniforms.count)
        let ft = Float(t)
        let progress = Float(min(1, max(0, (t - installedAt) / 20)))
        v[0] = SIMD4(ft, Float(fps), Float(frameNo), progress)
        let vol = (audio.bass + audio.mid + audio.treb) / 3, volAtt = (audio.bassAtt + audio.midAtt + audio.trebAtt) / 3
        v[1] = SIMD4(Float(audio.bass), Float(audio.mid), Float(audio.treb), Float(vol))
        v[2] = SIMD4(Float(audio.bassAtt), Float(audio.midAtt), Float(audio.trebAtt), Float(volAtt))
        v[3] = SIMD4(Float(aspect.0), Float(aspect.1), Float(1 / aspect.0), Float(1 / aspect.1))
        v[4] = SIMD4(Float(size.0), Float(size.1), 1 / Float(size.0), 1 / Float(size.1))
        v[5] = SIMD4(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
        v[6] = pr.randPreset
        let roam = SIMD4<Float>(0.13, 0.09, 0.055, 0.043) * ft
        v[7] = 0.5 + 0.5 * SIMD4(cos(roam.x), cos(roam.y), cos(roam.z), cos(roam.w))
        v[8] = 0.5 + 0.5 * SIMD4(sin(roam.x), sin(roam.y), sin(roam.z), sin(roam.w))
        let slow = roam * 0.1
        v[9] = 0.5 + 0.5 * SIMD4(cos(slow.x), cos(slow.y), cos(slow.z), cos(slow.w))
        v[10] = 0.5 + 0.5 * SIMD4(sin(slow.x), sin(slow.y), sin(slow.z), sin(slow.w))
        v[11] = SIMD4(Float(rt["b1n"]), Float(rt["b1x"]), Float(rt["b2n"]), Float(rt["b2x"]))
        v[12] = SIMD4(Float(rt["b3n"]), Float(rt["b3x"]), 0, 0)
        // hue_shader: four slowly cycling corner colours, normalised to full brightness.
        for i in 0..<4 {
            let fi = Float(i), r = pr.randPreset
            var c = SIMD3<Float>(0.6 + 0.3 * sin(ft * 0.429 + 3 + fi * 21 + r.x * 6),
                                 0.6 + 0.3 * sin(ft * 0.553 + 1 + fi * 13 + r.y * 6),
                                 0.6 + 0.3 * sin(ft * 0.495 + 5 + fi * 9 + r.z * 6))
            c /= max(c.x, max(c.y, c.z))
            v[MDUniforms.hueBase + i] = SIMD4(c, 1)
        }
        for q in 0..<32 { v[17 + q / 4][q % 4] = Float(rt["q\(q + 1)"]) }
        // rot_s1…rot_rand4: rotations at increasing speeds (slow, default, fast, very fast, ultra fast, fixed).
        let speeds: [Float] = [0.02, 0.08, 0.3, 0.9, 2.4, 0]
        for i in 0..<24 {
            let axis = pr.rotAxes[i]
            let angle = speeds[i / 4] * ft * (1 + 0.37 * Float(i % 4)) + pr.rotPhase[i]
            let m = simd_float3x3(simd_quatf(angle: angle, axis: axis))
            let b = 25 + i * 4
            v[b] = SIMD4(m.columns.0, 0); v[b + 1] = SIMD4(m.columns.1, 0); v[b + 2] = SIMD4(m.columns.2, 0); v[b + 3] = SIMD4(0, 0, 0, 1)
        }
        for (i, tex) in user.prefix(8).enumerated() {
            v[MDUniforms.userTexSizeBase + i] = SIMD4(Float(tex.width), Float(tex.height), 1 / Float(tex.width), 1 / Float(tex.height))
        }
        return v
    }

    private func encodeBlur(_ cb: MTLCommandBuffer, from main: MTLTexture) {
        guard blur.count == 3, blurTmp.count == 3 else { return }
        var source = main
        for i in 0..<3 {
            mpsScale.encode(commandBuffer: cb, sourceTexture: source, destinationTexture: blurTmp[i])
            mpsBlur.encode(commandBuffer: cb, sourceTexture: blurTmp[i], destinationTexture: blur[i])
            source = blur[i]
        }
    }

    static func noise2D(_ device: MTLDevice, grid: Int, size: Int = 256, value: UInt8? = nil) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        var px = [UInt8](repeating: value ?? 0, count: size * size * 4)
        if value == nil {
            // Random values on a grid, smoothly interpolated: grid == size gives white noise.
            let g = (0..<(grid * grid * 4)).map { _ in Float.random(in: 0...1) }
            for y in 0..<size {
                for x in 0..<size {
                    let fx = Float(x) * Float(grid) / Float(size), fy = Float(y) * Float(grid) / Float(size)
                    let x0 = Int(fx) % grid, y0 = Int(fy) % grid, x1 = (x0 + 1) % grid, y1 = (y0 + 1) % grid
                    var tx = fx - Float(Int(fx)), ty = fy - Float(Int(fy))
                    tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
                    for c in 0..<4 {
                        func at(_ i: Int, _ j: Int) -> Float { g[(j * grid + i) * 4 + c] }
                        let v = (at(x0, y0) * (1 - tx) + at(x1, y0) * tx) * (1 - ty) + (at(x0, y1) * (1 - tx) + at(x1, y1) * tx) * ty
                        px[(y * size + x) * 4 + c] = UInt8(max(0, min(255, v * 255)))
                    }
                }
            }
        }
        t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: px, bytesPerRow: size * 4)
        return t
    }

    static func noise3D(_ device: MTLDevice, grid: Int, size: Int = 32) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type3D
        d.pixelFormat = .rgba8Unorm
        d.width = size; d.height = size; d.depth = size
        let t = device.makeTexture(descriptor: d)!
        let g = (0..<(grid * grid * grid * 4)).map { _ in Float.random(in: 0...1) }
        var px = [UInt8](repeating: 0, count: size * size * size * 4)
        for z in 0..<size {
            for y in 0..<size {
                for x in 0..<size {
                    let f = SIMD3<Float>(Float(x), Float(y), Float(z)) * Float(grid) / Float(size)
                    let i0 = SIMD3<Int>(Int(f.x) % grid, Int(f.y) % grid, Int(f.z) % grid)
                    let i1 = SIMD3<Int>((i0.x + 1) % grid, (i0.y + 1) % grid, (i0.z + 1) % grid)
                    var tt = f - SIMD3<Float>(Float(Int(f.x)), Float(Int(f.y)), Float(Int(f.z)))
                    tt = tt * tt * (3 - 2 * tt)
                    for c in 0..<4 {
                        func at(_ a: Int, _ b: Int, _ cc: Int) -> Float { g[((cc * grid + b) * grid + a) * 4 + c] }
                        func lerp(_ a: Float, _ b: Float, _ s: Float) -> Float { a + (b - a) * s }
                        let v = lerp(lerp(lerp(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), tt.x), lerp(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), tt.x), tt.y),
                                     lerp(lerp(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), tt.x), lerp(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), tt.x), tt.y), tt.z)
                        px[((z * size + y) * size + x) * 4 + c] = UInt8(max(0, min(255, v * 255)))
                    }
                }
            }
        }
        t.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: px, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        return t
    }

    private func ensureFeedback(_ w: Int, _ h: Int) {
        if let f = feedback.first, f.width == w, f.height == h { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkdropRenderer.format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        feedback = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        func level(_ k: Int) -> MTLTexture? {
            let bd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(1, w >> k), height: max(1, h >> k), mipmapped: false)
            bd.usage = [.shaderRead, .shaderWrite, .renderTarget]
            bd.storageMode = .private
            return device.makeTexture(descriptor: bd)
        }
        blur = (1...3).compactMap(level)
        blurTmp = (1...3).compactMap(level)
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
