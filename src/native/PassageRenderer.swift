import AppKit

@MainActor
final class PassageRenderer {
    private let targetText: NSTextView
    private let editor: NSTextView
    private let content: NSView
    private let caret: NSView
    private let paragraphStyle: NSParagraphStyle
    private weak var renderedSession: TypingSession?
    private var target: NSString?
    private var renderedFont: NSFont?
    private var renderedRevision = -1
    private var caretLength: Int?
    private var contentHeight: CGFloat?
    private var colorsInvalid = true
    private(set) var isUpdating = false

    init(targetText: NSTextView, editor: NSTextView, content: NSView,
         caret: NSView, paragraphStyle: NSParagraphStyle) {
        self.targetText = targetText
        self.editor = editor
        self.content = content
        self.caret = caret
        self.paragraphStyle = paragraphStyle
    }

    func invalidateColors() { colorsInvalid = true }

    func render(session: TypingSession, font: NSFont,
                primary: NSColor, secondary: NSColor, acceptedInput: Bool) {
        guard let storage = targetText.textStorage else { return }
        isUpdating = true
        defer { isUpdating = false }
        let sessionChanged = renderedSession !== session
        let passageChanged = target == nil || (sessionChanged && target?.isEqual(to: session.passage.text) != true)
        let rebuilt = passageChanged || renderedFont !== font
        if rebuilt {
            let attributes: [NSAttributedString.Key: Any] = [.font: font,
                .paragraphStyle: paragraphStyle, .ligature: 0, .foregroundColor: secondary]
            storage.setAttributedString(NSAttributedString(string: session.passage.text, attributes: attributes))
            var invisibleAttributes = attributes
            invisibleAttributes[.foregroundColor] = NSColor.clear
            editor.typingAttributes = invisibleAttributes
            editor.textStorage?.setAttributedString(NSAttributedString(string: session.typed, attributes: invisibleAttributes))
            target = session.passage.text as NSString
            renderedFont = font
            caretLength = nil
            contentHeight = nil
        }
        guard let target else { return }
        let length = target.length
        let changed: NSRange
        if rebuilt || sessionChanged || colorsInvalid {
            changed = NSRange(location: 0, length: length)
        } else if renderedRevision != session.textRevision {
            changed = session.textRevision == renderedRevision + 1
                ? NSIntersectionRange(session.dirtyRange, NSRange(location: 0, length: length))
                : NSRange(location: 0, length: length)
        } else {
            changed = NSRange(location: 0, length: 0)
        }
        if changed.length > 0 {
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: secondary, range: changed)
            let typed = NSIntersectionRange(changed, NSRange(location: 0, length: min(length, session.typedLength)))
            if typed.length > 0 { storage.addAttribute(.foregroundColor, value: primary, range: typed) }
            for mistake in session.mistakes {
                let intersection = NSIntersectionRange(mistake, changed)
                if intersection.length > 0 { storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: intersection) }
            }
            storage.endEditing()
        }
        colorsInvalid = false
        if !editor.hasMarkedText() {
            reconcileEditor(session: session, acceptedInput: acceptedInput && !rebuilt && !sessionChanged)
            let selection = NSRange(location: session.typedLength, length: 0)
            if editor.selectedRange() != selection { editor.setSelectedRange(selection) }
        }
        if caretLength != session.typedLength || rebuilt {
            positionCaret(at: session.typedLength, target: target)
        }
        renderedSession = session
        renderedRevision = session.textRevision
    }

    private func reconcileEditor(session: TypingSession, acceptedInput: Bool) {
        guard let storage = editor.textStorage else { return }
        if acceptedInput, storage.length >= session.typedLength {
            // Cocoa already inserted accepted input. Discard only a suffix left by a prefix edit.
            if storage.length > session.typedLength {
                storage.replaceCharacters(in: NSRange(location: session.typedLength,
                    length: storage.length - session.typedLength), with: "")
            }
            return
        }
        // Restore rejected input or a changed session without replacing unaffected text.
        let desired = session.typed as NSString
        let actual = storage.string as NSString
        var start = 0
        let commonLength = min(actual.length, desired.length)
        while start < commonLength && actual.character(at: start) == desired.character(at: start) { start += 1 }
        if start == actual.length && start == desired.length { return }
        var oldEnd = actual.length
        var newEnd = desired.length
        while oldEnd > start && newEnd > start && actual.character(at: oldEnd - 1) == desired.character(at: newEnd - 1) {
            oldEnd -= 1
            newEnd -= 1
        }
        while start > 0 && (!isScalarBoundary(actual, at: start) || !isScalarBoundary(desired, at: start)) { start -= 1 }
        while oldEnd < actual.length && newEnd < desired.length &&
            (!isScalarBoundary(actual, at: oldEnd) || !isScalarBoundary(desired, at: newEnd)) {
            oldEnd += 1
            newEnd += 1
        }
        storage.replaceCharacters(in: NSRange(location: start, length: oldEnd - start),
            with: desired.substring(with: NSRange(location: start, length: newEnd - start)))
    }

    private func isScalarBoundary(_ text: NSString, at index: Int) -> Bool {
        guard index >= 0 && index <= text.length else { return false }
        guard index > 0 && index < text.length else { return true }
        return !(0xD800...0xDBFF).contains(text.character(at: index - 1)) ||
            !(0xDC00...0xDFFF).contains(text.character(at: index))
    }

    private func positionCaret(at typedLength: Int, target: NSString) {
        guard let layout = targetText.layoutManager, let container = targetText.textContainer else { return }
        layout.ensureLayout(for: container)
        guard target.length > 0, layout.numberOfGlyphs > 0 else { return }
        let character = min(typedLength, target.length)
        let glyph = layout.glyphIndexForCharacter(at: min(character, target.length - 1))
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = line.minX + layout.location(forGlyphAt: glyph).x
        var y = line.minY
        if character == target.length {
            if target.hasSuffix("\n") {
                x = layout.extraLineFragmentRect.minX
                y = layout.extraLineFragmentRect.minY
            } else {
                x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
            }
        }
        if contentHeight == nil {
            let height = max(400, layout.usedRect(for: container).maxY + 40)
            let size = NSSize(width: 670, height: height)
            if targetText.frame.size != size { targetText.setFrameSize(size) }
            if editor.frame.size != size { editor.setFrameSize(size) }
            if content.frame.size != size { content.setFrameSize(size) }
            contentHeight = height
        }
        let origin = NSPoint(x: 40, y: 143 - y)
        if content.frame.origin != origin { content.setFrameOrigin(origin) }
        let frame = NSRect(x: x, y: y + 5, width: 2, height: 30)
        if caret.frame != frame { caret.frame = frame }
        caretLength = typedLength
    }
}
