// Generates Resources/AppIcon.icns: `swift Scripts/make-icon.swift`
// Original artwork: graphite squircle, LCD with pixel spectrum bars (classic viscolor palette), orange seek bar.
import AppKit

func C(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func gradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func rr(_ r: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil) }

/// Draws the icon on a 1024-unit canvas (top-left origin) scaled to `px`.
func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    let small = px <= 64

    // Body with drop shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: C(0x000000, 0.45))
    ctx.addPath(rr(body, 185)); ctx.setFillColor(C(0x1A1D2B)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rr(body, 185)); ctx.clip()
    gradient(ctx, [C(0x474E70), C(0x262A3D), C(0x14161F)], from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
    // brushed-metal streaks
    if !small {
        for i in stride(from: 110, to: 924, by: 6) {
            ctx.setFillColor(C(0xFFFFFF, i % 12 == 2 ? 0.025 : 0.012))
            ctx.fill(CGRect(x: 100, y: CGFloat(i), width: 824, height: 2))
        }
    }
    ctx.restoreGState()
    // Bevel: top highlight, inner dark line
    ctx.addPath(rr(body.insetBy(dx: 3, dy: 3), 182)); ctx.setStrokeColor(C(0xFFFFFF, 0.22)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.addPath(rr(body.insetBy(dx: 22, dy: 22), 165)); ctx.setStrokeColor(C(0x000000, 0.35)); ctx.setLineWidth(4); ctx.strokePath()

    // LCD panel
    let lcd = CGRect(x: 180, y: 196, width: 664, height: 460)
    ctx.addPath(rr(lcd.insetBy(dx: -10, dy: -10), 58)); ctx.setFillColor(C(0x0B0D14)); ctx.fillPath()
    ctx.addPath(rr(lcd.insetBy(dx: -10, dy: -10), 58)); ctx.setStrokeColor(C(0x8A93B8, 0.35)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.saveGState()
    ctx.addPath(rr(lcd, 48)); ctx.clip()
    gradient(ctx, [C(0x08160D), C(0x030805)], from: CGPoint(x: 0, y: lcd.minY), to: CGPoint(x: 0, y: lcd.maxY))
    if !small {
        ctx.setFillColor(C(0x1C3A24, 0.8))
        for y in stride(from: lcd.minY + 22, to: lcd.maxY, by: 28) {
            for x in stride(from: lcd.minX + 22, to: lcd.maxX, by: 28) { ctx.fill(CGRect(x: x, y: y, width: 6, height: 6)) }
        }
    }

    // Spectrum: 9 bars of pixel blocks, coloured by row like viscolor.txt (green bottom → red top)
    let rows: [UInt32] = [0x18840A, 0x29CE10, 0x39B510, 0x94DE21, 0xBDDE29, 0xDEA518, 0xD67300, 0xCE2910, 0xEF3110]
    let heights = [5, 8, 9, 7, 6, 7, 5, 4, 2]
    let peaks = [7, 9, 9, 8, 8, 8, 7, 6, 4]
    let barW: CGFloat = 50, gap: CGFloat = 14
    let blockH: CGFloat = 32, blockGap: CGFloat = small ? 4 : 9
    let left = lcd.midX - (9 * barW + 8 * gap) / 2
    let bottom = lcd.maxY - 34
    ctx.setShadow(offset: .zero, blur: small ? 0 : 22, color: C(0x3CFF5A, 0.45))
    for (b, h) in heights.enumerated() {
        let x = left + CGFloat(b) * (barW + gap)
        for r in 0..<h {
            let y = bottom - CGFloat(r + 1) * (blockH + blockGap) + blockGap
            ctx.setFillColor(C(rows[r]))
            ctx.fill(CGRect(x: x, y: y, width: barW, height: blockH))
        }
        if peaks[b] > h {
            let y = bottom - CGFloat(peaks[b]) * (blockH + blockGap) + blockGap + blockH - 12
            ctx.setFillColor(C(0xB4B4B4))
            ctx.fill(CGRect(x: x, y: y, width: barW, height: 12))
        }
    }
    ctx.restoreGState()
    // glass highlight on the LCD
    ctx.saveGState()
    ctx.addPath(rr(lcd, 48)); ctx.clip()
    gradient(ctx, [C(0xFFFFFF, 0.10), C(0xFFFFFF, 0)], from: CGPoint(x: 0, y: lcd.minY), to: CGPoint(x: 0, y: lcd.minY + 170))
    ctx.restoreGState()

    // Seek bar
    let track = CGRect(x: 180, y: 724, width: 664, height: 52)
    ctx.addPath(rr(track, 26)); ctx.setFillColor(C(0x07080D)); ctx.fillPath()
    ctx.addPath(rr(track, 26)); ctx.setStrokeColor(C(0x8A93B8, 0.3)); ctx.setLineWidth(4); ctx.strokePath()
    let fill = CGRect(x: track.minX + 8, y: track.minY + 8, width: 664 * 0.62, height: 36)
    ctx.saveGState()
    ctx.addPath(rr(fill, 18)); ctx.clip()
    gradient(ctx, [C(0xFFC14A), C(0xF08A1C), C(0xC4520C)], from: CGPoint(x: 0, y: fill.minY), to: CGPoint(x: 0, y: fill.maxY))
    ctx.restoreGState()
    let thumb = CGRect(x: fill.maxX - 44, y: track.midY - 42, width: 96, height: 84)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 12, color: C(0x000000, 0.5))
    ctx.addPath(rr(thumb, 20)); ctx.setFillColor(C(0xC8CCD8)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(rr(thumb, 20)); ctx.clip()
    gradient(ctx, [C(0xFFFFFF), C(0xCDD2E0), C(0x8C93A8)], from: CGPoint(x: 0, y: thumb.minY), to: CGPoint(x: 0, y: thumb.maxY))
    ctx.restoreGState()
    if !small {
        for i in 0..<3 {
            let gx = thumb.midX - 18 + CGFloat(i) * 18
            ctx.setFillColor(C(0x5A6078)); ctx.fill(CGRect(x: gx - 2, y: thumb.minY + 22, width: 5, height: 40))
            ctx.setFillColor(C(0xFFFFFF, 0.8)); ctx.fill(CGRect(x: gx + 3, y: thumb.minY + 22, width: 2, height: 40))
        }
    }
    return ctx.makeImage()!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for mult in [1, 2] {
        let name = mult == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(base * mult))
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK: Resources/AppIcon.icns" : "iconutil failed")
