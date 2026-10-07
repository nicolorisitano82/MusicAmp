import AppKit

final class SkinWindow: NSWindow {
    init(view: SkinView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 275, height: 116), styleMask: [.borderless, .miniaturizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        contentView = view
        initialFirstResponder = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Base view: renders a logical (1x) framebuffer and scales it nearest-neighbour,
/// clipped to the skin's region.txt polygon when present.
class SkinView: NSView {
    var ctl: Ctl { Ctl.shared }
    /// Set to render this view with another skin (preferences preview) instead of the active one.
    var previewSkin: Skin?
    var skin: Skin { previewSkin ?? ctl.skin }
    var logicalSize: CGSize { CGSize(width: 275, height: 116) }
    var regionKey: String? { nil }
    var scale: CGFloat { ctl.scale }
    var isActive: Bool { previewSkin != nil || (window?.isKeyWindow ?? false) }

    private var windowDrag = false
    private var drawnSignature: Int?
    var axCache: [String: SkinAXElement] = [:]

    // MARK: Accessibility (VoiceOver)
    // The skin is pixels, so each view lists its controls as AXItems; they become NSAccessibilityElements.

    var accessibilityName: String { "MusicAmp" }
    func accessibilityItems() -> [AXItem] { [] }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { accessibilityName }
    override func accessibilityChildren() -> [Any]? { axElements() }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        let els = axElements()
        return els.last { $0.accessibilityFrame().contains(point) } ?? self
    }

    /// Hash of everything the view shows. The timer redraws only when it differs from the last drawn frame.
    var renderSignature: Int { 0 }

    func refreshIfChanged() {
        if renderSignature != drawnSignature { needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Subclass hooks
    func render(_ r: Renderer) {}
    func hitDown(_ p: CGPoint, _ e: NSEvent) -> Bool { false }
    func hitDrag(_ p: CGPoint, _ e: NSEvent) {}
    func hitUp(_ p: CGPoint, _ e: NSEvent) {}
    func cursorAreas() -> [(String, CGRect)] { [] }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let size = logicalSize
        guard let r = Renderer(width: Int(size.width), height: Int(size.height), skin: skin) else { return }
        drawnSignature = renderSignature
        render(r)
        guard let img = r.image() else { return }
        cg.clear(bounds)
        cg.saveGState()
        if let key = regionKey, let polys = skin.regions[key], !polys.isEmpty {
            let path = CGMutablePath()
            for poly in polys {
                path.addLines(between: poly.map { CGPoint(x: $0.x * scale, y: $0.y * scale) })
                path.closeSubpath()
            }
            cg.addPath(path)
            cg.clip()
        }
        cg.interpolationQuality = .none
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(img, in: CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        cg.restoreGState()
    }

    func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / scale, y: p.y / scale)
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if hitDown(point(e), e) {
            windowDrag = false
        } else if let w = window {
            windowDrag = true
            ctl.beginDrag(w)
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        if windowDrag { ctl.continueDrag() } else { hitDrag(point(e), e) }
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        if windowDrag {
            windowDrag = false
            ctl.endDrag()
        } else {
            hitUp(point(e), e)
        }
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        if !ctl.handleKey(e) { super.keyDown(with: e) }
    }

    // MARK: Skin cursors (.cur)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// cursorAreas() is ordered background-first; the last area containing the point wins.
    func updateCursor(_ e: NSEvent) {
        let p = point(e)
        let name = cursorAreas().last { $0.1.contains(p) }?.0
        CursorAnimator.shared.show(name.flatMap { skin.cursors[$0] })
    }

    override func mouseExited(with e: NSEvent) {
        CursorAnimator.shared.stop()
        NSCursor.arrow.set()
    }

    override func mouseMoved(with e: NSEvent) { updateCursor(e) }
    override func cursorUpdate(with e: NSEvent) { updateCursor(e) }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        ctl.handleDrop(urls, toPlaylist: self is PlaylistView)
        return true
    }

    // MARK: Helpers

    func popUp(_ menu: NSMenu, at p: CGPoint) {
        menu.popUp(positioning: nil, at: NSPoint(x: p.x * scale, y: p.y * scale), in: self)
    }
}
