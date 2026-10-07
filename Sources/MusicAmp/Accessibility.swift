import AppKit

/// One accessible control drawn by a skin view, in the view's logical (1x) coordinates.
struct AXItem {
    enum Kind { case button, toggle, slider, text, row }

    let id: String
    let kind: Kind
    let label: String
    let rect: CGRect
    var value: String? = nil
    var on: Bool = false
    var selected: Bool = false
    var press: (() -> Void)? = nil
    var increment: (() -> Void)? = nil
    var decrement: (() -> Void)? = nil
}

/// Accessibility element backed by an AXItem; its frame follows the skin rect, scale and window position.
final class SkinAXElement: NSAccessibilityElement {
    weak var view: SkinView?
    var item: AXItem

    init(item: AXItem, view: SkinView) {
        self.item = item
        self.view = view
        super.init()
        apply()
    }

    func apply() {
        setAccessibilityParent(view)
        setAccessibilityIdentifier(item.id)
        setAccessibilityLabel(item.label)
        switch item.kind {
        case .button:
            setAccessibilityRole(.button)
        case .toggle:
            setAccessibilityRole(.checkBox)
            setAccessibilityValue(item.on ? 1 : 0)
        case .slider:
            setAccessibilityRole(.slider)
            setAccessibilityValue(item.value)
        case .text:
            setAccessibilityRole(.staticText)
            setAccessibilityValue(item.value)
        case .row:
            setAccessibilityRole(.button)
            setAccessibilityValue(item.value)
            setAccessibilitySelected(item.selected)
        }
    }

    override func accessibilityFrame() -> NSRect {
        guard let v = view, let w = v.window else { return .zero }
        let s = v.scale
        let r = NSRect(x: item.rect.minX * s, y: item.rect.minY * s, width: item.rect.width * s, height: item.rect.height * s)
        return w.convertToScreen(v.convert(r, to: nil))
    }

    override func isAccessibilityElement() -> Bool { true }
    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let p = item.press else { return false }
        p()
        view?.needsDisplay = true
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard let f = item.increment else { return false }
        f()
        view?.needsDisplay = true
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let f = item.decrement else { return false }
        f()
        view?.needsDisplay = true
        return true
    }
}

extension SkinView {
    /// Builds (or refreshes, keeping identity) the elements for the current items.
    func axElements() -> [SkinAXElement] {
        let items = accessibilityItems()
        var out: [SkinAXElement] = []
        var next: [String: SkinAXElement] = [:]
        for it in items {
            let el: SkinAXElement
            if let old = axCache[it.id] {
                old.item = it
                old.apply()
                el = old
            } else {
                el = SkinAXElement(item: it, view: self)
            }
            next[it.id] = el
            out.append(el)
        }
        axCache = next
        return out
    }
}

/// Labels shared by the skin windows.
enum AXText {
    static func time(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }

    static func balance(_ b: Double) -> String {
        b == 0 ? "center" : "\(Int(abs(b).rounded()))% \(b < 0 ? "left" : "right")"
    }
}
