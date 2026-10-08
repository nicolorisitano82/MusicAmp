import AppKit
import SwiftUI
import Metal
import CommonCrypto
import AVFoundation
import Accelerate
import MusicAmpShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var started = false
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.mainMenu = buildMenu()
        Ctl.shared.start()
        started = true
        if !pending.isEmpty { Ctl.shared.handleDrop(pending, toPlaylist: false) }
        pendingCommands.forEach(WidgetBridge.shared.handle)
        // Launched in the background by a widget button or a musicamp:// command: stay behind.
        if pendingCommands.isEmpty || pendingCommands.contains(where: { $0.host == "open" }) { NSApp.activate(ignoringOtherApps: true) }
    }
    private var pendingCommands: [URL] = []

    func application(_ app: NSApplication, open urls: [URL]) {
        // musicamp://play, …/next, …/sleep?minutes=30: commands from the widget, Shortcuts, scripts.
        let commands = urls.filter { $0.scheme?.lowercased() == "musicamp" }
        let files = urls.filter { $0.scheme?.lowercased() != "musicamp" }
        if started { commands.forEach(WidgetBridge.shared.handle) } else { pendingCommands += commands }
        guard !files.isEmpty else { return }
        if started { Ctl.shared.handleDrop(files, toPlaylist: false) } else { pending += files }
    }

    func applicationWillTerminate(_ n: Notification) {
        Ctl.shared.saveSettings()
        WidgetBridge.shared.terminated()
        PlayStats.shared.save()
        Ctl.shared.audio.restoreDeviceRate()   // bit-perfect: give the device its rate back
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Ctl.shared.mainWindow.makeKeyAndOrderFront(nil) }
        return true
    }

    private func buildMenu() -> NSMenu {
        let c = Ctl.shared
        let bar = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            it.submenu = m
            bar.addItem(it)
            return m
        }

        let app = sub("MusicAmp")
        app.addItem(withTitle: "About MusicAmp", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        c.item(app, "Settings…", #selector(Ctl.showPreferences), ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide MusicAmp", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit MusicAmp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Standard Edit menu: text fields (library search, preferences, Jump to file) get ⌘A ⌘C ⌘V ⌘X ⌘Z from it.
        let edit = sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let find = edit.addItem(withTitle: "Find in Playlist", action: #selector(Ctl.searchPlaylist), keyEquivalent: "f")
        find.target = c
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let file = sub("File")
        // macOS order: File before Edit.
        if let fi = bar.items.firstIndex(where: { $0.submenu === file }), let ei = bar.items.firstIndex(where: { $0.submenu === edit }), fi > ei {
            let item = bar.items[fi]
            bar.removeItem(item)
            bar.insertItem(item, at: ei)
        }
        c.item(file, "Open Files…", #selector(Ctl.openFiles), "o")
        c.item(file, "Add Files…", #selector(Ctl.addFiles), "o", [.command, .shift])
        c.item(file, "Add Folder…", #selector(Ctl.addFolder))
        c.item(file, "Open URL…", #selector(Ctl.openURL), "u")
        file.addItem(.separator())
        c.item(file, "Load Playlist…", #selector(Ctl.loadPlaylistFile))
        c.item(file, "Save Playlist…", #selector(Ctl.savePlaylistFile), "s")
        let smart = NSMenuItem(title: "Smart Playlists", action: nil, keyEquivalent: "")
        smart.submenu = SmartPlaylistStore.shared.menu()
        file.addItem(smart)
        file.addItem(.separator())
        c.item(file, "File Info…", #selector(Ctl.fileInfo), "i")
        c.item(file, "Edit Tags…", #selector(Ctl.showTagEditor), "i", [.command, .option])

        let play = sub("Controls")
        // Winamp letter keys (Z X C V B, J, Q…) are handled by the skin windows, not as menu key equivalents:
        // as menu shortcuts they would fire while typing in the library or preferences search fields.
        c.item(play, "Previous (Z)", #selector(Ctl.previous))
        c.item(play, "Play (X)", #selector(Ctl.play))
        c.item(play, "Pause (C)", #selector(Ctl.pause))
        c.item(play, "Stop (V)", #selector(Ctl.stop))
        c.item(play, "Next (B)", #selector(Ctl.next as (Ctl) -> () -> Void))
        play.addItem(.separator())
        c.item(play, "Jump to File… (J)", #selector(Ctl.showJumpToFile))
        c.item(play, "Queue / Dequeue (Q)", #selector(Ctl.queueSelected))
        c.item(play, "Clear Queue", #selector(Ctl.clearQueue))
        play.addItem(.separator())
        let speed = NSMenuItem(title: "Speed and Pitch", action: nil, keyEquivalent: "")
        speed.submenu = c.speedMenu()
        play.addItem(speed)
        c.item(play, "Back 15 Seconds", #selector(Ctl.skipBack15), String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), [.command, .option])
        c.item(play, "Forward 30 Seconds", #selector(Ctl.skipForward30), String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.command, .option])
        play.addItem(.separator())
        c.item(play, "Shuffle (S)", #selector(Ctl.toggleShuffle))
        c.item(play, "Repeat (R)", #selector(Ctl.toggleRepeat))
        c.item(play, "Time Remaining", #selector(Ctl.toggleTimeRemaining))
        play.addItem(.separator())
        c.item(play, "Remove Vocals (Karaoke)", #selector(Ctl.toggleVocalRemover), "v", [.command, .option])
        let rate = NSMenuItem(title: "Rate Current Track", action: nil, keyEquivalent: "")
        rate.submenu = c.ratingMenu(#selector(Ctl.rateCurrent(_:)), current: nil, keys: true)
        play.addItem(rate)
        let sleep = NSMenuItem(title: "Sleep Timer and Alarm", action: nil, keyEquivalent: "")
        sleep.submenu = Scheduler.shared.sleepMenu()
        play.addItem(sleep)

        let skins = sub("Skin")
        skins.delegate = c

        let view = sub("View")
        c.item(view, "Equalizer", #selector(Ctl.toggleEQ), "g", [.option])
        c.item(view, "Playlist", #selector(Ctl.togglePL), "e", [.option])
        c.item(view, "Library", #selector(Ctl.showLibrary), "l", [.option])
        c.item(view, "Radio", #selector(Ctl.showRadio), "r", [.option])
        c.item(view, "Podcast", #selector(Ctl.showPodcasts), "p", [.option])
        c.item(view, "Lyrics", #selector(Ctl.showLyrics), "t", [.command, .option])
        c.item(view, "Album Art", #selector(Ctl.showAlbumArt), "a", [.command, .option])
        c.item(view, "Smart Playlists", #selector(Ctl.showSmartPlaylists), "s", [.command, .option])
        c.item(view, "Sonic Mix", #selector(Ctl.showSonicMix), "x", [.command, .option])
        c.item(view, "Full-Screen Karaoke", #selector(Ctl.showKaraoke), "k", [.command, .option])
        c.item(view, "Milkdrop", #selector(Ctl.showMilkdrop), "m", [.command, .option])
        view.addItem(.separator())
        c.item(view, "Windowshade Mode", #selector(Ctl.toggleMainShade), "w", [.option])
        c.item(view, "Equalizer Windowshade", #selector(Ctl.toggleEQShade), "w", [.option, .shift])
        c.item(view, "Playlist Windowshade", #selector(Ctl.togglePLShade), "w", [.control, .option])
        c.item(view, "Double Size", #selector(Ctl.toggleDoubleSize), "d")
        c.item(view, "Group Playlist by Artist and Album", #selector(Ctl.togglePlTree), "g", [.command, .option])
        c.item(view, "Always on Top", #selector(Ctl.toggleAlwaysOnTop), "a", [.option])
        let vis = NSMenuItem(title: "Visualization", action: nil, keyEquivalent: "")
        vis.submenu = c.visMenu()
        view.addItem(vis)

        return bar
    }
}

// Test runs never touch the real play statistics (stats.json).
if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-") || $0 == "--self-test" }) { PlayStats.shared.inMemory = true }

/// Debug: `MusicAmp --snapshot <skin.wsz|-> <out.png>` renders main/EQ/playlist stacked, then exits.
func snapshot(_ args: [String]) -> Never {
    let c = Ctl.shared
    if args[0] != "-" {
        do { c.skin = try Skin.load(from: URL(fileURLWithPath: args[0])) } catch { print("skin error: \(error)"); exit(1) }
    }
    c.bands = [-12, -6, 0, 6, 12, 6, 0, -6, -12, 3]
    c.preamp = 4
    c.playlist.tracks = ["Artist - First Song", "Another Artist - Second Song With A Long Title"].map {
        let t = Track(url: URL(fileURLWithPath: "/tmp/\($0).mp3"))
        t.duration = 215
        return t
    }
    c.playlist.selection = [1]
    if ProcessInfo.processInfo.environment["MUSICAMP_DEMO"] != nil {
        // README screenshots: a believable (made-up) playlist, the third track playing.
        let demo: [(String, String, String, Double)] = [
            ("The Skin Collectors", "Pixel Perfect", "Bitmap Hearts", 214), ("The Skin Collectors", "Region.txt", "Bitmap Hearts", 188),
            ("The Skin Collectors", "Ten Bands of Gold", "Bitmap Hearts", 233), ("Pixel Orchestra", "Midnight Visualizer", "Shader Bloom", 251),
            ("Pixel Orchestra", "Chroma Tunnel", "Shader Bloom", 302), ("Pixel Orchestra", "Equal Power", "Crossfade Suite", 246),
            ("Pixel Orchestra", "No Pause Between Us", "Crossfade Suite", 197), ("Retina Twins", "Double Pixels", "@2x", 221),
            ("Retina Twins", "Nearest Neighbour", "@2x", 205), ("Retina Twins", "Journey from A to B", "@2x", 279),
        ]
        c.playlist.tracks = demo.map { a, s, al, d in
            let t = Track(url: URL(fileURLWithPath: "/tmp/\(a) - \(s).mp3"), title: "\(a) - \(s)")
            t.artist = a; t.songTitle = s; t.duration = d; t.album = al
            return t
        }
        c.playlist.currentTrack = c.playlist.tracks[3]
        c.playlist.selection = [3]
    }
    if let q = ProcessInfo.processInfo.environment["MUSICAMP_SEARCH"] {
        c.plView.setSearch(q)
        print("search \"\(q)\": \(c.plView.searchMatches.count) results \(c.plView.searchMatches)")
    }
    if ProcessInfo.processInfo.environment["MUSICAMP_TREE"] != nil {
        // Grouped view sample: two albums of one artist (the demo playlist has its own artists and albums).
        if ProcessInfo.processInfo.environment["MUSICAMP_DEMO"] == nil {
            for (i, t) in c.playlist.tracks.enumerated() { t.artist = "Artist"; t.album = i == 0 ? "First Album" : "Second Album"; t.songTitle = ["First Song", "Second Song"][i] }
        }
        c.plTree = true
    }
    let views: [SkinView] = [c.mainView, c.eqView, c.plView]
    // MUSICAMP_RETINA=1: render at 2x with the skin's @2x sheets.
    let k = ProcessInfo.processInfo.environment["MUSICAMP_RETINA"] != nil ? 2 : 1
    func renderAll() -> [CGImage] {
        views.compactMap { v -> CGImage? in
            let s = v.logicalSize
            guard let r = Renderer(width: Int(s.width), height: Int(s.height), skin: c.skin, pixelScale: k) else { return nil }
            v.render(r)
            return r.image()
        }
    }
    c.snapshotMode = true
    c.easterEgg = ProcessInfo.processInfo.environment["MUSICAMP_EGG"] != nil
    c.debugFillVis()
    var images = renderAll()
    (c.mainShade, c.eqShade, c.plW) = (true, true, 3)
    images += renderAll()
    c.plShade = true
    images += [c.plView].compactMap { v -> CGImage? in
        guard let r = Renderer(width: Int(v.logicalSize.width), height: 14, skin: c.skin, pixelScale: k) else { return nil }
        v.render(r)
        return r.image()
    }
    let info = c.makeInfoView(1)
    if let r = Renderer(width: Int(info.size.width), height: Int(info.size.height), skin: c.skin, pixelScale: k) {
        info.render(r)
        if let img = r.image() { images.append(img) }
    }
    // MUSICAMP_SNAPSHOT_PARTS=dir: every window also as its own PNG (README screenshots).
    if let dir = ProcessInfo.processInfo.environment["MUSICAMP_SNAPSHOT_PARTS"] {
        let names = ["main", "eq", "playlist", "main-shade", "eq-shade", "playlist-wide", "playlist-shade", "file-info"]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (img, name) in zip(images, names) {
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
    let w = (images.map(\.width).max() ?? 1) / k, h = images.reduce(0) { $0 + $1.height } / k
    let ctx = CGContext(data: nil, width: w * 2, height: h * 2, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    var y = h
    for img in images {
        y -= img.height / k
        ctx.draw(img, in: CGRect(x: 0, y: y * 2, width: img.width * 2 / k, height: img.height * 2 / k))
    }
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
    exit(0)
}

/// `MusicAmp --retina-check skin.wsz` / `--make-retina in.wsz out.wsz` (Scale2x @2x sheets as a starting point).
if let i = CommandLine.arguments.firstIndex(of: "--retina-check"), CommandLine.arguments.count > i + 1 {
    exit(RetinaTools.check(CommandLine.arguments[i + 1]))
}
if let i = CommandLine.arguments.firstIndex(of: "--make-retina"), CommandLine.arguments.count > i + 2 {
    exit(RetinaTools.make(CommandLine.arguments[i + 1], CommandLine.arguments[i + 2]))
}

/// Debug: `MusicAmp --test-milkdrop [out-dir]` checks the equation language, the presets and renders every built-in
/// preset offscreen with synthetic audio (optionally saving a PNG of each).
if let i = CommandLine.arguments.firstIndex(of: "--test-milkdrop") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    func eval(_ src: String, _ setup: [String: Double] = [:], read: String? = nil) -> Double {
        let c = EELContext()
        for (k, v) in setup { c[k] = v }
        let v = EEL.compile(src, c).run()
        return read.map { c[$0] } ?? v
    }
    // 1. Equations.
    check(eval("1 + 2*3 - 4/2") == 5, "eel: precedence")
    check(eval("x = 3; y = x*x; y + 1") == 10, "eel: assignments and sequence")
    check(eval("a = 2; a += 3; a *= 2; a -= 1; a /= 3", read: "a") == 3, "eel: += *= -= /=")
    check(eval("2^10") == 1024 && eval("-2^2") == -4, "eel: power")
    check(eval("if(above(bass, 1), 10, 20)", ["bass": 1.5]) == 10 && eval("if(below(1, 0), 1, 2)") == 2, "eel: if/above/below")
    check(eval("equal(0.1+0.2, 0.3) + band(1, 0) + bor(0, 3) + bnot(0)") == 3, "eel: equal/band/bor/bnot")
    check(eval("5 % 3") == 2 && eval("7 / 0") == 0 && eval("sqrt(-16)") == 4, "eel: modulo, division by zero, sqrt(|x|)")
    check(abs(eval("sin($PI/2) + cos(0) + atan2(1, 1)*4") - (2 + .pi)) < 1e-9, "eel: trigonometry and $PI")
    check(eval("min(3, max(1, 2)) + sign(-4) + abs(-2) + int(3.7) + sqr(3)") == 2 - 1 + 2 + 3 + 9, "eel: min/max/sign/abs/int/sqr")
    check(eval("x > 2 ? 7 : 9", ["x": 3]) == 7 && eval("x == 3 && y != 1", ["x": 3, "y": 2]) == 1, "eel: ?: && == !=")
    check(eval("megabuf(10) = 4; megabuf(10) * 2") == 8, "eel: megabuf")
    check(eval("n = 0; loop(5, n += 2); n") == 10, "eel: loop")
    check(eval("// comment\nX = 2; /* block */ x * 3") == 6, "eel: comments and case-insensitive names")
    check(eval("q1 = 1;;; bogus ) + ; q2 = 5", read: "q2") == 5, "eel: an error does not block the statements after it")
    let r = (0..<200).map { _ in eval("rand(10)") }
    check(r.allSatisfy { $0 >= 0 && $0 < 10 && $0 == $0.rounded() } && Set(r).count > 5, "eel: rand(n) integer in 0…n-1")

    // 2. Preset parsing.
    let milk = "[preset00]\nfDecay=0.9\nzoom=1.05\nper_frame_2=b=2;\nper_frame_1=a=1;\nper_pixel_1=rot=0.1*rad;\n" +
        "wavecode_0_enabled=1\nwavecode_0_samples=100\nwave_0_per_point1=y=0.5;\nshapecode_1_enabled=1\nshapecode_1_sides=5\n" +
        "shape_1_per_frame1=x=0.3;\nwarp_1=`shader_body {\n"
    let mp = MilkPreset.parse(milk, name: "t")
    check(mp.values["decay"] == 0.9 && mp.values["zoom"] == 1.05, "milk: base values and Milkdrop names (fDecay → decay)")
    check(mp.frameCode == "a=1;\nb=2;" && mp.pixelCode == "rot=0.1*rad;", "milk: code lines sorted by number")
    check(mp.waves[0].enabled && mp.waves[0].values["samples"] == 100 && mp.waves[0].pointCode == "y=0.5;", "milk: custom wave")
    check(mp.shapes[1].enabled && mp.shapes[1].values["sides"] == 5 && mp.shapes[1].frameCode == "x=0.3;" && mp.usesShaders, "milk: custom shape and shaders detected")
    let rt = MilkRuntime(mp)
    rt.runFrame(time: 1, frameNo: 1, fps: 60, audio: MilkAudio(), aspect: (1, 1), size: (100, 100))
    check(rt["a"] == 1 && rt["b"] == 2 && rt["decay"] == 0.9 && rt["warp"] == 1, "milk: per-frame run, defaults for missing values")
    let builtins = MilkdropBuiltins.presets
    check(builtins.count == 8 && builtins.allSatisfy { !$0.frameCode.isEmpty }, "built-in presets: \(builtins.count), all with per-frame code")

    // 2b. Milkdrop 2 shaders: HLSL → Metal, compiled for real.
    let shaderCases: [(String, String, String)] = [
        ("float4 → float3 truncation, decay in warp", "shader_body { ret = tex2D(sampler_main, uv); ret *= 0.97; }", ""),
        ("function, static const, mul with matrix, lerp/frac/saturate, q and _qa, 3D noise",
         "static const float3 tint = float3(1, 0.5, 0.25);\nfloat3 swirl(float2 p, float k) { float2x2 m = float2x2(cos(k), -sin(k), sin(k), cos(k)); return tex2D(sampler_main, mul(p - 0.5, m) + 0.5).xyz * tint; }\n" +
         "shader_body { float3 a = swirl(uv, q1*0.1 + time*0.01); float3 n = tex3D(sampler_noisevol_hq, float3(uv*4, time*0.1)).xyz; ret = lerp(a, n, 0.05) + frac(_qa.x)*0; ret = saturate(ret - 0.002); }", ""),
        ("comp: blur, hue_shader, rot_s1 cast, user texture, texsize_, for, ternary, lum", "",
         "sampler sampler_clouds2; float4 texsize_clouds2;\nshader_body { float3 acc = 0; for (int i = 0; i < 4; i++) { float s = i / 4.0; acc += GetBlur1(uv + float2(s*0.01, 0)) * 0.25; }\n" +
         " float3 p = mul(float3(uv - 0.5, 0), (float3x3)rot_s1); float3 cl = tex2D(sampler_clouds2, p.xy * texsize_clouds2.zw * 100).xyz;\n" +
         " ret = (rad > 0.4 ? acc : GetMain(uv)) * hue_shader + cl * 0.1 + lum(acc) * 0.1; ret.rg += ret.b > 0.5 ? 0.1 : 0; }"),
        ("sincos, out parameter, pow with scalar, step/smoothstep, swizzle on scalar", "",
         "void foo(float x, out float2 r) { float s, c; sincos(x, s, c); r = float2(s, c); }\n" +
         "shader_body { float2 r; foo(time, r); float3 c = GetPixel(uv + r*0.001); ret = pow(c, 1.2) * step(0.1, rad) + smoothstep(0.2, 0.8, c.g) * 0.1; ret = max(ret, 0.0); ret += bass.xxx * 0; }"),
        ("real preset constructs: macro with GetPixel, modified uniforms, redeclarations, float2x2(float4), -matrix, mul vector·vector",
         "#define PIX(p) GetPixel(p)\n#define K 0.5\nfloat2x2 m0;\nshader_body { q1 = q1 + 1; rand_preset = rand_preset.yzwx; float2 a = uv; float2 a = a * K; float2x2 r = float2x2(_qb); m0 = -r;" +
         " float d = mul(float3(a, 1), float3(1, 2, 3)); ret = PIX(mul(a - 0.5, m0) + 0.5) * d * q1 + rand_preset.x * 0; }", ""),
        ("globals used in functions, sampler_state, variable 'or', flat array, g_fTexSize, lowercase tex2d, scalar normalize", "",
         "float3 sunpos; float k = time * 0.1;\nsampler sampler_grad = sampler_state { Texture = <grad>; MipFilter = LINEAR; };\nconst float4 samples[2] = {1,0,0,1, 0,1,0,1};\n" +
         "float3 shade(float2 p) { return sunpos * k + tex2d(sampler_grad, p).xyz; }\n" +
         "shader_body { sunpos = float3(1, 0.5, 0.2); float3 or = shade(uv) * samples[1].y; ret = or + normalize(-2.0) * 0 + g_fTexSize.z; }"),
        ("mixed int and vectors, #define, while, compound on swizzle", "#define ZOOM 0.98\nshader_body { int n = 3; float2 z = (uv - 0.5) * ZOOM + 0.5; int k = 0; while (k < n) { z += 0.001 * float2(k, -k); k++; } ret = tex2D(sampler_fc_main, z).rgb; ret.xy *= 0.99; }", ""),
    ]
    if let rd0 = MilkdropRenderer() {
        for (label, warp, comp) in shaderCases {
            var pr = MilkPreset(name: "t")
            pr.warpShader = warp
            pr.compShader = comp
            let prep = rd0.prepare(pr)
            let ok = prep.notes.isEmpty && (warp.isEmpty || prep.warp != nil) && (comp.isEmpty || prep.comp != nil)
            check(ok, "md2: " + label + (ok ? "" : " — " + prep.notes.joined(separator: " | ")))
        }
        let bad = rd0.prepare({ var p = MilkPreset(name: "bad"); p.warpShader = "shader_body { ret = nonexistent_fn(uv) +; }"; return p }())
        check(bad.warp == nil && !bad.notes.isEmpty, "md2: broken shader → classic pipeline and error note")
        for p in builtins where p.usesShaders {
            let prep = rd0.prepare(p)
            check(prep.notes.isEmpty, "md2: \(p.name) compiles" + (prep.notes.isEmpty ? "" : " — " + prep.notes.joined(separator: " | ")))
        }
    }

    // 3. Offscreen rendering with synthetic audio.
    let out = CommandLine.arguments.count > i + 1 ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
    if let rd = MilkdropRenderer() {
        let w = 640, h = 360
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkdropRenderer.format, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .managed
        let tex = rd.device.makeTexture(descriptor: d)!
        func pixels() -> [UInt8] {
            let q = rd.device.makeCommandQueue()!, cb = q.makeCommandBuffer()!
            let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: tex); b.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: w * h * 4)
            tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            return px
        }
        for p in builtins {
            rd.load(p, blend: false)
            var lit = 0.0, diff = 0.0, ms = 0.0
            var prev: [UInt8] = []
            for f in 0..<150 {
                let t = Double(f) / 60
                rd.fixedTime = t
                let beat: Float = f % 30 < 4 ? 1 : 0.2
                let l = (0..<576).map { Float(sin(Double($0) * 0.11 + t * 7)) * 0.5 * beat }
                let rr = (0..<576).map { Float(cos(Double($0) * 0.07 + t * 5)) * 0.5 * beat }
                let sp = (0..<512).map { Float(max(0, 1 - Double($0) / 300)) * beat }
                rd.updateAudio(left: l, right: rr, spectrum: sp, bands: (beat * 0.02, beat * 0.01, 0.005), dt: 1 / 60)
                let t0 = Date()
                let cb = rd.render(into: tex)!
                cb.commit(); cb.waitUntilCompleted()
                ms += Date().timeIntervalSince(t0) * 1000
                if f == 149 || f == 120 {
                    let px = pixels()
                    if f == 149 {
                        lit = Double(stride(from: 0, to: px.count, by: 4).filter { Int(px[$0]) + Int(px[$0 + 1]) + Int(px[$0 + 2]) > 30 }.count) / Double(w * h)
                        diff = Double(zip(px, prev).filter { abs(Int($0) - Int($1)) > 8 }.count) / Double(px.count)
                        if let out {
                            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                            px.withUnsafeBytes { memcpy(ctx.data!, $0.baseAddress!, px.count) }
                            try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?
                                .write(to: out.appendingPathComponent(p.name + ".png"))
                        }
                    }
                    prev = px
                }
            }
            check(lit > 0.02 && diff > 0.005, String(format: "render %@: %.0f%% pixels lit, %.1f%% changed in 0.5 s, %.2f ms/frame", p.name, lit * 100, diff * 100, ms / 150))
        }
        // Blend between two presets does not crash and keeps drawing.
        rd.load(builtins[0], blend: false)
        rd.fixedTime = 10; _ = rd.render(into: tex).map { $0.commit(); $0.waitUntilCompleted() }
        rd.load(builtins[1], blend: true)
        for k in 1...20 { rd.fixedTime = 10 + Double(k) * 0.2; rd.render(into: tex).map { $0.commit(); $0.waitUntilCompleted() } }
        check(true, "blend between two presets")
    } else {
        check(false, "Metal available")
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --karaoke-snapshot out.png`: renders karaoke lines (made-up words) at chosen instants.
if let i = CommandLine.arguments.firstIndex(of: "--karaoke-snapshot"), CommandLine.arguments.count > i + 1 {
    let lrc = LRC.parse("[00:01.00]<00:01.00>la <00:01.30>luce <00:01.60>sale <00:01.90>piano <00:02.20>sooopra <00:05.20>noi\n[00:06.00]fine\n") ?? []
    let words = Lyrics(plain: nil, synced: lrc, source: "test").timedWords(0)
    let shots: [(String, Double, Double)] = [("fill halfway through \"sale\"", 1.75, 0), ("held word: start", 2.6, 0.2),
                                             ("held word: halfway, strong bass", 3.7, 0.9), ("held word: end", 5.1, 0.3)]
    MainActor.assumeIsolated {
    let view = VStack(alignment: .leading, spacing: 26) {
        ForEach(Array(shots.enumerated()), id: \.offset) { _, s in
            VStack(alignment: .leading, spacing: 6) {
                Text(s.0).font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
                KaraokeLine(words: words, now: s.1, size: 44, pulse: s.2)
            }
        }
    }
    .padding(40)
    .frame(width: 900)
    .background(Color(red: 0.1, green: 0.08, blue: 0.2))
    let r = ImageRenderer(content: view)
    r.scale = 1
    if let img = r.cgImage { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    }
    exit(0)
}

/// Debug: `MusicAmp --test-bitperfect`: device rate choice, the internal chain rebuilt at another rate, and the
/// bit-perfect diagnosis. Never changes the output device's sample rate (that is the user's system setting).
if CommandLine.arguments.contains("--test-bitperfect") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    let discrete: [ClosedRange<Double>] = [44100...44100, 48000...48000, 88200...88200, 96000...96000, 176400...176400, 192000...192000]
    check(AudioDevice.bestRate(for: 96000, supported: discrete) == 96000, "rate: same rate when supported")
    check(AudioDevice.bestRate(for: 44100, supported: [48000...48000, 88200...88200, 96000...96000]) == 88200, "rate: 44.1 kHz → 88.2 kHz (integer multiple) when 44.1 is missing")
    check(AudioDevice.bestRate(for: 44100, supported: [48000...48000, 96000...96000]) == 48000, "rate: else the lowest rate above")
    check(AudioDevice.bestRate(for: 384000, supported: discrete) == 192000, "rate: above the maximum → the highest")
    check(AudioDevice.bestRate(for: 44100, supported: [8000...192000]) == 44100 && AudioDevice.bestRate(for: 44100, supported: []) == nil, "rate: continuous ranges; nothing listed → no change")

    let e = AudioEngine()
    let dev = e.deviceRate
    print("output device at \(AudioEngine.khz(dev)) (left untouched)")
    let other = abs(dev - 44100) < 1 ? 48000.0 : 44100.0
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-bp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func tone(_ rate: Double, amp: Float) -> URL {
        let url = dir.appendingPathComponent("t\(Int(rate)).caf")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let f = try! AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) { let v = amp * Float(sin(2 * .pi * 440 * Double(i) / rate)); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
        try! f.write(from: buf)
        return url
    }
    // Chain rebuilt at another rate (device untouched): audio still flows, at the new internal rate.
    e.setVolume(0)
    e.rebuildChain(rate: other)
    var peak: Float = 0, tapRate = 0.0
    e.onTap = { buf in tapRate = buf.format.sampleRate; if let d = buf.floatChannelData { for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[0][i])) } } }
    let o = tone(other, amp: 0.3)
    e.use(try! AVAudioFile(forReading: o), url: o)
    e.play()
    var end = Date().addingTimeInterval(0.6)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(peak > 0.25 && abs(tapRate - other) < 1 && e.busRate == other, "chain rebuilt at \(AudioEngine.khz(other)): audio flows at that rate (peak \(String(format: "%.2f", peak)))")
    let issues = e.bitPerfectIssues
    check(issues.contains { $0.hasPrefix("output at") } && issues.contains("volume below 100%") && !issues.contains("resampled inside the player"),
          "diagnosis: device at another rate and volume flagged, no internal resampling (\(issues.joined(separator: "; ")))")
    e.stop()

    // Same rate as the device, everything neutral (silent file, so nothing is heard at 100%): bit-perfect.
    let g = AudioEngine()
    g.rebuildChain(rate: dev)
    let s = tone(dev, amp: 0)
    g.use(try! AVAudioFile(forReading: s), url: s)
    g.setVolume(100)
    check(g.bitPerfectIssues.isEmpty, "diagnosis: same rate, volume 100%, EQs off → bit-perfect (\(g.bitPerfectIssues.joined(separator: "; ")))")
    g.setEQ(on: true, preamp: 0, bands: [0, 0, 3, 0, 0, 0, 0, 0, 0, 0])
    var pq = PEQProfile(); pq.filters = [PEQFilter()]
    g.setParametricEQ(pq, enabled: true)
    g.rate = 1.25
    g.setBalance(-30)
    let flagged = g.bitPerfectIssues
    check(["equalizer on", "parametric EQ on", "speed or pitch changed", "balance not centered"].allSatisfy(flagged.contains),
          "diagnosis: EQ, parametric EQ, speed and balance flagged")
    g.setVolume(0)
    end = Date().addingTimeInterval(0.1)
    while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    try? FileManager.default.removeItem(at: dir)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-peq`: Equalizer APO parsing/export, response maths, the engine's parametric EQ measured on
/// tones, and the live AutoEq catalogue (index, search, profile download).
if CommandLine.arguments.contains("--test-peq") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    let sample = """
    Preamp: -6.3 dB
    Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
    Filter 2: ON PK Fc 125 Hz Gain -2.7 dB Q 0.55
    Filter 3: OFF PK Fc 8445 Hz Gain 3.3 dB Q 1.61
    Filter 4: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
    """
    let p = PEQProfile.parse(sample, name: "Test")
    check(p?.preamp == -6.3 && p?.filters.count == 4 && p?.filters[0].kind == .lowShelf && p?.filters[3].kind == .highShelf && p?.filters[2].enabled == false,
          "APO format: preamp, 4 filters, shelf types, OFF filter")
    check(p.flatMap { PEQProfile.parse($0.text, name: "Test") }.map { a in zip(a.filters, p!.filters).allSatisfy { $0.kind == $1.kind && abs($0.frequency - $1.frequency) < 0.5 && abs($0.gain - $1.gain) < 0.05 && abs($0.q - $1.q) < 0.005 } } == true,
          "APO format: export and re-import give the same filters")
    var pk = PEQProfile(name: "pk"); pk.filters = [PEQFilter(enabled: true, kind: .peak, frequency: 1000, gain: 6, q: 1)]
    check(abs(pk.response(at: 1000) - 6) < 0.05 && abs(pk.response(at: 100)) < 0.3, "response: +6 dB peak at 1 kHz, flat at 100 Hz (\(String(format: "%.2f / %.2f", pk.response(at: 1000), pk.response(at: 100))))")
    var ls = PEQProfile(name: "ls"); ls.filters = [PEQFilter(enabled: true, kind: .lowShelf, frequency: 105, gain: 6, q: 0.7)]
    check(abs(ls.response(at: 25) - 6) < 0.5 && abs(ls.response(at: 5000)) < 0.1, "response: low shelf +6 dB below 105 Hz")
    check(abs(PEQProfile.octaves(q: 1.414) - 1) < 0.02 && abs(PEQProfile.octaves(q: 0.707) - 1.9) < 0.05, "Q → octaves (1.41 → 1, 0.71 → 1.9)")
    check(abs(pk.safePreamp + 6) < 0.1, "auto preamp: -6 dB for a +6 dB peak")

    // Engine: a +12 dB peak at 1 kHz on a 1 kHz and a 200 Hz tone.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-peq", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func tone(_ hz: Double) -> URL {
        let url = dir.appendingPathComponent("\(Int(hz)).caf")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let f = try! AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(48000 * 2)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) { let v = Float(0.1 * sin(2 * .pi * hz * Double(i) / 48000)); buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v }
        try! f.write(from: buf)
        return url
    }
    func level(_ url: URL, _ profile: PEQProfile?) -> Double {
        let e = AudioEngine()
        e.setVolume(0)
        e.setParametricEQ(profile, enabled: profile != nil)
        var sum = 0.0, n = 0
        let lock = NSLock()
        e.onTap = { buf in
            guard let d = buf.floatChannelData else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[0][i])) }
            guard peak > 0.01 else { return }
            lock.lock(); for i in 0..<Int(buf.frameLength) { sum += Double(d[0][i] * d[0][i]) }; n += Int(buf.frameLength); lock.unlock()
        }
        e.use(try! AVAudioFile(forReading: url), url: url)
        e.play()
        let end = Date().addingTimeInterval(1.0)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        e.stop()
        return n > 0 ? 10 * log10(sum / Double(n)) : -200
    }
    var boost = PEQProfile(name: "boost"); boost.filters = [PEQFilter(enabled: true, kind: .peak, frequency: 1000, gain: 12, q: 2)]
    let k1 = tone(1000), k200 = tone(200)
    let d1 = level(k1, boost) - level(k1, nil), d200 = level(k200, boost) - level(k200, nil)
    check(abs(d1 - 12) < 1.5 && abs(d200) < 1.5, "engine: +12 dB peak at 1 kHz measured \(String(format: "%+.1f", d1)) dB at 1 kHz, \(String(format: "%+.1f", d200)) dB at 200 Hz")
    var pre = PEQProfile(name: "pre"); pre.preamp = -6
    let dp = level(k200, pre) - level(k200, nil)
    check(abs(dp + 6) < 0.6, "engine: preamp -6 dB measured \(String(format: "%+.1f", dp)) dB")
    try? FileManager.default.removeItem(at: dir)

    // Live AutoEq catalogue.
    var done = false
    Task { @MainActor in await AutoEqCatalog.shared.load(); done = true }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let cat = AutoEqCatalog.shared
    check(cat.entries.count > 5000, "AutoEq index: \(cat.entries.count) profiles")
    let hits = cat.search("hd 600")
    check(hits.contains { $0.name == "Sennheiser HD 600" && $0.source.hasPrefix("oratory1990") }, "AutoEq search \"hd 600\": \(hits.count) results, oratory1990 among them")
    if let e = hits.first(where: { $0.name == "Sennheiser HD 600" && $0.source.hasPrefix("oratory1990") }) {
        var prof: PEQProfile?
        var err: Error?
        Task { do { prof = try await cat.profile(e) } catch { err = error }; done = false }
        while done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(prof?.filters.count == 10 && (prof?.preamp ?? 0) < 0, "AutoEq profile: \(prof?.filters.count ?? 0) filters, preamp \(prof?.preamp ?? 0) dB" + (err.map { " (\($0))" } ?? ""))
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-musicbrainz`: Lucene escaping, file↔track mapping, and real MusicBrainz / Cover Art
/// Archive lookups (respecting the 1 request per second limit).
if CommandLine.arguments.contains("--test-musicbrainz") {
    var results: [(Bool, String)]?
    Task { results = await MusicBrainz.selfTest() }
    while results == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    for (ok, what) in results! { print((ok ? "PASS " : "FAIL ") + what) }
    let failed = results!.filter { !$0.0 }.count
    print(failed == 0 ? "ALL PASSED" : "\(failed) FAILED")
    exit(failed == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --sonic-analyze file …`: tempo, key, loudness and analysis time of each file.
if let si = CommandLine.arguments.firstIndex(of: "--sonic-analyze") {
    for path in CommandLine.arguments[(si + 1)...] {
        let t0 = Date()
        if let f = SonicAnalyzer.analyze(URL(fileURLWithPath: path)) {
            print(String(format: "%5.1f BPM  %-4@  %5.1f dB  bright %.1f  noisy %.2f  %.2f s  %@", f.bpm, f.keyName, f.loudness, f.centroid, f.flatness,
                         Date().timeIntervalSince(t0), (path as NSString).lastPathComponent))
        } else {
            print("cannot analyse \(path)")
        }
    }
    exit(0)
}

/// Debug: `MusicAmp --test-sonic`: sonic analysis of generated music (tempo, key, timbre) and the mixes built on it.
if CommandLine.arguments.contains("--test-sonic") {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "OK  " : "FAIL", what); if !ok { fails += 1 } }
    let sr = 22050.0
    var seed: UInt64 = 7
    func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) * 2 - 1 }
    /// 40 s of a beat at `bpm`: a kick on every beat, a chord pad (MIDI notes), optional bright noise hats.
    func song(bpm: Double, chord: [Int], hats: Float, pad: Float = 0.25) -> [Float] {
        let n = Int(40 * sr)
        var x = [Float](repeating: 0, count: n)
        let beat = 60 / bpm
        for i in 0..<n {
            let t = Double(i) / sr
            let ph = t.truncatingRemainder(dividingBy: beat)
            var v = Float(exp(-ph * 18) * sin(2 * .pi * 55 * ph)) * 0.6                          // kick
            for m in chord { v += pad * Float(sin(2 * .pi * 440 * pow(2, Double(m - 69) / 12) * t)) / Float(chord.count) }
            let hph = (t + beat / 2).truncatingRemainder(dividingBy: beat)
            v += hats * rnd() * Float(exp(-hph * 60))                                           // off-beat hat
            x[i] = v
        }
        return x
    }
    let specs: [(String, Double, [Int], Float)] = [
        ("a", 120, [60, 64, 67, 72], 0.05),   // C major, kick + pad
        ("b", 123, [60, 64, 67, 72], 0.07),   // almost the same
        ("c", 92, [57, 60, 64, 69], 0.5),     // A minor, slower, bright hats
        ("d", 140, [62, 66, 69, 74], 0.9),    // D major, fast, very noisy
        ("e", 100, [57, 60, 64, 69], 0.35),   // A minor, in between c and a
    ]
    let store = SonicStore(load: false)
    var items: [SmartItem] = []
    var feats: [String: SonicFeatures] = [:]
    for (name, bpm, chord, hats) in specs {
        guard let f = SonicAnalyzer.features(song(bpm: bpm, chord: chord, hats: hats), sampleRate: sr) else { check(false, "\(name): analysed"); continue }
        feats[name] = f
        let ratio = f.bpm / Float(bpm)
        check(abs(ratio - 1) < 0.03 || abs(ratio - 2) < 0.06 || abs(ratio - 0.5) < 0.02, String(format: "%@: tempo %.1f BPM (true %.0f)", name, f.bpm, bpm))
        let key = "/tmp/sonic-\(name).wav"
        store.remember(f, key: key)
        var e = PlayStats.Entry(); e.title = name; e.artist = "Artist " + name
        items.append(SmartItem(key: key, url: URL(fileURLWithPath: key), stats: e))
    }
    check(feats["a"].map { $0.key == 0 && !$0.minor } ?? false, "a: key C major (\(feats["a"]?.keyName ?? "?"))")
    check(feats["c"].map { $0.key == 9 && $0.minor } ?? false, "c: key A minor (\(feats["c"]?.keyName ?? "?"))")
    check(feats["d"].map { $0.key == 2 && !$0.minor } ?? false, "d: key D major (\(feats["d"]?.keyName ?? "?"))")
    check((feats["d"]?.flatness ?? 0) > (feats["a"]?.flatness ?? 1), "d noisier than a (spectral flatness)")
    let space = SonicSpace(items: items, store: store)
    func tr(_ n: String) -> SonicSpace.Track { space.track(URL(fileURLWithPath: "/tmp/sonic-\(n).wav"))! }
    let near = space.similar(to: tr("a"), count: 4).map { $0.0.item.stats.title ?? "" }
    check(near.first == "b", "closest to a is its near twin b (order \(near.joined()))")
    check(near.last == "d", "furthest from a is the fast noisy d")
    let radio = space.radio(from: tr("a"), count: 4, randomness: 0).map { $0.item.stats.title ?? "" }
    check(radio.count == 5 && radio[0] == "a" && radio[1] == "b" && Set(radio).count == 5, "radio from a: a, b, … all different (\(radio.joined()))")
    let path = space.journey(from: tr("a"), to: tr("d"), steps: 3)
    let journey = path.map { $0.item.stats.title ?? "" }
    let steps = zip(path, path.dropFirst()).map { SonicSpace.distance($0, $1) }
    check(journey.first == "a" && journey.last == "d" && journey.count == 5 && Set(journey).count == 5,
          "journey a → d uses every in-between track once (\(journey.joined(separator: " → ")))")
    _ = steps
    // Smoothing: tracks on a line in feature space, given zig-zag, come back in order.
    let flat = feats["a"]!
    func point(_ x: Float) -> SonicSpace.Track {
        var e = PlayStats.Entry(); e.title = String(Int(x))
        return SonicSpace.Track(item: SmartItem(key: "p\(x)", url: URL(fileURLWithPath: "/tmp/p\(x)"), stats: e), f: flat, v: [x, 0])
    }
    let zigzag = [0, 4, 1, 3, 2, 5].map { point(Float($0)) }
    let smoothed = SonicSpace.smooth(zigzag).map { $0.item.stats.title ?? "" }
    check(smoothed == ["0", "1", "2", "3", "4", "5"], "journey smoothing untangles a zig-zag (\(smoothed.joined(separator: " ")))")
    check(SonicSpace.tempoDistance(120, 60) < SonicSpace.tempoDistance(120, 90), "half time counts as closer than a different tempo")
    // The same song in two files (and a featuring) never appears twice; the main artist doesn't repeat.
    do {
        var e1 = PlayStats.Entry(); e1.title = "Song’s Title"; e1.artist = "Alpha"
        var e2 = PlayStats.Entry(); e2.title = "song's  title"; e2.artist = "Alpha, Beta"
        let x = SonicSpace.Track(item: SmartItem(key: "x", url: URL(fileURLWithPath: "/tmp/x"), stats: e1), f: feats["a"]!, v: [0])
        let y = SonicSpace.Track(item: SmartItem(key: "y", url: URL(fileURLWithPath: "/tmp/y"), stats: e2), f: feats["a"]!, v: [0])
        check(SonicSpace.songKey(x) == SonicSpace.songKey(y), "duplicate song detected across files, apostrophes and featurings")
        var e3 = PlayStats.Entry(); e3.title = "Song’s Title (2)"; e3.artist = "Alpha"
        let z = SonicSpace.Track(item: SmartItem(key: "z", url: URL(fileURLWithPath: "/tmp/z"), stats: e3), f: feats["a"]!, v: [0])
        check(SonicSpace.songKey(x) == SonicSpace.songKey(z), "a Finder copy (\"… (2)\") is the same song")
    }
    print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-vocal`: the vocal remover on generated stereo (muted): a centred 440 Hz "voice" must
/// drop, a left-only 1 kHz "guitar" and a centred 60 Hz bass must stay; off must leave the signal untouched.
/// `MusicAmp --test-smart`: smart transitions between generated tracks with dead air (gap measured at the tap),
/// and gapless with no trimming inside an album.
if ["--test-vocal", "--test-smart", "--test-crossfeed", "--test-spoken"].contains(where: CommandLine.arguments.contains) {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "OK  " : "FAIL", what); if !ok { fails += 1 } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-vs-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func write(_ name: String, seconds: Double, _ gen: (Double) -> (Float, Float)) -> URL {
        let url = dir.appendingPathComponent(name)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let n = Int(44100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { let (l, r) = gen(Double(i) / 44100); buf.floatChannelData![0][i] = l; buf.floatChannelData![1][i] = r }
        do { let f = try AVAudioFile(forWriting: url, settings: fmt.settings); try f.write(from: buf) } catch { print("write failed: \(error)") }
        return url
    }
    func wait(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) } }

    if CommandLine.arguments.contains("--test-vocal") {
        let url = write("mix.wav", seconds: 6) { t in
            let voice = Float(0.3 * sin(2 * .pi * 440 * t)), guitar = Float(0.3 * sin(2 * .pi * 1000 * t)), bass = Float(0.3 * sin(2 * .pi * 60 * t))
            return (voice + guitar + bass, voice + bass)
        }
        let e = AudioEngine()
        e.setVolume(0)
        // Goertzel power of a frequency over the left channel of the tapped blocks.
        var acc: [Double: Double] = [:]
        let lock = NSLock()
        e.onTap = { buf in
            guard let d = buf.floatChannelData else { return }
            let n = Int(buf.frameLength), sr = buf.format.sampleRate
            var local: [Double: Double] = [:]
            for f in [60.0, 440, 1000] {
                let k = 2 * cos(2 * .pi * f / sr)
                var s1 = 0.0, s2 = 0.0
                for i in 0..<n { let s0 = Double(d[0][i]) + k * s1 - s2; s2 = s1; s1 = s0 }
                local[f] = (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(n * n)
            }
            lock.lock(); for (f, v) in local { acc[f, default: 0] += v }; lock.unlock()
        }
        func measure(_ amount: Double) -> [Double: Double] {
            e.vocalRemoval = amount
            wait(0.4)   // let the effect settle
            lock.lock(); acc = [:]; lock.unlock()
            wait(1.0)
            lock.lock(); defer { lock.unlock() }; return acc
        }
        e.use(try! AVAudioFile(forReading: url), url: url)
        e.play()
        let off = measure(0), on = measure(1), half = measure(0.5)
        e.vocalRemoval = 0
        e.stop()
        func db(_ a: Double?, _ b: Double?) -> Double { 10 * log10(max(1e-12, a ?? 0) / max(1e-12, b ?? 0)) }
        let voice = db(on[440], off[440]), guitar = db(on[1000], off[1000]), bass = db(on[60], off[60]), voiceHalf = db(half[440], off[440])
        check(voice < -30, String(format: "centred voice removed (%.1f dB)", voice))
        check(abs(guitar) < 7, String(format: "left-only guitar kept (%.1f dB)", guitar))
        check(bass > -6, String(format: "centred bass kept (%.1f dB)", bass))
        check(voiceHalf < -3 && voiceHalf > -12, String(format: "50%% strength: voice partly removed (%.1f dB)", voiceHalf))
        check(e.bitPerfectIssues.contains("vocal remover on") == false, "off again: not listed among bit-perfect issues")
    }

    if CommandLine.arguments.contains("--test-crossfeed") {
        // Left only: a 200 Hz low and a 6 kHz high; then the same low in both channels (mono).
        let side = write("left.wav", seconds: 4) { t in (Float(0.3 * sin(2 * .pi * 200 * t) + 0.3 * sin(2 * .pi * 6000 * t)), 0) }
        let mono = write("mono.wav", seconds: 4) { t in let v = Float(0.3 * sin(2 * .pi * 200 * t)); return (v, v) }
        func goertzel(_ p: UnsafePointer<Float>, _ n: Int, _ f: Double, _ sr: Double) -> Double {
            let k = 2 * cos(2 * .pi * f / sr); var s1 = 0.0, s2 = 0.0
            for i in 0..<n { let s0 = Double(p[i]) + k * s1 - s2; s2 = s1; s1 = s0 }
            return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double(n * n)
        }
        /// Power of 200 Hz and 6 kHz in each output channel, after the crossfeed node.
        func measure(_ url: URL, _ preset: CrossfeedAU.Preset) -> (l200: Double, r200: Double, r6k: Double) {
            let e = AudioEngine()
            e.setVolume(0)
            e.crossfeedPreset = preset
            var acc = (0.0, 0.0, 0.0)
            let lock = NSLock()
            var counting = false
            e.crossfeed.installTap(onBus: 0, bufferSize: 4096, format: nil) { buf, _ in
                guard let d = buf.floatChannelData, buf.format.channelCount >= 2 else { return }
                let n = Int(buf.frameLength), sr = buf.format.sampleRate
                let a = goertzel(d[0], n, 200, sr), b = goertzel(d[1], n, 200, sr), c = goertzel(d[1], n, 6000, sr)
                lock.lock(); if counting { acc.0 += a; acc.1 += b; acc.2 += c }; lock.unlock()
            }
            e.use(try! AVAudioFile(forReading: url), url: url)
            e.play()
            wait(0.5); lock.lock(); counting = true; lock.unlock(); wait(1.5)
            e.stop()
            e.crossfeed.removeTap(onBus: 0)
            lock.lock(); defer { lock.unlock() }; return acc
        }
        func db(_ a: Double, _ b: Double) -> Double { 10 * log10(max(1e-14, a) / max(1e-14, b)) }
        let off = measure(side, .off)
        check(db(off.r200, off.l200) < -60, "off: nothing reaches the right ear")
        for (preset, feed) in [(CrossfeedAU.Preset.light, 9.5), (.medium, 6.0), (.strong, 4.5)] {
            let m = measure(side, preset)
            // 200 Hz is below the cut, so it is fed at nearly the full level (a one-pole filter is −0.3 dB there).
            let cross = db(m.r200, m.l200)
            check(abs(cross + feed) < 1.5, String(format: "%@: a hard-left 200 Hz reaches the right ear at %.1f dB (target −%.1f)", preset.label, cross, feed))
            check(db(m.r6k, m.r200) < -12, String(format: "%@: the 6 kHz high is barely fed (%.1f dB below the low)", preset.label, db(m.r6k, m.r200)))
        }
        let monoOff = measure(mono, .off), monoOn = measure(mono, .strong)
        check(abs(db(monoOn.l200, monoOff.l200)) < 0.5, String(format: "mono content keeps its level (%.2f dB)", db(monoOn.l200, monoOff.l200)))
    }

    if CommandLine.arguments.contains("--test-spoken") {
        // "Speech": 1.5 s bursts of modulated noise; pauses of 1.2 s and 0.3 s alternate; a faint room noise
        // under everything (−60 dB).
        var seed: UInt64 = 3
        func rnd() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) * 2 - 1 }
        func speech(level: Float) -> (Double) -> (Float, Float) {
            { t in
                let cycle = t.truncatingRemainder(dividingBy: 4.5)   // 1.5 talk, 1.2 pause, 1.5 talk, 0.3 pause
                let talking = cycle < 1.5 || (cycle >= 2.7 && cycle < 4.2)
                let syllables = Float(0.6 + 0.4 * sin(2 * .pi * 4 * t))
                let v = (talking ? level * syllables * rnd() : 0) + 0.001 * rnd()
                return (v, v)
            }
        }
        let talk = write("talk.wav", seconds: 45, speech(level: 0.3))
        let pauses = SpokenWord.find(talk) ?? []
        let long = pauses.filter { $0.end - $0.start > 0.9 }
        check(pauses.count == 10 && long.count == 10, "pauses: the ten 1.2 s pauses found, the 0.3 s ones ignored (\(pauses.count) found)")
        check(pauses.allSatisfy { abs(($0.end - $0.start) - 1.2) < 0.15 }, String(format: "pause lengths ≈ 1.2 s (%.2f–%.2f)", pauses.map { $0.end - $0.start }.min() ?? 0, pauses.map { $0.end - $0.start }.max() ?? 0))
        // Playback: with the map, 10 s of listening covers more of the file.
        func advance(_ map: [SpokenWord.Pause]) -> Double {
            let e = AudioEngine()
            e.setVolume(0)
            e.use(try! AVAudioFile(forReading: talk), url: talk)
            e.pauses = map
            e.play()
            wait(9)
            let t = e.currentTime
            e.stop()
            return t
        }
        let plain = advance([]), shortened = advance(pauses)
        // 9 s hold two 1.2 s pauses of which 0.7 s run at 4×: about 9 + 2×0.7×3/4 ≈ 10 s... measured loosely.
        check(abs(plain - 9) < 0.6, String(format: "without the map: 9 s of listening = %.1f s of the file", plain))
        check(shortened - plain > 0.8, String(format: "shortened silences: %.1f s of the file in the same 9 s (+%.1f s)", shortened, shortened - plain))
        // Voice Boost: a quiet voice gets louder, a loud one doesn't clip.
        func level(_ url: URL, boost: Bool) -> (rms: Float, peak: Float) {
            let e = AudioEngine()
            e.setVolume(0)
            e.voiceBoost = boost
            var sum: Float = 0, n = 0, peak: Float = 0
            let lock = NSLock()
            var counting = false
            e.onTap = { buf in
                guard let d = buf.floatChannelData else { return }
                var r: Float = 0, p: Float = 0
                vDSP_rmsqv(d[0], 1, &r, vDSP_Length(buf.frameLength))
                vDSP_maxmgv(d[0], 1, &p, vDSP_Length(buf.frameLength))
                lock.lock(); if counting { sum += r * r; n += 1; peak = max(peak, p) }; lock.unlock()
            }
            e.use(try! AVAudioFile(forReading: url), url: url)
            e.play()
            wait(0.5); lock.lock(); counting = true; lock.unlock(); wait(3)
            e.stop()
            lock.lock(); defer { lock.unlock() }
            return ((sum / Float(max(1, n))).squareRoot(), peak)
        }
        let quiet = write("quiet.wav", seconds: 5, speech(level: 0.02)), loud = write("loud.wav", seconds: 5, speech(level: 0.6))
        let q0 = level(quiet, boost: false), q1 = level(quiet, boost: true), l1 = level(loud, boost: true), l0 = level(loud, boost: false)
        let gainQuiet = 20 * log10(q1.rms / max(1e-9, q0.rms)), gainLoud = 20 * log10(l1.rms / max(1e-9, l0.rms))
        check(gainQuiet > 6, String(format: "voice boost: a quiet voice +%.1f dB", gainQuiet))
        check(gainLoud < gainQuiet - 4, String(format: "voice boost: a loud voice raised less (+%.1f dB): levels even out", gainLoud))
        check(l1.peak <= 1.0, String(format: "voice boost: no clipping on a loud voice (peak %.2f)", l1.peak))
    }

    if CommandLine.arguments.contains("--test-smart") {
        // A: 2 s tone then 3 s of silence. B: 1.5 s of silence then a tone.
        let a = write("a.wav", seconds: 5) { t in t < 2 ? (Float(0.4 * sin(2 * .pi * 500 * t)), Float(0.4 * sin(2 * .pi * 500 * t))) : (0, 0) }
        let b = write("b.wav", seconds: 4) { t in t >= 1.5 ? (Float(0.4 * sin(2 * .pi * 800 * t)), Float(0.4 * sin(2 * .pi * 800 * t))) : (0, 0) }
        check(abs(Double(AudioEngine.silence(try! AVAudioFile(forReading: a), url: a, atEnd: true)) / 44100 - 2.9) < 0.05, "trailing silence of A: 3 s, 0.1 s kept")
        check(abs(Double(AudioEngine.silence(try! AVAudioFile(forReading: b), url: b, atEnd: false)) / 44100 - 1.4) < 0.05, "leading silence of B: 1.5 s, 0.1 s kept")
        /// Longest stretch of silence (in seconds) between the first and the last loud block at the tap.
        func gap(smart: Bool, sameAlbum: Bool) -> Double {
            let e = AudioEngine()
            e.setVolume(0)
            e.gapless = true
            e.smartTransitions = smart
            e.sameAlbum = { _, _ in sameAlbum }
            var given = false
            e.nextProvider = { given ? nil : (1, b) }
            e.onAdvance = { _ in given = true }
            let lock = NSLock()
            var started = false, silentRun = 0.0, longest = 0.0
            e.onTap = { buf in
                guard let d = buf.floatChannelData else { return }
                var peak: Float = 0
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[0][i])) }
                let secs = Double(buf.frameLength) / buf.format.sampleRate
                lock.lock()
                if peak > 0.01 { if started { longest = max(longest, silentRun) }; started = true; silentRun = 0 } else if started { silentRun += secs }
                lock.unlock()
            }
            e.use(try! AVAudioFile(forReading: a), url: a, index: 0)
            e.play()
            wait(smart && !sameAlbum ? 4.5 : 8.5)
            e.stop()
            lock.lock(); defer { lock.unlock() }
            return longest
        }
        let smartGap = gap(smart: true, sameAlbum: false)
        check(smartGap < 0.5, String(format: "smart, different albums: dead air skipped (gap %.2f s)", smartGap))
        let albumGap = gap(smart: true, sameAlbum: true)
        check(albumGap > 4.2, String(format: "smart, same album: silence kept, gapless join (gap %.2f s)", albumGap))
        let plainGap = gap(smart: false, sameAlbum: false)
        check(plainGap > 4.2, String(format: "smart off: plain gapless keeps the silence (gap %.2f s)", plainGap))
    }
    try? FileManager.default.removeItem(at: dir)
    print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --dock-snapshot out.png [cover.jpg]`: the dynamic Dock icon in its four states (playing with a
/// cover, paused, radio, no cover), side by side at 256 px.
if let di = CommandLine.arguments.firstIndex(of: "--dock-snapshot"), CommandLine.arguments.count > di + 1 {
    _ = NSApplication.shared
    let cover = CommandLine.arguments.count > di + 2 ? NSImage(contentsOfFile: CommandLine.arguments[di + 2]) : nil
    let states: [(NSImage?, Double?, Bool, Bool)] = [(cover, 0.42, false, false), (cover, 0.42, true, false), (cover, nil, false, true), (nil, 0.7, false, false)]
    let side = 256
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side * 4, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: side * 4, height: side).fill()
    for (i, st) in states.enumerated() {
        let v = DockTileView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        (v.cover, v.progress, v.paused, v.isStream) = st
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(i * side), y: 0)
        v.draw(v.bounds)
        ctx.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[di + 1]))
    print("dock snapshot written")
    exit(0)
}

/// Debug: `MusicAmp --test-waveform [out-dir]`: peaks of a generated file (silence, ramp, loud), a cue segment,
/// ffmpeg vs native, the disk cache, and the main window's position bar rendered with and without the waveform
/// (off must leave every pixel as the skin draws it; on may change only the groove). PNGs go to out-dir if given.
if let wi = CommandLine.arguments.firstIndex(of: "--test-waveform") {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "OK  " : "FAIL", what); if !ok { fails += 1 } }
    let out = CommandLine.arguments.count > wi + 1 ? URL(fileURLWithPath: CommandLine.arguments[wi + 1]) : nil
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-wave-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // 6 s at 44.1 kHz: 1 s silence, 3 s ramp up, 2 s loud.
    let wav = dir.appendingPathComponent("ramp.wav")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    do {
        let f = try AVAudioFile(forWriting: wav, settings: fmt.settings)
        let n = 44100 * 6
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / 44100
            let amp = t < 1 ? 0 : (t < 4 ? (t - 1) / 3 : 1)
            let v = Float(amp * 0.8 * sin(2 * .pi * 440 * t))
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        try f.write(from: buf)
    } catch { print("can't write test file: \(error)"); exit(1) }
    guard let w = WaveformStore.compute(wav) else { print("FAIL no waveform"); exit(1) }
    let p = w.peaks, n = p.count
    check(n == Waveform.buckets, "\(n) buckets")
    check(p[0..<(n / 6 - 2)].allSatisfy { $0 < 0.01 }, "first second silent")
    check(p[(n * 4 / 6 + 2)...].allSatisfy { $0 > 0.9 }, "last two seconds at full height")
    let a = p[n * 2 / 6], b = p[n * 3 / 6]
    check(a > 0.05 && a < b && b < 0.9, String(format: "ramp grows (%.2f → %.2f)", a, b))
    if FFmpeg.available, let fw = WaveformStore.viaFFmpeg(wav, start: 0, end: nil) {
        let diff = zip(fw.peaks, p).map { abs($0 - $1) }.max() ?? 1
        check(diff < 0.08, String(format: "ffmpeg path matches native (max diff %.3f)", diff))
    } else { print("SKIP ffmpeg not available") }
    // Cue: track 2 = seconds 2–4, all ramp; its waveform grows over the whole bar.
    let cue = dir.appendingPathComponent("ramp.cue")
    try? "FILE \"ramp.wav\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n  TRACK 02 AUDIO\n    INDEX 01 00:02:00\n  TRACK 03 AUDIO\n    INDEX 01 00:04:00\n".write(to: cue, atomically: true, encoding: .utf8)
    let t2 = CueSheet.trackURLs(cue)[1]
    if let cw = WaveformStore.compute(t2) {
        let q = cw.peaks
        check(q[2] > 0.1 && q[2] < q[q.count / 2] && q[q.count / 2] < q[q.count - 3] && q[q.count - 3] > 0.8, String(format: "cue segment: ramp only (%.2f → %.2f)", q[2], q[q.count - 3]))
    } else { check(false, "cue segment waveform") }
    // Disk cache through the store (asynchronous).
    var ready = false
    WaveformStore.shared.onReady = { _ in ready = true }
    check(WaveformStore.shared.waveform(for: wav) == nil, "store: computing in the background first")
    let t0 = Date()
    while !ready, Date().timeIntervalSince(t0) < 10 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    check(WaveformStore.shared.waveform(for: wav) != nil && WaveformStore.cached(wav)?.peaks.count == Waveform.buckets, "store: ready, cached on disk")
    // Rendering in the position bar.
    // MUSICAMP_WAVE_SKIN / MUSICAMP_WAVE_FILE: render with a real skin and a real track (muted).
    let c = Ctl.shared
    let env = ProcessInfo.processInfo.environment
    if let sk = env["MUSICAMP_WAVE_SKIN"], let skin = try? Skin.load(from: URL(fileURLWithPath: sk)) { c.skin = skin }
    let shown = env["MUSICAMP_WAVE_FILE"].map { URL(fileURLWithPath: $0) } ?? wav
    if shown != wav {
        ready = false
        _ = WaveformStore.shared.waveform(for: shown)
        let t1 = Date()
        while !ready, Date().timeIntervalSince(t1) < 20 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        print(String(format: "real track waveform in %.2f s", Date().timeIntervalSince(t1)))
    }
    do {
        let wr = c.skin.waveformRect
        let rows = Skin.grooveLumas(c.skin.image("posbar"), CGRect(x: 30, y: 72, width: 219, height: 10))
        let col = c.skin.waveformColors.played.components ?? []
        print("groove rect \(wr), row lumas \(rows.map { String(format: "%.2f", $0) }), colour \(col.map { String(format: "%.2f", $0) })")
    }
    c.audio.setVolume(0)
    c.playlist.tracks = [Track(url: shown)]
    c.playlist.currentTrack = c.playlist.tracks[0]
    c.audio.use(try! AVAudioFile(forReading: shown), url: shown, index: 0)
    c.audio.play()
    c.audio.seek(to: shown == wav ? 3 : c.audio.duration * 0.4)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    c.audio.pause()
    c.snapshotMode = true
    func render(_ wave: Bool, _ k: Int) -> CGImage? {
        c.waveSeekBar = wave
        let s = c.mainView.logicalSize
        guard let r = Renderer(width: Int(s.width), height: Int(s.height), skin: c.skin, pixelScale: k) else { return nil }
        c.mainView.render(r)
        return r.image()
    }
    func pixels(_ img: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: img.width * img.height * 4))
    }
    for k in [1, 2] {
        guard let off1 = render(false, k), let on = render(true, k), let off2 = render(false, k) else { check(false, "render \(k)x"); continue }
        let a0 = pixels(off1), a1 = pixels(on), a2 = pixels(off2)
        check(a0 == a2, "\(k)x: option off draws the skin exactly (no waveform left behind)")
        var outside = 0, inside = 0
        let g = c.skin.waveformRect; let groove = CGRect(x: Int(g.minX) * k, y: Int(g.minY) * k, width: Int(g.width) * k, height: Int(g.height) * k)
        for y in 0..<on.height { for x in 0..<on.width {
            let i = (y * on.width + x) * 4
            if a0[i..<(i + 4)] != a1[i..<(i + 4)] { if groove.contains(CGPoint(x: x, y: y)) { inside += 1 } else { outside += 1 } }
        } }
        check(outside == 0 && inside > 30 * k * k, "\(k)x: waveform changes only the groove (\(inside) px inside, \(outside) outside)")
        if let out {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for (name, img) in [("off", off1), ("on", on)] {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("posbar-\(k)x-\(name).png"))
            }
        }
    }
    c.audio.stop()
    try? FileManager.default.removeItem(at: dir)
    print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-stats`: play counting (threshold, skips, seeks), ratings and smart playlist rules
/// on an in-memory store; never touches stats.json.
if CommandLine.arguments.contains("--test-stats") {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "OK  " : "FAIL", what); if !ok { fails += 1 } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-stats-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func file(_ n: String) -> URL { let u = dir.appendingPathComponent(n); FileManager.default.createFile(atPath: u.path, contents: Data()); return u }
    let s = PlayStats(inMemory: true)
    let a = Track(url: file("a.mp3")); a.artist = "Alpha"; a.songTitle = "Song A"; a.album = "First"; a.duration = 300
    let b = Track(url: file("b.flac")); b.artist = "Beta"; b.songTitle = "Song B"; b.album = "Second"; b.duration = 200
    let c = Track(url: file("c.m4a")); c.artist = "Alpha"; c.songTitle = "Short"; c.album = "First"; c.duration = 20
    var now = Date()
    func listen(_ t: Track, _ seconds: Int, from start: Double = 0, step: Double = 0.5) {
        var pos = start
        for _ in 0..<Int(Double(seconds) / step) {
            s.observe(track: t, playing: true, position: pos, duration: t.duration ?? 0, now: now)
            now += step; pos += step
        }
    }
    check(PlayStats.threshold(duration: 300) == 150 && PlayStats.threshold(duration: 600) == 240 && PlayStats.threshold(duration: 20) == 18, "threshold: half, 4 min cap, 90% under 30 s")
    listen(a, 140)
    check(s.entry(a.url)?.plays == 0, "a: 140 s of 300 is not a play yet")
    listen(a, 20, from: 140)
    check(s.entry(a.url)?.plays == 1, "a: past half is one play")
    listen(a, 100, from: 160)
    check(s.entry(a.url)?.plays == 1, "a: counted once per listen")
    // A seek to the end doesn't count: only time actually played.
    s.observe(track: b, playing: true, position: 0, duration: 200, now: now); now += 0.5
    s.observe(track: b, playing: true, position: 190, duration: 200, now: now); now += 0.5
    s.observe(track: b, playing: true, position: 190.5, duration: 200, now: now); now += 0.5
    check(s.entry(b.url)?.plays == 0, "b: seeking near the end is no play")
    listen(b, 10, from: 20)
    s.observe(track: c, playing: true, position: 0, duration: 20, now: now)   // leave b after ~11 s
    check(s.entry(b.url)?.skips == 1, "b: left after 11 s → skip")
    listen(c, 19, from: 0.5)
    check(s.entry(c.url)?.plays == 1, "c: short track played almost whole → play")
    s.observe(track: a, playing: true, position: 0, duration: 300, now: now)
    check(s.entry(c.url)?.skips == 0, "c: finished, so not a skip")
    // Paused time is not listening.
    let pausedBefore = s.entry(a.url)?.plays ?? -1
    for _ in 0..<400 { s.observe(track: a, playing: false, position: 1, duration: 300, now: now); now += 1 }
    check(s.entry(a.url)?.plays == pausedBefore, "paused time doesn't count")
    s.setRating(a.url, 5); s.setRating(b.url, 2); s.setRating(c.url, 9)
    check(s.rating(a.url) == 5 && s.rating(c.url) == 5 && s.rating(b.url) == 2, "ratings stored and clamped to 5")
    let stream = Track(url: URL(string: "https://example.com/stream")!)
    s.observe(track: stream, playing: true, position: 0, duration: 0, now: now)
    check(s.entry(stream.url) == nil, "radio streams are not tracked")
    // Smart playlists.
    let pool = s.entries.map { SmartItem(key: $0.key, url: PlayStats.url(forKey: $0.key), stats: $0.value) }
    func run(_ p: SmartPlaylist) -> [String] { p.evaluate(pool, now: now).map { $0.url.lastPathComponent } }
    var p = SmartPlaylist(name: "t", rules: [SmartRule(field: .artist, op: .contains, text: "alpha")], order: .title)
    check(run(p) == ["c.m4a", "a.mp3"], "artist contains (case-insensitive), ordered by title")
    p.rules = [SmartRule(field: .rating, op: .greater, number: 3)]; p.order = .highestRated
    check(Set(run(p)) == ["a.mp3", "c.m4a"], "rating > 3")
    p.rules = [SmartRule(field: .plays, op: .numEquals, number: 0)]
    check(run(p) == ["b.flac"], "never played")
    p.rules = [SmartRule(field: .lastPlayed, op: .inLast, number: 1)]
    check(Set(run(p)) == ["a.mp3", "c.m4a"], "played in the last day")
    p.rules = [SmartRule(field: .format, op: .equals, text: "FLAC"), SmartRule(field: .duration, op: .less, number: 1)]; p.matchAll = false
    check(Set(run(p)) == ["b.flac", "c.m4a"], "any: FLAC or shorter than 1 min")
    p.matchAll = true
    check(run(p).isEmpty, "all: FLAC and shorter than 1 min")
    p.rules = []; p.order = .mostPlayed; p.limit = 2
    check(run(p).count == 2 && run(p).first != "b.flac", "limit 2 by most played")
    try? FileManager.default.removeItem(at: dir.appendingPathComponent("a.mp3"))
    p.limit = 0; p.onlyExisting = true
    check(!run(p).contains("a.mp3"), "missing files hidden")
    // Genre, year, BPM and key rules (BPM/key from the Sonic Mix analysis).
    do {
        func item(_ key: String, genre: String?, year: Int?) -> SmartItem {
            var e = PlayStats.Entry(); e.genre = genre; e.year = year; e.title = key
            return SmartItem(key: key, url: URL(fileURLWithPath: key), stats: e)
        }
        func feat(_ bpm: Float, _ key: Int, _ minor: Bool) -> SonicFeatures {
            SonicFeatures(mfcc: Array(repeating: 0, count: 13), chroma: Array(repeating: 1 / 12, count: 12), bpm: bpm, key: key, minor: minor,
                          keyStrength: 0.8, loudness: -14, centroid: 10, flatness: 0.1, dynamics: 6, punch: 1, zcr: 1000)
        }
        let pool2 = [item("/r1", genre: "Rock", year: 1985), item("/r2", genre: "Indie Rock", year: 2019), item("/j1", genre: "Jazz", year: 1959),
                     item("/x1", genre: nil, year: nil)]
        SonicStore.shared.remember(feat(124, 9, true), key: "/r1")    // A minor
        SonicStore.shared.remember(feat(128, 0, false), key: "/r2")   // C major (relative of A minor)
        SonicStore.shared.remember(feat(92, 2, false), key: "/j1")    // D major
        func run2(_ rules: [SmartRule], all: Bool = true) -> [String] {
            SmartPlaylist(name: "t", matchAll: all, rules: rules, order: .title, onlyExisting: false).evaluate(pool2).map(\.key)
        }
        check(run2([SmartRule(field: .genre, op: .contains, text: "rock")]) == ["/r1", "/r2"], "genre contains “rock”")
        check(run2([SmartRule(field: .year, op: .less, number: 1990)]) == ["/j1", "/r1"], "year before 1990 (no year tag never matches)")
        check(run2([SmartRule(field: .bpm, op: .greater, number: 120), SmartRule(field: .bpm, op: .less, number: 126)]) == ["/r1"], "BPM between 120 and 126")
        check(run2([SmartRule(field: .key, op: .keyCompatible, text: "Am")]) == ["/r1", "/r2"], "mixes well with Am: A minor and its relative C major")
        check(run2([SmartRule(field: .key, op: .keyIs, text: "D")]) == ["/j1"], "key is D")
        check(SmartRule.parseKey("F♯m").map { $0.key == 6 && $0.minor } == true && SmartRule.parseKey("Bb").map { $0.key == 10 && !$0.minor } == true,
              "key names parsed (F♯m, Bb)")
        check(run2([SmartRule(field: .key, op: .keyCompatible, text: "E")]) == [], "E major doesn't mix with A minor, C major or D major")
    }
    check(SmartPlaylist.defaults.count == 7, "default smart playlists")
    let data = try? JSONEncoder().encode(SmartPlaylist.defaults)
    check(data.flatMap { try? JSONDecoder().decode([SmartPlaylist].self, from: $0) }?.count == 7, "smart playlists round-trip as JSON")
    try? FileManager.default.removeItem(at: dir)
    print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-schedule`: alarm times (days, once, DST), fade curves, widget state and commands.
if CommandLine.arguments.contains("--test-schedule") {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print(ok ? "OK  " : "FAIL", what); if !ok { fails += 1 } }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Rome")!
    func date(_ s: String) -> Date {
        let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
    // 2026-10-07 is a Wednesday (weekday 4).
    let wedEvening = date("2026-10-07 21:00")
    check(Scheduler.nextOccurrence(hour: 7, minute: 30, days: [], after: wedEvening, calendar: cal) == date("2026-10-08 07:30"), "once: tomorrow morning")
    check(Scheduler.nextOccurrence(hour: 22, minute: 0, days: [], after: wedEvening, calendar: cal) == date("2026-10-07 22:00"), "once: later today")
    check(Scheduler.nextOccurrence(hour: 7, minute: 30, days: [2, 3, 4, 5, 6], after: date("2026-10-09 08:00"), calendar: cal) == date("2026-10-12 07:30"), "weekdays: Friday after the alarm → Monday")
    check(Scheduler.nextOccurrence(hour: 9, minute: 0, days: [1, 7], after: wedEvening, calendar: cal) == date("2026-10-10 09:00"), "weekend: Saturday")
    check(Scheduler.nextOccurrence(hour: 21, minute: 0, days: [4], after: wedEvening, calendar: cal) == date("2026-10-14 21:00"), "same minute → next week")
    // Daylight saving ends in Rome on 2026-10-25 (03:00 → 02:00): 07:30 is still 07:30 local.
    let dst = Scheduler.nextOccurrence(hour: 7, minute: 30, days: [], after: date("2026-10-24 23:00"), calendar: cal)!
    check(cal.dateComponents([.day, .hour, .minute], from: dst) == DateComponents(day: 25, hour: 7, minute: 30), "DST change keeps local time")
    check(Scheduler.fadeFactor(remaining: 60, fade: 30) == 1, "fade: before the fade window")
    check(abs(Scheduler.fadeFactor(remaining: 15, fade: 30) - 0.5) < 1e-9, "fade: halfway")
    check(Scheduler.fadeFactor(remaining: 0, fade: 30) == 0, "fade: silent at the end")
    check(Scheduler.fadeFactor(remaining: 5, fade: 0) == 1, "no fade: full volume until the end")
    // Widget state: the clock alone is not a change; a pause is.
    var a = WidgetState(); a.running = true; a.hasTrack = true; a.title = "T"; a.playing = true; a.duration = 200; a.elapsed = 10
    var b = a; b.updated = a.updated.addingTimeInterval(5); b.elapsed = 15
    check(a.sameContent(as: b) && b.sameContent(as: a), "widget: elapsed moving with the clock is no change")
    var c = b; c.elapsed = 60
    check(!c.sameContent(as: a), "widget: a seek is a change")
    var d = b; d.playing = false; d.paused = true
    check(!d.sameContent(as: a), "widget: pause is a change")
    if let data = WidgetShared.encode(a) {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        check((try? dec.decode(WidgetState.self, from: data)) != nil, "widget: state round-trips as JSON")
    }
    check(MusicAmpCommand.allCases.allSatisfy { MusicAmpCommand(rawValue: $0.url.host ?? "") == $0 }, "commands: musicamp:// URLs map back")
    check(WidgetShared.folder.path.hasSuffix("Library/Application Support/MusicAmp/Widget"), "widget folder under the real home")
    print(fails == 0 ? "ALL OK" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-cue`: a file with three tones indexed by a cue sheet — parsing, folder expansion,
/// metadata, segment playback (pitch measured), seeking, gapless advance, and the ffmpeg path.
if CommandLine.arguments.contains("--test-cue") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    guard let ff = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        print("a full ffmpeg (Homebrew) is needed to make the test files"); exit(1)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-cue", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tones = "sine=frequency=300:duration=2:sample_rate=44100[a];sine=frequency=600:duration=2:sample_rate=44100[b];sine=frequency=900:duration=2:sample_rate=44100[c];[a][b][c]concat=n=3:v=0:a=1"
    for ext in ["flac", "wv"] {
        FFmpeg.run(ff, ["-y", "-v", "error", "-filter_complex", tones, "-ac", "2", dir.appendingPathComponent("album.\(ext)").path])
    }
    // The sheet names "album.wav" (converted since) and is Windows-1252 with an accented title.
    let cue = """
    REM GENRE Test
    REM DATE 2020
    PERFORMER "Tone Band"
    TITLE "Three Tones"
    FILE "album.wav" WAVE
      TRACK 01 AUDIO
        TITLE "Low"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Caffè"
        PERFORMER "Guest"
        INDEX 00 00:01:70
        INDEX 01 00:02:00
      TRACK 03 AUDIO
        TITLE "High"
        INDEX 01 00:04:00
    """
    let flacDir = dir.appendingPathComponent("flac", isDirectory: true), wvDir = dir.appendingPathComponent("wv", isDirectory: true)
    for (d, ext) in [(flacDir, "flac"), (wvDir, "wv")] {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: dir.appendingPathComponent("album.\(ext)"), to: d.appendingPathComponent("album.\(ext)"))
        try? cue.data(using: .windowsCP1252)!.write(to: d.appendingPathComponent("album.cue"))
    }
    let cueURL = flacDir.appendingPathComponent("album.cue")
    let sheet = CueSheet.parse(cueURL)
    check(sheet?.entries.count == 3 && sheet?.title == "Three Tones" && sheet?.performer == "Tone Band" && sheet?.date == "2020",
          "cue: 3 tracks, album title, performer, date")
    check(sheet?.entries[1].title == "Caffè" && sheet?.entries[1].performer == "Guest" && sheet?.entries[1].start == 2 && sheet?.entries[1].end == 4,
          "cue: Windows-1252 title, track performer, INDEX 01 wins over 00, end = next start")
    check(sheet?.entries[0].file.lastPathComponent == "album.flac" && sheet?.entries[2].end == nil, "cue: album.wav resolved to album.flac; last track to the end")
    check(CueSheet.time("01:02:37") == 62 + 37.0 / 75, "cue: mm:ss:ff with 75 frames per second")
    let expanded = Playlist.expand([flacDir])
    check(expanded.count == 3 && expanded.allSatisfy(CueSheet.isCueTrack) && expanded[1].absoluteString.hasSuffix("album.cue#track=2"),
          "playlist: the folder shows the cue's 3 tracks, not the whole file")
    let pl = Playlist()
    pl.add(expanded)
    let t0 = Date()
    while (pl.tracks.last?.duration ?? 0) == 0, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    check(pl.tracks[1].songTitle == "Caffè" && pl.tracks[1].artist == "Guest" && pl.tracks[0].artist == "Tone Band" && pl.tracks[1].album == "Three Tones",
          "playlist: titles and artists from the sheet")
    check(abs((pl.tracks[1].duration ?? 0) - 2) < 0.01 && abs((pl.tracks[2].duration ?? 0) - 2) < 0.05, "playlist: durations 2 s, last one from the file")

    /// Dominant frequency of what the engine plays, by counting zero crossings over a window.
    func measure(_ e: AudioEngine, seconds: Double) -> Double {
        var crossings = 0, frames = 0, last: Float = 0
        let lock = NSLock()
        e.onTap = { buf in
            guard let d = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            // Only blocks with signal: the engine's start-up silence would lower the estimate.
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(d[0][i])) }
            guard peak > 0.05 else { return }
            lock.lock()
            for i in 0..<n { let v = d[0][i]; if (v >= 0) != (last >= 0) { crossings += 1 }; last = v }
            frames += n
            lock.unlock()
        }
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        e.onTap = nil
        let rate = e.eq.outputFormat(forBus: 0).sampleRate
        return frames > 0 ? Double(crossings) / 2 / (Double(frames) / rate) : 0
    }
    func wait(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }

    // Native (FLAC): track 2 only, then gapless into track 3.
    let e = AudioEngine()
    e.setVolume(0)
    e.gapless = true
    var advanced: Int?
    e.nextProvider = { advanced == nil ? (2, expanded[2]) : nil }
    e.onAdvance = { advanced = $0 }
    e.use(try! AVAudioFile(forReading: CueSheet.audioURL(expanded[1])), url: expanded[1], index: 1)
    check(abs(e.duration - 2) < 0.01, "engine: duration is the segment's (\(String(format: "%.2f", e.duration)) s)")
    e.play()
    let f2 = measure(e, seconds: 0.6)
    check(abs(f2 - 600) < 50 && e.currentTime < 1.2, "engine: track 2 plays its own tone (\(Int(f2)) Hz), time from 0 (\(String(format: "%.2f", e.currentTime)) s)")
    e.seek(to: 1.2)
    wait(0.2)
    check(e.currentTime >= 1.2 && e.currentTime < 1.6, "engine: seek inside the segment (\(String(format: "%.2f", e.currentTime)) s)")
    wait(0.9)
    let f3 = measure(e, seconds: 0.5)
    check(advanced == 2 && abs(f3 - 900) < 50, "engine: gapless advance to track 3 at the segment end (\(Int(f3)) Hz)")
    e.stop()

    // ffmpeg (WavPack + cue).
    let wvTrack = CueSheet.trackURLs(wvDir.appendingPathComponent("album.cue"))[1]
    if FFmpeg.available, let probe = FFmpeg.probe(CueSheet.audioURL(wvTrack)) {
        let g = AudioEngine()
        g.setVolume(0)
        g.useFFmpeg(url: wvTrack, probe: probe, index: 1)
        check(abs(g.duration - 2) < 0.05, "ffmpeg: duration is the segment's (\(String(format: "%.2f", g.duration)) s)")
        var done = false
        g.onFinish = { done = true }
        g.play()
        let fw = measure(g, seconds: 1.2)
        check(abs(fw - 600) < 40, "ffmpeg: WavPack track 2 plays its own tone (\(Int(fw)) Hz)")
        let t1 = Date()
        while !done, Date().timeIntervalSince(t1) < 4 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(done && Date().timeIntervalSince(t0) > 0, "ffmpeg: stops at the end of the segment")
    } else {
        check(false, "ffmpeg available for the WavPack case")
    }
    try? FileManager.default.removeItem(at: dir)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-tags`: writes and reads back tags on MP3 (ID3v2.3/2.4 + v1), FLAC and M4A files made
/// with a full ffmpeg, checking values, untouched fields and frames, in-place writes and that the audio is intact.
if CommandLine.arguments.contains("--test-tags") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    guard let ff = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        print("a full ffmpeg (Homebrew) is needed to create the test files"); exit(1)
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-tags", isDirectory: true)
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func make(_ name: String, _ args: [String]) -> URL {
        let u = dir.appendingPathComponent(name)
        FFmpeg.run(ff, ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=44100", "-ac", "2",
                        "-metadata", "title=Vecchio titolo", "-metadata", "artist=Vecchio artista", "-metadata", "album=Album",
                        "-metadata", "genre=Pop", "-metadata", "custom=resta"] + args + [u.path])
        return u
    }
    func frames(_ u: URL) -> AVAudioFramePosition { (try? AVAudioFile(forReading: u))?.length ?? -1 }
    func wait<T>(_ f: @escaping () async throws -> T) -> Result<T, Error> {
        var r: Result<T, Error>?
        Task { do { r = .success(try await f()) } catch { r = .failure(error) } }
        while r == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return r!
    }
    // A small PNG cover.
    var px = RGBA(width: 64, height: 64)
    for y in 0..<64 { for x in 0..<64 { px[x, y] = 0xFF000000 | UInt32(x * 4) | UInt32(y * 4) << 8 } }
    let cover = NSBitmapImageRep(cgImage: px.image()!).representation(using: .png, properties: [:])!

    let files: [(String, URL)] = [
        ("MP3 ID3v2.3 + v1", make("a.mp3", ["-c:a", "libmp3lame", "-id3v2_version", "3", "-write_id3v1", "1"])),
        ("MP3 ID3v2.4", make("b.mp3", ["-c:a", "libmp3lame", "-id3v2_version", "4"])),
        ("FLAC", make("c.flac", ["-c:a", "flac"])),
        ("M4A", make("d.m4a", ["-c:a", "aac"])),
    ]
    for (label, u) in files {
        guard FileManager.default.fileExists(atPath: u.path) else { check(false, "\(label): test file"); continue }
        let before = frames(u)
        let t0 = (try? wait { await TagIO.read(u) }.get()) ?? TagSet()
        check(t0.title == "Vecchio titolo" && t0.artist == "Vecchio artista" && t0.genre == "Pop", "\(label): reading existing tags")
        var up = TagUpdate()
        up.fields = [\.title: "Città è “bella” 🎵", \.artist: "Artista Nuovo", \.year: "2024", \.track: "3", \.trackTotal: "12",
                     \.disc: "1", \.discTotal: "2", \.comment: "nota", \.albumArtist: "Vari"]
        up.artwork = .set(cover)
        let w = wait { try await TagIO.write(u, up) }
        if case .failure(let e) = w { check(false, "\(label): write (\(e.localizedDescription))"); continue }
        let t1 = (try? wait { await TagIO.read(u) }.get()) ?? TagSet()
        check(t1.title == "Città è “bella” 🎵" && t1.artist == "Artista Nuovo" && t1.year == "2024" && t1.albumArtist == "Vari",
              "\(label): text written and read back (accents, quotes, emoji)")
        check(t1.track == "3" && t1.trackTotal == "12" && t1.disc == "1" && t1.discTotal == "2", "\(label): track 3/12 and disc 1/2")
        check(t1.comment == "nota" && t1.artwork == cover, "\(label): comment and artwork")
        check(t1.album == "Album" && t1.genre == "Pop", "\(label): untouched fields unchanged")
        check(frames(u) == before && before > 0, "\(label): audio intact (\(before) samples)")
        // Independent reader: the full ffprobe must see the same tags.
        if let out = FFmpeg.run(ff.replacingOccurrences(of: "ffmpeg", with: "ffprobe"), ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", u.path]),
           let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] {
            var tags: [String: String] = [:]
            for src in [(json["format"] as? [String: Any])?["tags"]] + ((json["streams"] as? [[String: Any]]) ?? []).map({ $0["tags"] }) {
                for (k, v) in (src as? [String: Any]) ?? [:] { tags[k.lowercased()] = "\(v)" }
            }
            let pic = ((json["streams"] as? [[String: Any]]) ?? []).contains { (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1 }
            check(tags["title"] == "Città è “bella” 🎵" && tags["artist"] == "Artista Nuovo" && (tags["track"] ?? "").hasPrefix("3") && pic,
                  "\(label): ffprobe (independent reader) sees title, artist, track and artwork")
        }
        // Small change after a big tag: in place, same file size (MP3/FLAC).
        let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        var up2 = TagUpdate(); up2.fields = [\.genre: "Rock"]
        _ = wait { try await TagIO.write(u, up2) }
        let t2 = (try? wait { await TagIO.read(u) }.get()) ?? TagSet()
        let size2 = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        check(t2.genre == "Rock" && t2.title == t1.title && t2.artwork == cover, "\(label): single-field change")
        if TagIO.kind(u) != .mp4 { check(size2 == size, "\(label): written in place, size unchanged (\(size) bytes)") }
        var up3 = TagUpdate(); up3.artwork = .remove; up3.fields = [\.comment: ""]
        _ = wait { try await TagIO.write(u, up3) }
        let t3 = (try? wait { await TagIO.read(u) }.get()) ?? TagSet()
        check(t3.artwork == nil && t3.comment.isEmpty && t3.title == t1.title && frames(u) == before, "\(label): artwork and comment removed")
        if TagIO.kind(u) == .id3 {
            let raw = (try? Data(contentsOf: u)) ?? Data()
            let head = String(decoding: raw.prefix(4096), as: UTF8.self)
            check(head.contains("custom") || head.contains("TXXX"), "\(label): unknown frames preserved (TXXX)")
        }
        // Star rating: POPM (MP3) or RATING (FLAC); MP4 has no standard star tag.
        if TagIO.kind(u) != .mp4 {
            for stars in [4, 1, 5, 0] {
                var ur = TagUpdate(); ur.fields = [\.rating: stars > 0 ? String(stars) : ""]
                _ = wait { try await TagIO.write(u, ur) }
                let tr = (try? wait { await TagIO.read(u) }.get()) ?? TagSet()
                check(tr.rating == (stars > 0 ? String(stars) : "") && tr.title == t1.title && frames(u) == before,
                      "\(label): rating \(stars)★ written and read back, rest intact")
            }
            if let out = FFmpeg.run(ff.replacingOccurrences(of: "ffmpeg", with: "ffprobe"), ["-v", "quiet", "-show_entries", "format_tags", "-of", "json", u.path]) {
                check(!out.lowercased().contains("rating=") || TagIO.kind(u) == .id3, "\(label): rating cleared (no RATING left)")
            }
        }
        if label.contains("v1") {
            let raw = [UInt8]((try? Data(contentsOf: u)) ?? Data())
            let v1 = raw.suffix(128)
            check(v1.starts(with: Array("TAG".utf8)) && String(decoding: v1.dropFirst(33).prefix(13), as: UTF8.self) == "Artista Nuovo", "\(label): ID3v1 updated")
        }
    }
    check(!TagIO.canWrite(URL(fileURLWithPath: "/x/a.ogg")) && TagIO.canWrite(URL(fileURLWithPath: "/x/a.flac")), "non-writable formats detected")
    // The playlist reads genre, year and the file's rating (adopted when MusicAmp has none). In-memory stats:
    // the real stats.json is never touched by tests.
    PlayStats.shared.inMemory = true
    if let flac = files.first(where: { $0.0 == "FLAC" })?.1 {
        var ur = TagUpdate(); ur.fields = [\.rating: "3", \.year: "1999"]
        _ = wait { try await TagIO.write(flac, ur) }
        let pl = Playlist()
        pl.add([flac])
        let t0 = Date()
        while pl.tracks.first?.year == nil, Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let t = pl.tracks.first
        check(t?.genre == "Rock" && t?.year == 1999, "playlist track: genre and year from the tags (\(t?.genre ?? "-"), \(t?.year.map(String.init) ?? "-"))")
        check(PlayStats.shared.rating(flac) == 3, "playlist track: the file's 3★ rating adopted")
    }
    // Ratings written by other players: POPM bytes from any owner, FLAC RATING on a 1–5 scale.
    do {
        let popm = { (b: UInt8) in ID3.Frame(id: "POPM", data: Array("someone@example.com".utf8) + [0, b]) }
        check([1, 64, 128, 196, 255, 30, 100, 230].map { ID3.popmStars(popm($0)) ?? -1 } == [1, 2, 3, 4, 5, 1, 3, 5], "POPM bytes map to stars like other players")
        let vc = FLACTags.le32Bytes(4) + Array("test".utf8) + FLACTags.le32Bytes(1) + FLACTags.le32Bytes(8) + Array("RATING=4".utf8)
        check(FLACTags.tagSet([FLACTags.Block(type: 4, data: vc)]).rating == "4", "FLAC RATING on a 1–5 scale (foobar2000) read as stars")
        let vc100 = FLACTags.le32Bytes(4) + Array("test".utf8) + FLACTags.le32Bytes(1) + FLACTags.le32Bytes(9) + Array("RATING=60".utf8)
        check(FLACTags.tagSet([FLACTags.Block(type: 4, data: vc100)]).rating == "3", "FLAC RATING on a 0–100 scale (MusicBee) read as stars")
    }
    // The editor's model, used like the window does: shared value, numbering, artwork, one file left out.
    let batch = (1...3).map { make("batch\($0).mp3", ["-c:a", "libmp3lame"]) }
    MainActor.assumeIsolated {
        let c = Ctl.shared
        let m = TagEditorModel(urls: batch, ctl: c)
        while m.files.contains(where: { !$0.loaded }) { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(m.common(\.album) == "Album" && m.common(\.title) == "Vecchio titolo", "editor: shared values detected")
        m.files[2].included = false
        m.binding(\.album).wrappedValue = "Nuovo album"
        m.autoNumber()
        m.artwork = .set(cover)
        check(m.common(\.track) == nil && m.isMixed(\.track) && !m.isMixed(\.album), "editor: different numbers per file, shared album")
        m.save()
        while m.saving || m.message == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let r = batch.map { u in (try? wait { await TagIO.read(u) }.get()) ?? TagSet() }
        check(r[0].album == "Nuovo album" && r[1].album == "Nuovo album" && r[0].track == "1" && r[1].track == "2" && r[1].trackTotal == "2",
              "editor: album and numbers 1/2, 2/2 saved on included files")
        check(r[0].artwork == cover && r[1].artwork == cover && r[2].album == "Album" && r[2].artwork == nil && r[2].track.isEmpty,
              "editor: artwork on included files, excluded file untouched")
        check(!m.hasChanges && (m.message ?? "").hasPrefix("Saved 2"), "editor: message \"\(m.message ?? "")\"")
    }
    try? FileManager.default.removeItem(at: dir)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --karaoke-sweep`: renders a karaoke line at 120 consecutive instants (through a held word)
/// and reports frame-to-frame change, to catch flicker (isolated spikes) and layout jumps (size changes).
if CommandLine.arguments.contains("--karaoke-sweep") {
    let lrc = LRC.parse("[00:01.00]<00:01.00>la <00:01.30>luce <00:01.60>sale <00:01.90>piano <00:02.20>sooopra <00:05.20>noi\n[00:06.00]fine\n") ?? []
    let words = Lyrics(plain: nil, synced: lrc, source: "test").timedWords(0)
    var frames: [[UInt8]] = []
    var sizes = Set<String>()
    let step = 1.0 / 60
    MainActor.assumeIsolated {
        for k in 0..<330 {   // 5.5 s at 60 fps, through the held word and its settle
            let t = 1.0 + Double(k) * step
            let r = ImageRenderer(content: KaraokeLine(words: words, now: t, size: 40, pulse: 0.3)
                .frame(width: CGFloat(Double(ProcessInfo.processInfo.environment["KARAOKE_W"] ?? "800") ?? 800), alignment: .leading).padding(20).background(Color.black))
            r.scale = 1
            guard let img = r.cgImage, let data = img.dataProvider?.data as Data? else { continue }
            sizes.insert("\(img.width)x\(img.height)")
            frames.append([UInt8](data))
        }
    }
    func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count else { return 255 }
        var d = 0
        for i in stride(from: 0, to: a.count, by: 4) { d += abs(Int(a[i]) - Int(b[i])) }
        return Double(d) / Double(a.count / 4)
    }
    // Flicker: frame i jumps away from both neighbours while the neighbours are alike (out and back).
    var flicker = 0, maxStep = 0.0
    for i in 1..<max(1, frames.count - 1) {
        let a = diff(frames[i - 1], frames[i]), b = diff(frames[i], frames[i + 1]), around = diff(frames[i - 1], frames[i + 1])
        maxStep = max(maxStep, a)
        if min(a, b) > 0.3, around < 0.5 * min(a, b) {
            flicker += 1
            print(String(format: "  flicker at t=%.3f: %.2f / %.2f, neighbours apart %.2f", 1.0 + Double(i) * step, a, b, around))
        }
    }
    print(String(format: "frames %d at 60 fps, sizes %@, max frame-to-frame jump %.2f, flickers %d",
                 frames.count, sizes.sorted().joined(separator: ","), maxStep, flicker))
    exit(flicker == 0 && sizes.count == 1 ? 0 : 1)
}

/// Debug: `MusicAmp --milkdrop-snapshot file.milk out.png [frames]`: renders a preset with synthetic audio and saves the last frame.
if let i = CommandLine.arguments.firstIndex(of: "--milkdrop-snapshot"), CommandLine.arguments.count > i + 2,
   let p = MilkPreset.load(URL(fileURLWithPath: CommandLine.arguments[i + 1])), let rd = MilkdropRenderer() {
    let frames = CommandLine.arguments.count > i + 3 ? Int(CommandLine.arguments[i + 3]) ?? 150 : 150
    let w = 640, h = 360
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkdropRenderer.format, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .managed
    let tex = rd.device.makeTexture(descriptor: d)!
    let prep = rd.prepare(p)
    rd.install(prep, blend: false)
    print("shader: warp \(prep.warp != nil ? "yes" : "no"), comp \(prep.comp != nil ? "yes" : "no"), blur \(prep.usesBlur)")
    prep.notes.forEach { print("  " + $0) }
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for f in 0..<frames {
        let t = Double(f) / 30
        rd.fixedTime = 100 + t
        let beat: Float = f % 15 < 3 ? 1 : 0.25
        let l = (0..<576).map { Float(sin(Double($0) * 0.13 + t * 9)) * 0.6 * beat }
        rd.updateAudio(left: l, right: l.reversed(), spectrum: (0..<512).map { Float(max(0, 1 - Double($0) / 256)) * beat }, bands: (beat * 0.02, beat * 0.01, beat * 0.005), dt: 1 / 30)
        guard let cb = rd.render(into: tex) else { break }
        let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: tex); b.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        if f % 30 == 29 || f == frames - 1 {
            tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let lit = stride(from: 0, to: px.count, by: 4).filter { Int(px[$0]) + Int(px[$0 + 1]) + Int(px[$0 + 2]) > 24 }.count
            let r = rd.runtime!
            print(String(format: "frame %3d: %.1f%% lit  decay %.3f zoom %.3f warp %.2f wave_a %.2f gamma %.2f", f + 1, 100 * Double(lit) / Double(w * h),
                         r["decay"], r["zoom"], r["warp"], r["wave_a"], r["gamma"]))
        }
    }
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    px.withUnsafeBytes { memcpy(ctx.data!, $0.baseAddress!, px.count) }
    try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(0)
}

/// Debug: `MusicAmp --milkdrop-msl file.milk`: prints the Metal translation of a preset's shaders and Metal's errors.
if let i = CommandLine.arguments.firstIndex(of: "--milkdrop-msl"), CommandLine.arguments.count > i + 1,
   let p = MilkPreset.load(URL(fileURLWithPath: CommandLine.arguments[i + 1])), let dev = MTLCreateSystemDefaultDevice() {
    for (label, src, stage) in [("warp", p.warpShader, HLSLTranslator.Stage.warp), ("comp", p.compShader, .comp)] where src.contains("shader_body") {
        print("===== \(label)")
        do {
            let msl = try HLSLTranslator(stage: stage).translate(src, entry: "md_main")
            let lines = msl.components(separatedBy: "\n")
            let preludeLines = MDShaderPrelude.source.components(separatedBy: "\n").count - 1
            do { _ = try dev.makeLibrary(source: MDShaderPrelude.source + msl, options: nil); print("OK") } catch {
                for l in "\(error)".components(separatedBy: "\n") where l.contains("error:") {
                    print(l)
                    // program_source:LINE:COL → show that line of the translation.
                    if let m = l.range(of: #"program_source:(\d+)"#, options: .regularExpression),
                       let n = Int(l[m].split(separator: ":")[1]), n - preludeLines - 1 >= 0, n - preludeLines - 1 < lines.count {
                        print("    > " + lines[n - preludeLines - 1].trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        } catch { print("translation: \(error)") }
    }
    exit(0)
}

/// Debug: `MusicAmp --milkdrop-verify <dir> [report.txt] [render-sample]`: translates and compiles every .milk under
/// <dir> (in parallel) and renders a sample of them, then prints totals and the most common failure causes.
if let i = CommandLine.arguments.firstIndex(of: "--milkdrop-verify"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let reportURL = CommandLine.arguments.count > i + 2 ? URL(fileURLWithPath: CommandLine.arguments[i + 2]) : nil
    let sample = CommandLine.arguments.count > i + 3 ? Int(CommandLine.arguments[i + 3]) ?? 200 : 200
    var files: [URL] = []
    if let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
        for case let f as URL in en where f.pathExtension.lowercased() == "milk" { files.append(f) }
    }
    files.sort { $0.path < $1.path }
    guard let rd = MilkdropRenderer() else { print("Metal not available"); exit(1) }
    struct Result { var name: String; var shaders = 0; var warpOK = true; var compOK = true; var notes: [String] = []; var parseFailed = false }
    var results = [Result?](repeating: nil, count: files.count)
    let lock = NSLock()
    var done = 0
    let t0 = Date()
    DispatchQueue.concurrentPerform(iterations: files.count) { k in
        let f = files[k]
        var r = Result(name: f.path.replacingOccurrences(of: dir.path + "/", with: ""))
        if let p = MilkPreset.load(f) {
            let prep = rd.prepare(p)
            r.shaders = (p.warpShader.contains("shader_body") ? 1 : 0) + (p.compShader.contains("shader_body") ? 1 : 0)
            r.warpOK = !p.warpShader.contains("shader_body") || prep.warp != nil
            r.compOK = !p.compShader.contains("shader_body") || prep.comp != nil
            r.notes = prep.notes
        } else {
            r.parseFailed = true
        }
        lock.lock()
        results[k] = r
        done += 1
        if done % 500 == 0 { print("  \(done)/\(files.count)…"); fflush(stdout) }
        lock.unlock()
    }
    let all = results.compactMap { $0 }
    let withShaders = all.filter { $0.shaders > 0 }
    let fullOK = withShaders.filter { $0.warpOK && $0.compOK }
    let stages = all.reduce(0) { $0 + $1.shaders }
    let stageOK = all.reduce(0) { $0 + ($1.shaders > 0 ? (($1.warpOK ? 1 : 0) + ($1.compOK ? 1 : 0)) - (2 - $1.shaders) : 0) }
    print(String(format: "presets: %d (%d unreadable), with MD2 shaders: %d", all.count, all.filter(\.parseFailed).count, withShaders.count))
    print(String(format: "MD2 presets with all shaders translated and compiled: %d / %d (%.1f%%)", fullOK.count, withShaders.count, 100 * Double(fullOK.count) / Double(max(1, withShaders.count))))
    print(String(format: "individual shaders compiled: %d / %d (%.1f%%), in %.0f s", stageOK, stages, 100 * Double(stageOK) / Double(max(1, stages)), Date().timeIntervalSince(t0)))
    // Most common causes: error text with names and numbers blanked out.
    func signature(_ note: String) -> String {
        var s = note
        if let r = s.range(of: "error: ") { s = String(s[r.upperBound...]) }
        s = s.replacingOccurrences(of: "'[^']*'", with: "'…'", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\b[0-9]+\\b", with: "N", options: .regularExpression)
        return String((note.hasPrefix("shader warp") ? "[warp] " : "[comp] ") + s.prefix(110))
    }
    var causes: [String: (Int, String)] = [:]
    for r in all { for n in r.notes { let k = signature(n); causes[k] = ((causes[k]?.0 ?? 0) + 1, causes[k]?.1 ?? r.name) } }
    print("most common causes:")
    for (k, v) in causes.sorted(by: { $0.value.0 > $1.value.0 }).prefix(25) { print(String(format: "%6d  %@   (e.g. %@)", v.0, k, String(v.1.suffix(60)))) }
    if let reportURL {
        var rep = ""
        for r in all where !r.notes.isEmpty { rep += r.name + "\n" + r.notes.map { "    " + $0 }.joined(separator: "\n") + "\n" }
        try? rep.write(to: reportURL, atomically: true, encoding: .utf8)
    }
    // Render a sample: catches crashes, black or frozen output at runtime.
    let w = 320, h = 180
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MilkdropRenderer.format, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .managed
    let tex = rd.device.makeTexture(descriptor: d)!
    let q = rd.device.makeCommandQueue()!
    var black = 0, frozen = 0, rendered = 0
    var blackNames: [String] = []
    let step = max(1, files.count / max(1, sample))
    for k in stride(from: 0, to: files.count, by: step) {
        guard let p = MilkPreset.load(files[k]) else { continue }
        rd.load(p, blend: false)
        var prev: [UInt8] = []
        var lit = 0.0, diff = 0.0
        for f in 0..<90 {
            let t = Double(f) / 30
            rd.fixedTime = 100 + t
            let beat: Float = f % 15 < 3 ? 1 : 0.25
            let l = (0..<576).map { Float(sin(Double($0) * 0.13 + t * 9)) * 0.6 * beat }
            rd.updateAudio(left: l, right: l.reversed(), spectrum: (0..<512).map { Float(max(0, 1 - Double($0) / 256)) * beat }, bands: (beat * 0.02, beat * 0.01, beat * 0.005), dt: 1 / 30)
            guard let cb = rd.render(into: tex) else { break }
            if f >= 80, f % 9 == 8 {
                let b = cb.makeBlitCommandEncoder()!; b.synchronize(resource: tex); b.endEncoding()
            }
            cb.commit(); cb.waitUntilCompleted()
            if f >= 80, f % 9 == 8 {
                var px = [UInt8](repeating: 0, count: w * h * 4)
                tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
                lit = Double(stride(from: 0, to: px.count, by: 4).filter { Int(px[$0]) + Int(px[$0 + 1]) + Int(px[$0 + 2]) > 24 }.count) / Double(w * h)
                if !prev.isEmpty { diff = Double(zip(px, prev).filter { abs(Int($0) - Int($1)) > 4 }.count) / Double(px.count) }
                prev = px
            }
        }
        _ = q
        rendered += 1
        if lit < 0.01 { black += 1; blackNames.append(files[k].lastPathComponent) }
        else if diff < 0.0005 { frozen += 1 }
    }
    print("test render: \(rendered) presets, \(black) nearly black, \(frozen) frozen")
    for n in blackNames.prefix(15) { print("   black: " + n) }
    exit(0)
}

/// Debug: `MusicAmp --resolve-fonts "Name" ...` runs the font lookup and prints where each font came from.
if let i = CommandLine.arguments.firstIndex(of: "--resolve-fonts") {
    let names = Array(CommandLine.arguments[(i + 1)...])
    let fr = FontResolver.shared
    names.forEach { _ = fr.family(for: $0) }
    let deadline = Date().addingTimeInterval(40)
    while names.contains(where: { fr.status(for: $0) == .searching }), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }
    for n in names { print("\(n) -> \(fr.family(for: n) ?? "Arial (fallback)")  [\(fr.status(for: n).map { "\($0)" } ?? "?")]") }
    exit(0)
}

/// Debug: `MusicAmp --self-test [file.eqf ...]` checks EQ preset files, the play queue and drop insertion.
if let i = CommandLine.arguments.firstIndex(of: "--self-test") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }
    // EQF: hand-built bytes as Winamp writes them
    var raw = EQF.header
    var name = Array("Test".utf8); name += [UInt8](repeating: 0, count: 257 - name.count)
    raw.append(contentsOf: name)
    raw.append(contentsOf: [0, 63, 31, 32, 16, 47, 0, 63, 31, 32, 20] as [UInt8])
    let parsed = EQF.parse(raw)
    check(parsed?.count == 1 && parsed?[0].name == "Test", "eqf: one preset named Test")
    check(parsed?[0].bands.first == 12 && parsed?[0].bands[1] == -12, "eqf: 0 = +12 dB, 63 = -12 dB")
    check(parsed?[0].bands[2] == 0, "eqf: 0x1F (31) = 0 dB")
    check(parsed.map { EQF.write($0) } == raw, "eqf: write(parse(x)) == x")
    let lib = [EQPreset(name: "A", bands: Array(repeating: 3, count: 10), preamp: -2),
               EQPreset(name: "B", bands: Array(repeating: -6, count: 10), preamp: 1)]
    let back = EQF.parse(EQF.write(lib))
    check(back?.map(\.name) == ["A", "B"] && back.map { zip($0, lib).allSatisfy { abs($0.bands[0] - $1.bands[0]) < 0.4 && abs($0.preamp - $1.preamp) < 0.4 } } == true,
          "q1: two presets round-trip within 0.4 dB")
    for path in CommandLine.arguments[(i + 1)...] {
        let ps = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(EQF.parse) ?? []
        print("file \(path): \(ps.count) preset" + ps.prefix(3).map { "\n  \($0.name): \($0.bands.map { String(format: "%+.1f", $0) }.joined(separator: " ")) pre \(String(format: "%+.1f", $0.preamp))" }.joined())
    }
    // Queue
    let pl = Playlist()
    pl.tracks = (0..<6).map { Track(url: URL(fileURLWithPath: "/tmp/t\($0).mp3")) }
    pl.toggleQueue([4]); pl.toggleQueue([1]); pl.toggleQueue([2])
    check(pl.queue.map { pl.tracks.firstIndex(of: $0) } == [4, 1, 2], "queue: order kept as queued")
    pl.toggleQueue([1])
    check(pl.queue.count == 2 && pl.queuePosition(pl.tracks[2]) == 2, "queue: Q again removes, positions shift")
    pl.remove([4])
    check(pl.popQueue() == 2 && pl.queue.isEmpty, "queue: removed tracks skipped, pop returns playlist index")
    // Insert at a drop position
    pl.insert([], at: 1)
    let before = pl.tracks.count
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-selftest.mp3")
    FileManager.default.createFile(atPath: tmp.path, contents: Data())
    pl.insert([tmp], at: 2)
    check(pl.tracks.count == before + 1 && pl.tracks[2].url == tmp && pl.selection == [2], "insert: lands at index 2 and is selected")
    try? FileManager.default.removeItem(at: tmp)

    // Retina skins: @2x sheets are validated, drawn at 2x, and 1x art is still used elsewhere.
    func solid(_ w: Int, _ h: Int, _ c: UInt32) -> CGImage { var b = RGBA(width: w, height: h); b.px = Array(repeating: c, count: w * h); return b.image()! }
    let red: UInt32 = 0xFF0000FF, blue: UInt32 = 0xFFFF0000, green: UInt32 = 0xFF00FF00   // RGBA bytes, little-endian
    let rdir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-retina-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: rdir, withIntermediateDirectories: true)
    func png(_ img: CGImage, _ name: String) { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: rdir.appendingPathComponent(name)) }
    png(solid(275, 116, red), "main.png"); png(solid(550, 232, blue), "main@2x.png")
    png(solid(136, 36, red), "cbuttons.png"); png(solid(100, 10, blue), "cbuttons@2x.png")   // wrong size
    png(solid(84, 18, green), "playpaus@2x.png")                                              // @2x only
    // Cursors: CUR with a PNG payload, ANI = RIFF ACON with 'anih' + LIST 'fram' of icons.
    func le16(_ v: Int) -> Data { Data([UInt8(v & 255), UInt8(v >> 8 & 255)]) }
    func le32(_ v: Int) -> Data { le16(v & 0xFFFF) + le16(v >> 16) }
    func cur(_ side: Int, _ c: UInt32, hot: Int) -> Data {
        let body = NSBitmapImageRep(cgImage: solid(side, side, c)).representation(using: .png, properties: [:])!
        return le16(0) + le16(2) + le16(1) + Data([UInt8(side & 255), UInt8(side & 255), 0, 0]) + le16(hot) + le16(hot) + le32(body.count) + le32(22) + body
    }
    func ani(_ icons: [Data]) -> Data {
        let anih = le32(36) + le32(icons.count) + le32(icons.count) + le32(0) + le32(0) + le32(0) + le32(0) + le32(6) + le32(1)
        var fram = Data("fram".utf8)
        for ic in icons { fram += Data("icon".utf8) + le32(ic.count) + ic + (ic.count & 1 == 1 ? Data([0]) : Data()) }
        let body = Data("ACON".utf8) + Data("anih".utf8) + le32(anih.count) + anih + Data("LIST".utf8) + le32(fram.count) + fram
        return Data("RIFF".utf8) + le32(body.count) + body
    }
    try? ani([cur(32, red, hot: 4), cur(32, green, hot: 4), cur(32, blue, hot: 4)]).write(to: rdir.appendingPathComponent("normal.ani"))
    try? ani([cur(64, red, hot: 8), cur(64, green, hot: 8), cur(64, blue, hot: 8)]).write(to: rdir.appendingPathComponent("normal@2x.ani"))
    try? ani([cur(32, red, hot: 0), cur(32, blue, hot: 0)]).write(to: rdir.appendingPathComponent("close.ani"))
    try? ani([cur(64, red, hot: 0)]).write(to: rdir.appendingPathComponent("close@2x.ani"))               // wrong frame count
    try? cur(32, red, hot: 2).write(to: rdir.appendingPathComponent("min.cur"))
    try? cur(64, blue, hot: 4).write(to: rdir.appendingPathComponent("min@2x.cur"))
    if let rs = try? Skin.load(from: rdir) {
        check(rs.isRetina && rs.image2x("main") != nil && rs.image2x("cbuttons") == nil, "retina: main@2x accepted, wrongly sized cbuttons@2x rejected")
        check(rs.image("playpaus").map { ($0.width, $0.height) } ?? (0, 0) == (42, 9), "retina: @2x only → 1x derived at 42×9")
        let r1 = Renderer(width: 4, height: 4, skin: rs)!, r2 = Renderer(width: 4, height: 4, skin: rs, pixelScale: 2)!
        r1.blit("main", R(0, 0, 4, 4), 0, 0); r2.blit("main", R(0, 0, 4, 4), 0, 0)
        let p1 = RGBA(r1.image()!)!, p2 = RGBA(r2.image()!)!
        check(p2.width == 8 && p2.height == 8, "retina: 2× framebuffer (8×8 for 4×4 logical)")
        check(p1[1, 1] == red && p2[7, 7] == blue && p2[0, 0] == blue, "retina: 1x uses main.png, 2x uses main@2x.png")
        let r3 = Renderer(width: 4, height: 4, skin: rs, pixelScale: 2)!
        r3.blit("cbuttons", R(0, 0, 4, 4), 0, 0)
        check(RGBA(r3.image()!)![5, 5] == red, "retina: without a valid @2x the upscaled 1x is used")
        let reps = { (c: String) in rs.cursors[c]?.frames.map { $0.image.representations.map(\.pixelsWide) } ?? [] }
        check(reps("normal").count == 3 && reps("normal").allSatisfy { $0.contains(32) && $0.contains(64) }
              && rs.cursors["normal"]?.frames.allSatisfy { $0.image.size.width == 32 && $0.hotSpot == NSPoint(x: 4, y: 4) } == true,
              "retina: .ani @2x, 3 frames with 32 and 64 px, same size in points and 1x hotspot")
        check(reps("close").allSatisfy { $0 == [32] } && rs.retinaIssues.contains { $0.hasPrefix("close@2x.ani") },
              "retina: .ani @2x with a different frame count rejected")
        check(reps("min") == [[32, 64]], "retina: .cur @2x")
        let gen = RetinaTools.cursor2x(ani([cur(32, red, hot: 5), cur(32, blue, hot: 5)])).flatMap { SkinCursor.parseANI($0) }
        check(gen?.frames.count == 2 && gen?.frames.allSatisfy { $0.image.representations.first?.pixelsWide == 64 && $0.hotSpot == NSPoint(x: 10, y: 10) } == true
              && gen?.delays == [0.1, 0.1], "make-retina: .ani doubled, 2 frames at 64 px, hotspot ×2, timings unchanged")
    } else { check(false, "retina: test skin loaded") }
    // Playlist tree: artist → album → track.
    func tr(_ artist: String?, _ album: String?, _ title: String) -> Track {
        let t = Track(url: URL(fileURLWithPath: "/tmp/\(title).mp3"), title: title)
        t.artist = artist; t.album = album; t.songTitle = title
        return t
    }
    let tt = [tr("A", "X", "a1"), tr("B", "Y", "b1"), tr("A", "X", "a2"), tr("A", nil, "a3"), tr(nil, nil, "radio"),
              tr("C", "Mix", "c1"), tr("D", "Mix", "d1"), tr("A", "Z", "a4")]
    let tree = PlaylistTree(tt, collapsed: [])
    let shape = tree.rows.map { r -> String in
        if case .header(let n) = r { return (tree.nodes[n].kind == .artist ? "A:" : "B:") + tree.nodes[n].title }
        if case .track(let i, let d) = r { return "\(d)\(tt[i].songTitle!)" }
        return "?"
    }
    check(shape == ["A:A", "B:X", "2a1", "2a2", "1a3", "B:Z", "2a4", "A:B", "B:Y", "2b1", "0radio", "A:Various Artists", "B:Mix", "2c1", "2d1"],
          "tree: artist → album → track, first-appearance order, no-album tracks under the artist, compilations under Various Artists")
    let closed = PlaylistTree(tt, collapsed: ["b:a|x", "a:b"])
    check(closed.rows.count == tree.rows.count - 4 && closed.rowOfTrack[2] == 1 && closed.rowOfTrack[1] == 5,
          "tree: collapsed album and artist hide their tracks, which point to the header")
    // Featurings don't make a compilation; the album-artist tag wins; a real compilation stays "Various Artists".
    let ft = [tr("Taylor Swift", "Midnights", "lavender"), tr("Taylor Swift, Lana Del Rey", "Midnights", "snow"), tr("Taylor Swift", "Midnights", "maroon"),
              tr("Simon & Garfunkel", "Bookends", "mrs"), tr("Simon & Garfunkel", "Bookends", "america"),
              tr("Ed Sheeran feat. X", "Sola", "s1"), tr("Ed Sheeran", "Sola", "s2")]
    let tagged = tr("Ospite", "Live", "l1"); tagged.albumArtist = "Band"
    let tagged2 = tr("Altro", "Live", "l2"); tagged2.albumArtist = "Band"
    let comp = [tr("A1", "Hits", "h1"), tr("B1", "Hits", "h2"), tr("C1", "Hits", "h3")]
    let t2 = PlaylistTree(ft + [tagged, tagged2] + comp, collapsed: [])
    let heads = t2.nodes.filter { $0.kind == .artist }.map { "\($0.title):\($0.tracks.count)" }
    check(heads == ["Taylor Swift:3", "Simon & Garfunkel:2", "Ed Sheeran:2", "Band:2", "Various Artists:3"],
          "tree: featurings in the artist's own album, names with & kept whole, album artist tag, real compilation (\(heads))")
    check(PlaylistTree.mainArtist("Taylor Swift, Lana Del Rey") == "Taylor Swift" && PlaylistTree.mainArtist("A feat. B") == "A"
          && PlaylistTree.mainArtist("Solo") == "Solo", "main artist before feat./,")
    // HLS: MPEG-TS demux (PAT → PMT → PES) and ID3 titles, on a hand-made segment.
    func tsPacket(_ pid: Int, start: Bool, _ payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x47, UInt8((start ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF), 0x10] + payload
        if p.count < 188 {
            // Pad with an adaptation field so the payload ends exactly at 188 bytes.
            let pad = 188 - p.count
            p[3] = 0x30
            p.insert(contentsOf: [UInt8(pad - 1)] + (pad > 1 ? [0x00] + Array(repeating: 0xFF, count: pad - 2) : []), at: 4)
        }
        return p
    }
    func id3(_ frames: [(String, String)]) -> [UInt8] {
        var body: [UInt8] = []
        for (id, text) in frames {
            let data: [UInt8] = [3] + Array(text.utf8)
            body += Array(id.utf8) + [0, 0, 0, UInt8(data.count)] + [0, 0] + data
        }
        return Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, UInt8(body.count)] + body
    }
    let pat: [UInt8] = [0, 0x00, 0xB0, 13, 0, 1, 0xC1, 0, 0, 0, 1, 0xE1, 0x00, 0, 0, 0, 0]
    let pmt: [UInt8] = [0, 0x02, 0xB0, 23, 0, 1, 0xC1, 0, 0, 0xE1, 0x01, 0xF0, 0,
                        0x0F, 0xE1, 0x01, 0xF0, 0, 0x15, 0xE1, 0x02, 0xF0, 0, 0, 0, 0, 0]
    let adts: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x02, 0x1F, 0xFC] + Array(repeating: 0x21, count: 200)
    let pesHeader: [UInt8] = [0, 0, 1, 0xC0, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, 1]
    let tag = id3([("TPE1", "Artista"), ("TIT2", "Titolo")])
    var ts = tsPacket(0, start: true, pat) + tsPacket(0x100, start: true, pmt)
    ts += tsPacket(0x101, start: true, pesHeader + Array(adts[0..<150]))
    ts += tsPacket(0x101, start: false, Array(adts[150...]))
    ts += tsPacket(0x102, start: true, [0, 0, 1, 0xBD, 0, 0, 0x80, 0x80, 5, 0x21, 0, 1, 0, 1] + tag)
    let fetcher = HLSFetcher(url: URL(string: "https://example.com/a.m3u8")!)
    var got: String?
    fetcher.onTitle = { got = $0 }
    if let (es, type) = try? fetcher.demux(Data(ts)) {
        check([UInt8](es) == adts && type == kAudioFileAAC_ADTSType, "hls: demux TS → \(es.count) bytes AAC ADTS, intact across two packets")
    } else { check(false, "hls: demux TS") }
    check(got == "Artista - Titolo", "hls: ID3 title from the metadata stream (\(got ?? "none"))")
    let packed = Data(id3([("TIT2", "Solo titolo")]) + adts)
    got = nil
    let pk = try? fetcher.demux(packed)
    check(pk?.0.count == adts.count && pk?.1 == kAudioFileAAC_ADTSType && got == "Solo titolo", "hls: packed audio with leading ID3 tag")
    let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=64000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=128000\nmid.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\nvideo.m3u8\n"
    check(HLSFetcher.pickVariant(master, base: URL(string: "https://x.y/radio/master.m3u8")!)?.0.absoluteString == "https://x.y/radio/mid.m3u8", "hls: best audio variant up to 320 kb/s")
    let media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:41\n#EXTINF:6.0,\nseg41.ts\n#EXTINF:6.0,\nseg42.ts\n"
    let mpl = try? HLSFetcher.parseMedia(media, base: URL(string: "https://x.y/radio/live.m3u8")!)
    check(mpl?.firstSeq == 41 && mpl?.segments.count == 2 && mpl?.segments[1].url.absoluteString == "https://x.y/radio/seg42.ts", "hls: media playlist, sequence and relative URLs")
    let enc = try? HLSFetcher.parseMedia("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI=\"../k.key\"\n#EXTINF:6,\na.ts\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:6,\nb.ts\n", base: URL(string: "https://x.y/r/live.m3u8")!)
    check(enc?.segments[0].key?.absoluteString == "https://x.y/k.key" && enc?.segments[1].key == nil, "hls: EXT-X-KEY AES-128 (relative URI) and METHOD=NONE")
    check((try? HLSFetcher.parseMedia("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"k\"\n#EXTINF:6,\na.ts\n", base: URL(string: "https://x.y/")!)) == nil,
          "hls: SAMPLE-AES → AVPlayer")
    // AES-128-CBC round trip with the sequence-number IV.
    let aesKey = Data((0..<16).map { UInt8($0 * 7 & 0xFF) }), plain = Data(ts.prefix(1000))
    let iv = HLSFetcher.sequenceIV(1851520)
    var cipher = Data(count: plain.count + 16), moved = 0
    let cipherCount = cipher.count
    _ = cipher.withUnsafeMutableBytes { o in plain.withUnsafeBytes { d in aesKey.withUnsafeBytes { k in
        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 16, iv, d.baseAddress, plain.count, o.baseAddress, cipherCount, &moved) } } }
    cipher.count = moved
    check(iv.suffix(4) == [0x00, 0x1C, 0x40, 0x80] && (try? HLSFetcher.decrypt(cipher, key: aesKey, iv: iv)) == plain, "hls: AES-128-CBC decryption, IV from the sequence number")
    let small = RGBA(width: 2, height: 2)
    check(Skin.scale2x(small.image()!).map { ($0.width, $0.height) } ?? (0, 0) == (4, 4), "scale2x: doubles")
    try? FileManager.default.removeItem(at: rdir)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-radio URL [seconds]` plays a stream muted and prints what the engine sees.
if let i = CommandLine.arguments.firstIndex(of: "--test-radio"), CommandLine.arguments.count > i + 1,
   let url = URL(string: CommandLine.arguments[i + 1]) {
    let secs = Double(CommandLine.arguments.count > i + 2 ? CommandLine.arguments[i + 2] : "8") ?? 8
    let a = AudioEngine()
    a.setVolume(0)
    a.bufferSeconds = 2
    var lastTitle: String?
    a.onStreamInfo = {
        if a.stream.title != lastTitle { lastTitle = a.stream.title; print("  title: \(a.stream.title ?? "-")") }
        if let e = a.stream.error { print("  status: \(e)") }
    }
    var rms: Float = 0   // from the analysis tap (after the EQ, before the volume)
    if let b = ProcessInfo.processInfo.environment["MUSICAMP_BALANCE"].flatMap(Double.init) { a.setBalance(b) }
    var lr: (Float, Float) = (0, 0)
    a.onTap = { buf in
        guard let d = buf.floatChannelData, buf.format.channelCount >= 2 else { return }
        var l: Float = 0, r: Float = 0
        for i in 0..<Int(buf.frameLength) { l += d[0][i] * d[0][i]; r += d[1][i] * d[1][i] }
        lr = (max(lr.0, (l / Float(max(1, buf.frameLength))).squareRoot()), max(lr.1, (r / Float(max(1, buf.frameLength))).squareRoot()))
    }
    a.analysisEnabled = true   // normally switched on by the UI timer when a visualizer is shown
    a.milkdropEnabled = true
    a.playStream(url)
    let start = Date()
    var peak: Float = 0, mdPeak: Float = 0
    while Date().timeIntervalSince(start) < secs {
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        peak = max(peak, a.visData().0.max() ?? 0)
        let md = a.milkdropData().left
        mdPeak = max(mdPeak, md.map { abs($0) }.max() ?? 0)
        rms = max(rms, (md.reduce(0) { $0 + $1 * $1 } / Float(max(1, md.count))).squareRoot())
    }
    print("  name=\(a.stream.name ?? "-") hls=\(a.stream.isHLS) rate=\(Int(a.sampleRate)) ch=\(a.channels) kbps=\(a.bitrate)")
    print("  state=\(a.state) buffering=\(a.stream.buffering) played=\(String(format: "%.1f", a.currentTime))s vis-peak=\(String(format: "%.2f", peak)) milkdrop-peak=\(String(format: "%.2f", mdPeak)) eq-rms=\(String(format: "%.3f", rms)) L=\(String(format: "%.3f", lr.0)) R=\(String(format: "%.3f", lr.1)) error=\(a.stream.error ?? "none")")
    exit(a.currentTime > 1 || a.stream.isHLS ? 0 : 1)
}

/// Debug: `MusicAmp --test-transitions` measures gapless and crossfade on generated tones (muted) and checks
/// the EBU R128 meter and ReplayGain tag reading.
if CommandLine.arguments.contains("--test-transitions") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-transitions", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func tone(_ name: String, freq: Double, seconds: Double, amp: Float, rate: Double = 44100) -> URL {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let f = try! AVAudioFile(forWriting: url, settings: fmt.settings)
        let n = AVAudioFrameCount(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
        buf.frameLength = n
        for i in 0..<Int(n) {
            let v = amp * Float(sin(2 * Double.pi * freq * Double(i) / rate))
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        try! f.write(from: buf)
        return url
    }
    let a1 = tone("a.caf", freq: 440, seconds: 2, amp: 0.5)
    let b1 = tone("b.caf", freq: 440, seconds: 2, amp: 0.5, rate: 48000)   // different rate on purpose

    /// Plays A then B (muted); returns per-10 ms RMS of the pre-volume signal and when the advance happened.
    func run(crossfade: Double) -> (rms: [Float], advanceAt: Double?) {
        let e = AudioEngine()
        e.setVolume(0)
        e.crossfadeSeconds = crossfade
        e.gapless = true
        var samples: [Float] = []
        let lock = NSLock()
        e.onTap = { buf in
            guard let d = buf.floatChannelData else { return }
            lock.lock(); samples += UnsafeBufferPointer(start: d[0], count: Int(buf.frameLength)); lock.unlock()
        }
        var advanceAt: Double?
        var served = false
        e.nextProvider = { served ? nil : { served = true; return (1, b1) }() }
        let t0 = Date()
        e.onAdvance = { _ in advanceAt = Date().timeIntervalSince(t0) }
        e.use(try! AVAudioFile(forReading: a1), url: a1, index: 0)
        e.play()
        while Date().timeIntervalSince(t0) < 5 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        e.stop()
        lock.lock(); defer { lock.unlock() }
        let rate = e.eq.outputFormat(forBus: 0).sampleRate
        let win = Int(rate / 100)
        let rms = stride(from: 0, to: max(0, samples.count - win), by: win).map { i -> Float in
            var s: Float = 0
            for k in i..<(i + win) { s += samples[k] * samples[k] }
            return (s / Float(win)).squareRoot()
        }
        return (rms, advanceAt)
    }

    // 1. Gapless: once the tone starts, no 10 ms window drops to silence until B ends (~4 s of audio).
    let g = run(crossfade: 0)
    let first = g.rms.firstIndex { $0 > 0.1 } ?? 0
    let body = Array(g.rms[first..<min(g.rms.count, first + 390)])
    let minLevel = body.min() ?? 0
    check(g.advanceAt != nil, "gapless: advanced to the next track automatically")
    check(body.count >= 390 && minLevel > 0.2, "gapless: no silent 10 ms window across the join (min rms \(String(format: "%.3f", minLevel)), 44.1 → 48 kHz)")

    // 2. Crossfade 1 s: the advance comes ~1 s before A's end, and the equal-power fade keeps the level up.
    let c = run(crossfade: 1)
    if let t = c.advanceAt { print("  crossfade advance at \(String(format: "%.2f", t)) s (A lasts 2.00 s)") }
    check((c.advanceAt ?? 9) < 1.6, "crossfade: next track starts about 1 s before the end")
    let cfirst = c.rms.firstIndex { $0 > 0.1 } ?? 0
    let cbody = Array(c.rms[cfirst..<min(c.rms.count, cfirst + 290)])
    check((cbody.min() ?? 0) > 0.2, "crossfade: no dip to silence (min rms \(String(format: "%.3f", cbody.min() ?? 0)))")

    // 2b. Balance: left/right level of A (44.1 kHz) and, after the gapless switch, of B (48 kHz, the other
    //     deck, reconnected for the new format). Changing it mid-track must apply at once too.
    func balanceRun(_ bal: Double, changeTo: Double? = nil) -> (a: (Float, Float), b: (Float, Float)) {
        let e = AudioEngine()
        e.setVolume(0)
        e.gapless = true
        e.setBalance(bal)
        var blocks: [(t: Double, l: Float, r: Float)] = []
        let lock = NSLock()
        let t0 = Date()
        e.onTap = { buf in
            guard let d = buf.floatChannelData, buf.format.channelCount >= 2 else { return }
            let n = Int(buf.frameLength)
            var l: Float = 0, r: Float = 0
            for i in 0..<n { l += d[0][i] * d[0][i]; r += d[1][i] * d[1][i] }
            lock.lock(); blocks.append((Date().timeIntervalSince(t0), (l / Float(max(1, n))).squareRoot(), (r / Float(max(1, n))).squareRoot())); lock.unlock()
        }
        var served = false
        e.nextProvider = { served ? nil : { served = true; return (1, b1) }() }
        e.use(try! AVAudioFile(forReading: a1), url: a1, index: 0)
        e.play()
        if let c = changeTo {
            while Date().timeIntervalSince(t0) < 0.6 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            e.setBalance(c)
        }
        while Date().timeIntervalSince(t0) < 3.6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        e.stop()
        lock.lock(); defer { lock.unlock() }
        func avg(_ from: Double, _ to: Double) -> (Float, Float) {
            let xs = blocks.filter { $0.t > from && $0.t < to && ($0.l + $0.r) > 0.01 }
            guard !xs.isEmpty else { return (0, 0) }
            return (xs.map(\.l).reduce(0, +) / Float(xs.count), xs.map(\.r).reduce(0, +) / Float(xs.count))
        }
        return (avg(1.0, 1.8), avg(2.5, 3.5))
    }
    func fmt(_ x: (Float, Float)) -> String { String(format: "L %.3f R %.3f", x.0, x.1) }
    let center = balanceRun(0), left = balanceRun(-100), right = balanceRun(100), half = balanceRun(50)
    check(abs(center.a.0 - center.a.1) < 0.01 && center.a.0 > 0.2, "balance centred: equal channels (\(fmt(center.a)))")
    check(left.a.1 < 0.02 && left.a.0 > 0.2, "balance full left: right silent (\(fmt(left.a)))")
    check(right.a.0 < 0.02 && right.a.1 > 0.2, "balance full right: left silent (\(fmt(right.a)))")
    check(half.a.0 < half.a.1 * 0.8 && half.a.0 > 0.05, "balance half right: left attenuated, not silent (\(fmt(half.a)))")
    check(left.b.1 < 0.02 && left.b.0 > 0.2 && right.b.0 < 0.02 && right.b.1 > 0.2, "balance kept on the next track at 48 kHz (left \(fmt(left.b)), right \(fmt(right.b)))")
    let moved = balanceRun(0, changeTo: -100)
    check(moved.a.1 < 0.02 && moved.a.0 > 0.2, "balance changed during playback (\(fmt(moved.a)))")

    // 3. EBU R128: stereo 1 kHz sine at -20 dBFS peak -> -20 LUFS (BS.1770 calibration).
    let cal = tone("cal.caf", freq: 997, seconds: 10, amp: 0.1, rate: 48000)
    if let (l, peak) = ReplayGain.measure(cal) {
        check(abs(l - -20) < 0.3, "loudness: 997 Hz -20 dBFS stereo = \(String(format: "%.2f", l)) LUFS (expected -20.0)")
        check(abs(peak - 0.1) < 0.005, "loudness: sample peak \(String(format: "%.3f", peak))")
    } else { check(false, "loudness: measure returned nil") }

    // 4. Tags: a TXXX-style block is found anywhere in the file, also UTF-16.
    let tagged = dir.appendingPathComponent("tagged.bin")
    var blob = Data(repeating: 0x41, count: 1000)
    blob += Data("TXXX".utf8) + Data([0, 0, 0, 30, 0, 0, 0]) + Data("REPLAYGAIN_TRACK_GAIN".utf8) + Data([0]) + Data("-6.54 dB".utf8)
    blob += Data("REPLAYGAIN_TRACK_PEAK".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + Data([0, 0]) + Data("0.988".utf16.flatMap { [UInt8($0 & 0xFF), 0] })
    try? blob.write(to: tagged)
    let info = ReplayGain.readTags(tagged)
    check(info?.trackGain == -6.54, "tags: REPLAYGAIN_TRACK_GAIN = \(info?.trackGain.map { String($0) } ?? "nil")")
    check(info?.trackPeak == 0.988, "tags: UTF-16 REPLAYGAIN_TRACK_PEAK = \(info?.trackPeak.map { String($0) } ?? "nil")")

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --replaygain file ...` prints tag values and the measured loudness.
if let i = CommandLine.arguments.firstIndex(of: "--replaygain") {
    for path in CommandLine.arguments[(i + 1)...] {
        let u = URL(fileURLWithPath: path)
        let tags = ReplayGain.readTags(u)
        let t0 = Date()
        let m = ReplayGain.measure(u)
        print("\(u.lastPathComponent)")
        print("  tag: gain \(tags?.trackGain.map { String(format: "%+.2f dB", $0) } ?? "none")  peak \(tags?.trackPeak.map { String(format: "%.3f", $0) } ?? "-")")
        if let (l, p) = m {
            print("  measured: \(String(format: "%.1f", l)) LUFS, peak \(String(format: "%.3f", p)) → gain \(String(format: "%+.1f", -18 - l)) dB (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
        }
    }
    exit(0)
}

/// Debug: `MusicAmp --test-ffmpeg` encodes short tones with ffmpeg and plays them back through the engine (muted).
if CommandLine.arguments.contains("--test-ffmpeg") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    guard let ff = FFmpeg.ffmpegPath else { print("ffmpeg not found"); exit(1) }
    print("decoding: ffmpeg \(FFmpeg.version ?? "?") at \(ff)")
    // Test files need encoders (lavfi, libopus) the bundled decode-only build doesn't have: use a full ffmpeg.
    let encoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ff
    print("test files: \(encoder)")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-ffmpeg", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let formats: [(String, [String])] = [("ogg", ["-c:a", "vorbis", "-strict", "-2"]), ("opus", ["-c:a", "libopus"]),
                                         ("wv", ["-c:a", "wavpack"]), ("tta", ["-c:a", "tta"])]
    for (ext, codec) in formats {
        let url = dir.appendingPathComponent("tone.\(ext)")
        try? FileManager.default.removeItem(at: url)
        FFmpeg.run(encoder, ["-y", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3:sample_rate=48000", "-ac", "2"] + codec + [url.path])
        guard FileManager.default.fileExists(atPath: url.path), let probe = FFmpeg.probe(url) else {
            check(false, "\(ext): encode/probe"); continue
        }
        check(abs(probe.duration - 3) < 0.15, "\(ext): probe \(probe.codec) \(Int(probe.sampleRate)) Hz, \(String(format: "%.2f", probe.duration)) s")
        let e = AudioEngine()
        e.setVolume(0)
        var rms: Float = 0
        e.onTap = { buf in
            guard let ch = buf.floatChannelData else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[0][i] * ch[0][i] }
            rms = max(rms, (sum / Float(max(1, buf.frameLength))).squareRoot())
        }
        var finished = false
        e.onFinish = { finished = true }
        e.useFFmpeg(url: url, probe: probe)
        e.play()
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 0.8 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let pos1 = e.currentTime
        e.seek(to: 2.0)
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 0.4 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let pos2 = e.currentTime
        while !finished, Date().timeIntervalSince(t1) < 3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        check(rms > 0.05, "\(ext): audio reaches the EQ (rms \(String(format: "%.3f", rms)))")
        check(pos1 > 0.4 && pos1 < 1.2, "\(ext): position advances (\(String(format: "%.2f", pos1)) s after 0.8 s)")
        check(pos2 >= 2.0 && pos2 < 2.8, "\(ext): seek to 2.0 s -> \(String(format: "%.2f", pos2)) s")
        check(finished, "\(ext): end of track reported")
        e.stop()
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-podcast [term]` checks search, feed parsing, OPML, speed and remote episode playback
/// (muted). Does not touch your subscriptions.
if let i = CommandLine.arguments.firstIndex(of: "--test-podcast") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    func wait(_ s: Double) { let t = Date(); while Date().timeIntervalSince(t) < s { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
    func await_<T>(_ f: @escaping () async throws -> T) -> T? {
        var out: T?, done = false
        Task { out = try? await f(); done = true }
        let t = Date()
        while !done, Date().timeIntervalSince(t) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return out
    }
    let term = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "il post"

    // 1-2. Apple catalogue search, then a real feed.
    let results = await_ { try await PodcastStore.search(term) } ?? []
    check(!results.isEmpty, "search \"\(term)\": \(results.count) podcast (\(results.first?.collectionName ?? "-"))")
    var episodeURL: URL?
    if let feedURL = results.first?.feedUrl, let u = URL(string: feedURL), let feed = await_({ try await PodcastStore.fetch(u) }) {
        let e = feed.episodes.first
        check(!feed.episodes.isEmpty, "feed: \(feed.title) — \(feed.episodes.count) episodes, latest \(e?.pubDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "?")")
        check(e?.duration != nil && feed.artworkURL != nil, "feed: duration (\(e?.duration.map { Ctl.hmmss($0) } ?? "-")) and artwork")
        episodeURL = e.flatMap { URL(string: $0.enclosure) }
    } else { check(false, "feed: fetch/parse") }

    // 3. Parser on edge cases.
    let xml = """
    <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Prova &amp; test</title>
    <image><url>https://e.x/img.jpg</url><title>ignore me</title></image><itunes:author>Autore</itunes:author>
    <item><title><![CDATA[Episodio <b>uno</b>]]></title><guid>g1</guid><pubDate>Tue, 07 Oct 2026 08:00:00 +0200</pubDate>
    <enclosure url="https://e.x/1.mp3" length="123" type="audio/mpeg"/><itunes:duration>1:02:03</itunes:duration></item>
    <item><title>Due</title><enclosure url="https://e.x/2.m4a"/><itunes:duration>754</itunes:duration>
    <pubDate>Mon, 6 Oct 2026 08:00:00 GMT</pubDate></item></channel></rss>
    """
    let pf = RSSParser.parse(Data(xml.utf8))
    check(pf?.title == "Prova & test" && pf?.author == "Autore" && pf?.artworkURL == "https://e.x/img.jpg", "rss: title, author, artwork")
    check(pf?.episodes.map(\.duration) == [3723, 754] && pf?.episodes.first?.id == "g1" && pf?.episodes.last?.id == "https://e.x/2.m4a",
          "rss: durations 1:02:03 and 754 s, guid or enclosure as id, sorted by date")

    // 4. OPML from another app.
    let opml = #"<opml><body><outline text="A" type="rss" xmlUrl="https://a.x/feed"/><outline text="cat"><outline xmlUrl="https://b.x/rss"/></outline></body></opml>"#
    check(PodcastStore.opmlFeeds(Data(opml.utf8)) == ["https://a.x/feed", "https://b.x/rss"], "opml: nested feeds too")

    // 5. Speed on a local tone: 1 s of clock at 2x plays ~2 s of audio.
    let dir = FileManager.default.temporaryDirectory
    let tone = dir.appendingPathComponent("musicamp-speed.caf")
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    if let f = try? AVAudioFile(forWriting: tone, settings: fmt.settings), let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100 * 6) {
        b.frameLength = 44100 * 6
        for k in 0..<Int(b.frameLength) { let v = Float(sin(Double(k) * 0.0627)) * 0.3; b.floatChannelData![0][k] = v; b.floatChannelData![1][k] = v }
        try? f.write(from: b)
    }
    let e = AudioEngine()
    e.setVolume(0)
    e.rate = 2
    e.use(try! AVAudioFile(forReading: tone), url: tone)
    e.play()
    wait(0.3)
    let a0 = e.currentTime
    wait(1.0)
    let a1 = e.currentTime
    e.stop()
    check(abs((a1 - a0) - 2.0) < 0.35, "speed 2×: 1 s of clock = \(String(format: "%.2f", a1 - a0)) s of audio")

    // 6. Remote episode streaming with seek and speed.
    if let u = episodeURL {
        let r = AudioEngine()
        r.setVolume(0)
        r.analysisEnabled = true
        r.milkdropEnabled = true
        r.playRemote(u, at: 60)
        wait(4)
        let level = r.milkdropData().left.map { abs($0) }.max() ?? 0
        check(r.remoteBridged && level > 0.001, "streaming: audio goes through our engine (EQ, visualizer, Milkdrop), peak \(String(format: "%.2f", level))")
        var lr: (Float, Float) = (0, 0)
        r.onTap = { buf in
            guard let d = buf.floatChannelData, buf.format.channelCount >= 2 else { return }
            var l: Float = 0, rr: Float = 0
            for i in 0..<Int(buf.frameLength) { l += d[0][i] * d[0][i]; rr += d[1][i] * d[1][i] }
            lr = (lr.0 + l, lr.1 + rr)
        }
        r.setBalance(100)
        wait(0.5)
        lr = (0, 0)   // measure only after the change has settled
        wait(1)
        check(lr.1 > 0.01 && lr.0 < lr.1 * 0.001, "streaming: balance full right (energy L \(String(format: "%.4f", lr.0)), R \(String(format: "%.1f", lr.1)))")
        r.setBalance(0)
        r.onTap = nil
        let p0 = r.currentTime
        check(p0 >= 60 && p0 < 66, "episode streaming: starts from the saved position (60 s → \(String(format: "%.1f", p0)))")
        r.rate = 1.5
        let t0 = r.currentTime
        wait(2)
        let adv = r.currentTime - t0
        check(adv > 2.4, "streaming at 1.5×: 2 s of clock = \(String(format: "%.1f", adv)) s")
        r.seek(to: 300)
        wait(2.5)
        check(abs(r.currentTime - 300) < 6, "streaming: seek to 300 s → \(String(format: "%.1f", r.currentTime))")
        r.unload()
    }

    // 7. Audiobook positions.
    let book = URL(fileURLWithPath: "/tmp/test-book.m4b")
    check(PlaybackPositions.remembers(book, duration: 60) && !PlaybackPositions.remembers(tone, duration: 200) &&
          PlaybackPositions.remembers(tone, duration: 25 * 60), "positions: .m4b always, other files over 20 minutes")
    PlaybackPositions.shared.set(book, 1234)
    check(PlaybackPositions.shared.position(book) == 1234, "positions: saved and read back")
    PlaybackPositions.shared.set(book, nil)
    wait(2.2)
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --test-lyrics` checks the LRC parser, sources and LRCLIB lookups. Prints counts only, never lyrics.
if CommandLine.arguments.contains("--test-lyrics") {
    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }
    func await_<T>(_ f: @escaping () async -> T) -> T? {
        var out: T?, done = false
        Task { out = await f(); done = true }
        let t = Date()
        while !done, Date().timeIntervalSince(t) < 30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return out
    }
    // 1. LRC parser (made-up lines).
    let lrc = "[ar:Test]\n[offset:+500]\n[00:01.50]prima\n[00:03.25][00:10.00]ritornello\n[00:05.1]seconda\nriga senza tempo\n"
    let parsed = LRC.parse(lrc) ?? []
    check(parsed.map(\.text) == ["prima", "ritornello", "seconda", "ritornello"], "lrc: 4 lines, multiple timestamps, tags ignored")
    check(abs(parsed[0].time - 1.0) < 0.001 && abs(parsed[2].time - 4.6) < 0.001, "lrc: +500 ms offset and hundredths/tenths")
    let ly = Lyrics(plain: nil, synced: parsed, source: "test")
    check(ly.lineIndex(at: 0.5) == nil && ly.lineIndex(at: 3.0) == 1 && ly.lineIndex(at: 99) == 3, "lrc: current line by time")

    // 1b. Enhanced LRC (word times) and estimated word timing (made-up words).
    let enh = LRC.parse("[00:02.00]<00:02.00>uno <00:02.50>due <00:03.20>tre\n[00:06.00]quattro cinque sei\n[00:30.00]sette\n") ?? []
    check(enh.first?.text == "uno due tre" && enh.first?.words?.count == 3, "enhanced lrc: 3 timed words, tags removed from the text")
    let el = Lyrics(plain: nil, synced: enh, source: "test")
    let w0 = el.timedWords(0)
    check(w0.count == 3 && abs(w0[1].start - 2.5) < 0.001 && abs(w0[1].end - 3.2) < 0.001, "enhanced lrc: word start/end from tags")
    check(w0[1].progress(2.4) == 0 && abs(w0[1].progress(2.85) - 0.5) < 0.01 && w0[1].progress(4) == 1, "word: progress 0 → 1")
    let w1 = el.timedWords(1)
    check(w1.count == 3 && w1[0].start == 6 && zip(w1, w1.dropFirst()).allSatisfy { $0.end <= $1.start + 0.001 } && w1.last!.end < 30,
          "word estimate: in order, within the line, before the next one")
    check(el.gap(after: 1) > 20, "long instrumental break detected")
    // Held notes: real word times with one long word; estimated line with much spare time before the next.
    let heldLRC = LRC.parse("[00:01.00]<00:01.00>la <00:01.30>la <00:01.60>looong <00:04.20>fine\n[00:05.00]dopo\n") ?? []
    let hw = Lyrics(plain: nil, synced: heldLRC, source: "test").timedWords(0)
    check(hw.map(\.held) == [false, false, true, false], "held word: detected from real timings (2.6 s vs 0.3 s)")
    let spare = Lyrics(plain: nil, synced: LRC.parse("[00:01.00]uno due tre\n[00:06.00]quattro cinque sei\n[00:07.20]sette\n") ?? [], source: "test")
    let sw = spare.timedWords(0), tight = spare.timedWords(1)
    check(sw.last?.held == true && sw.dropLast().allSatisfy { !$0.held } && (sw.last?.end ?? 0) <= 5.8, "held word: estimated on the last word when the line has spare time")
    check(tight.allSatisfy { !$0.held }, "no held word in a line without spare time")

    // 2. Sidecar .lrc next to the file.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musicamp-lyrics", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let song = dir.appendingPathComponent("song.mp3")
    FileManager.default.createFile(atPath: song.path, contents: Data())
    try? lrc.write(to: dir.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8)
    check(LyricsService.sidecar(song)?.synced?.count == 4, "sidecar: song.lrc next to song.mp3")

    // 3. Queries from tags, "Artist - Title" names and radio titles.
    let t1 = Track(url: URL(fileURLWithPath: "/x/03. Anti-Hero.mp3"), title: "Taylor Swift - Anti-Hero")
    let q1 = LyricsService.query(for: t1, duration: 200.7)
    check(q1?.artist == "Taylor Swift" && q1?.title == "Anti-Hero", "query: from \"Artist - Title\"")
    let radio = Track(url: URL(string: "http://radio.example/stream")!, title: "Radio")
    radio.streamTitle = "Coldplay - Yellow"
    check(LyricsService.query(for: radio, duration: 0)?.artist == "Coldplay", "query: from the radio's now-playing title")

    // 4. LRCLIB, real lookups (counts only).
    for (artist, title, dur) in [("Taylor Swift", "Anti-Hero", 200.7), ("Taylor Swift", "Sweet Nothing", 188.0)] {
        let q = LyricsService.Query(artist: artist, title: title, album: nil, duration: dur, file: nil)
        let r = await_ { try? await LyricsService.lrclib(q) } ?? nil
        check(r != nil && (r?.synced?.count ?? 0) > 10, "lrclib: \(title) — found, \(r?.synced?.count ?? 0) synced lines, \(r?.plain?.split(separator: "\n").count ?? 0) plain lines")
    }
    let none = await_ { try? await LyricsService.lrclib(LyricsService.Query(artist: "Zzqx Nonexistent Band", title: "Qwxz Song", duration: 100)) } ?? nil
    check(none == nil, "lrclib: nonexistent track → no result")
    let wrongLength = await_ { try? await LyricsService.lrclib(LyricsService.Query(artist: "Taylor Swift", title: "Anti-Hero", duration: 600)) } ?? nil
    check(wrongLength == nil, "lrclib: duration too different (600 s) → rejected, probably another track")
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

/// Debug: `MusicAmp --parse-cursor file.ani|file.cur` prints frame count, delays and hotspots.
if let i = CommandLine.arguments.firstIndex(of: "--parse-cursor"), CommandLine.arguments.count > i + 1 {
    guard let c = SkinCursor.load(URL(fileURLWithPath: CommandLine.arguments[i + 1])) else { print("parse failed"); exit(1) }
    print("frames: \(c.frames.count)  delays: \(c.delays.map { String(format: "%.3f", $0) })")
    print("hotspots: \(c.frames.map { "\(Int($0.hotSpot.x)),\(Int($0.hotSpot.y))" })")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 2 {
    snapshot(Array(CommandLine.arguments[(i + 1)...]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
