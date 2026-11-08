import AppKit

@MainActor
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class PassageMask: FlippedView {
    var activateInput: (() -> Void)?
    override func mouseDown(with event: NSEvent) { activateInput?() }
}

@MainActor
final class CaretView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class HeaderDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

@MainActor
final class PracticeWindow: NSWindow {
    var handleShortcut: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// The native editor supplies text services/IME; the separate target view supplies ink.
@MainActor
final class PassageEditor: NSTextView {
    var canBackspace: (() -> Bool)?
    var focusChanged: ((Bool) -> Void)?
    var compositionEnded: (() -> Void)?
    var cancel: (() -> Void)?
    var compositionAnchor: (() -> NSRect?)?

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let anchor = compositionAnchor?() else {
            return super.firstRect(forCharacterRange: range, actualRange: actualRange)
        }
        actualRange?.pointee = range
        return anchor
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76, 115, 116, 119, 121, 123, 124, 125, 126:
            if !hasMarkedText() { return }
        case 51, 117:
            if !hasMarkedText(), canBackspace?() == false { return }
        default: break
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusChanged?(false) }
        return accepted
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        super.unmarkText()
        if wasMarked { compositionEnded?() }
    }

    override func cancelOperation(_ sender: Any?) { cancel?() }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
    // Clipboard and drag insertion deliberately do not participate in a typing test.
    override func paste(_ sender: Any?) {}
    override func pasteAsPlainText(_ sender: Any?) {}
    override func pasteAsRichText(_ sender: Any?) {}
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }

    override func selectAll(_ sender: Any?) {
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:))].contains(item.action) { return false }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class ProgressRing: NSView {
    var progress = 0.0 {
        didSet {
            guard progress != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(progress * 100)
        }
    }
    var foreground = NSColor.white {
        didSet { if foreground != oldValue { needsDisplay = true } }
    }
    var track = NSColor.white.withAlphaComponent(0.1) {
        didSet { if track != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Practice progress")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        setAccessibilityValue(0)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.75, dy: 1.75))
        circle.lineWidth = 1.5
        track.setStroke()
        circle.stroke()
        guard progress > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: 8, y: 8), radius: 6.25,
            startAngle: 90, endAngle: 90 - CGFloat(min(1, max(0, progress))) * 360, clockwise: true)
        arc.lineWidth = 1.5
        foreground.setStroke()
        arc.stroke()
    }
}
