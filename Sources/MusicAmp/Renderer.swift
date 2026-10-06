import AppKit
import CoreText

/// 1:1 pixel framebuffer addressed with Winamp's top-left coordinates.
final class Renderer {
    let ctx: CGContext
    let width: Int
    let height: Int
    let skin: Skin

    init?(width: Int, height: Int, skin: Skin) {
        guard width > 0, height > 0,
              let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx = c
        self.width = width
        self.height = height
        self.skin = skin
        c.interpolationQuality = .none
        c.setShouldAntialias(false)
    }

    func image() -> CGImage? { ctx.makeImage() }

    private func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: CGFloat(height) - r.minY - r.height, width: r.width, height: r.height)
    }

    /// Copies `src` from a skin sheet to (x, y). Out-of-bounds source areas are skipped, like Winamp does.
    func blit(_ sheet: String, _ src: CGRect, _ x: CGFloat, _ y: CGFloat, w: CGFloat? = nil, h: CGFloat? = nil) {
        guard let img = skin.image(sheet) else { return }
        let s = src.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard !s.isNull, !s.isEmpty, let sub = img.cropping(to: s) else { return }
        let sx = (w ?? src.width) / src.width
        let sy = (h ?? src.height) / src.height
        let dst = CGRect(x: x + (s.minX - src.minX) * sx, y: y + (s.minY - src.minY) * sy,
                         width: s.width * sx, height: s.height * sy)
        ctx.draw(sub, in: flip(dst))
    }

    /// Repeats `src` horizontally over [x, x+width).
    func tileX(_ sheet: String, _ src: CGRect, _ x: CGFloat, _ y: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        clip(R(x, y, width, src.height)) {
            var cx = x
            while cx < x + width {
                blit(sheet, src, cx, y)
                cx += src.width
            }
        }
    }

    func tileY(_ sheet: String, _ src: CGRect, _ x: CGFloat, _ y: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        clip(R(x, y, src.width, height)) {
            var cy = y
            while cy < y + height {
                blit(sheet, src, x, cy)
                cy += src.height
            }
        }
    }

    func fill(_ c: CGColor, _ r: CGRect) {
        ctx.setFillColor(c)
        ctx.fill(flip(r))
    }

    func clip(_ r: CGRect, _ body: () -> Void) {
        ctx.saveGState()
        ctx.clip(to: flip(r))
        body()
        ctx.restoreGState()
    }

    /// Draws a string with the skin's TEXT.BMP bitmap font (5x6 cells).
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat) {
        var cx = x
        for ch in s {
            let (col, row) = Skin.charPos(ch)
            blit("text", R(CGFloat(col * 5), CGFloat(row * 6), 5, 6), cx, y)
            cx += 5
        }
    }

    /// Draws text with a system font (used by the playlist). Returns the drawn width.
    @discardableResult
    func ttf(_ s: String, font: NSFont, color: CGColor, x: CGFloat, baseline: CGFloat, maxWidth: CGFloat,
             alignRight: Bool = false) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        var w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if w > maxWidth {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            if let t = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, token) { line = t }
            w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(color)
        ctx.textPosition = CGPoint(x: alignRight ? x - w : x, y: CGFloat(height) - baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return w
    }
}
