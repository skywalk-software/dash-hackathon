import EditorInteractionKit
import SwiftUI
import AppKit

struct NativeTextEditor: NSViewRepresentable {
    let text: String
    let ranges: [DocumentTextRange]
    var changes: [EditingEngine.Change] = []
    var inspectedChangeID: String?
    var inspectionRequest: UUID?
    var onInspect: (String) -> Void = { _ in }
    var onRendered: (String, UInt64) -> Void = { _, _ in }
    var onComposition: (Bool) -> Void = { _ in }
    let onEvent: (String, [DocumentTextRange], String, UUID?, UInt64, Bool) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let view = CursorTrackingTextView(frame: scroll.bounds)
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.font = EditorTheme.nativeFont(18)
        view.backgroundColor = NSColor(EditorTheme.paper)
        view.textColor = NSColor(EditorTheme.ink)
        view.insertionPointColor = NSColor(EditorTheme.navy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 27
        paragraph.maximumLineHeight = 27
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: EditorTheme.nativeFont(18), .foregroundColor: NSColor(EditorTheme.ink), .paragraphStyle: paragraph]
        view.isRichText = false
        view.allowsUndo = true
        view.textContainerInset = NSSize(width: 43, height: 48)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Document text")
        view.setAccessibilityIdentifier("document-editor")
        view.actionEnded = { [weak coordinator = context.coordinator] view in coordinator?.emit(view, forceAction: true) }
        view.inspectAt = { [weak coordinator = context.coordinator] offset in
            guard let parent = coordinator?.parent else { return }
            let hits = parent.changes.reversed().filter { change in change.hunks.contains { h in
                h.active && (h.length == 0 ? abs(h.location - offset) <= 1 : offset >= h.location && offset <= h.location + h.length)
            } }
            if let hit = hits.first { parent.onInspect(hit.id) }
        }
        scroll.backgroundColor = NSColor(EditorTheme.paper)
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? CursorTrackingTextView else { preconditionFailure("Expected CursorTrackingTextView") }
        guard !view.hasMarkedText() else { return }
        context.coordinator.isRendering = true
        defer { context.coordinator.isRendering = false }
        if context.coordinator.lastText == nil {
            view.string = text
        } else if view.string != text {
            view.breakUndoCoalescing()
            let change = DocumentChange(before: view.string, after: text)
            let replacement = (text as NSString).substring(with: NSRange(location: change.replacedRange.location, length: change.insertedUTF16Count))
            view.insertText(replacement, replacementRange: change.replacedRange.nsRange)
            view.breakUndoCoalescing()
            context.coordinator.parent.onRendered(view.string, SessionClock.nowNanoseconds())
        }
        let desired = ranges.map { NSValue(range: $0.nsRange) }
        if !desired.isEmpty && view.selectedRanges != desired { view.selectedRanges = desired }
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor] {
            view.layoutManager?.removeTemporaryAttribute(key, forCharacterRange: full)
        }
        view.deletionOffsets = []
        for change in changes {
            let selected = change.id == inspectedChangeID
            let age = max(0, Date().timeIntervalSince1970 * 1000 - change.committedAt)
            let flashAlpha = max(0.035, 0.25 * (1 - age / 3000))
            for h in change.hunks where h.active && h.location >= 0 && h.location + h.length <= full.length {
                if h.length == 0 { view.deletionOffsets.append(h.location); continue }
                let range = NSRange(location: h.location, length: h.length)
                view.layoutManager?.addTemporaryAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: NSColor.systemTeal,
                    .backgroundColor: NSColor.systemTeal.withAlphaComponent(selected ? 0.30 : flashAlpha)
                ], forCharacterRange: range)
            }
        }
        if context.coordinator.inspectionRequest != inspectionRequest {
            context.coordinator.inspectionRequest = inspectionRequest
            if let change = changes.first(where: { $0.id == inspectedChangeID }), let h = change.hunks.first(where: { $0.active }) {
                view.scrollRangeToVisible(NSRange(location: min(h.location, full.length), length: min(h.length, max(0, full.length - h.location))))
            }
        }
        view.needsDisplay = true
        context.coordinator.lastText = view.string
        context.coordinator.lastRanges = view.selectedRanges
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeTextEditor
        var isRendering = false
        var inspectionRequest: UUID?
        var lastText: String?
        var lastRanges: [NSValue]?
        init(_ parent: NativeTextEditor) { self.parent = parent }
        func emit(_ view: CursorTrackingTextView, forceAction: Bool = false) {
            guard !isRendering else { return }
            parent.onComposition(view.hasMarkedText())
            if !forceAction && lastText == view.string && lastRanges == view.selectedRanges { return }
            lastText = view.string; lastRanges = view.selectedRanges
            if !forceAction { view.changedDuringAction = true }
            let ranges = view.selectedRanges.map { DocumentTextRange(location: $0.rangeValue.location, length: $0.rangeValue.length) }
            parent.onEvent(view.string, ranges, view.actionSource ?? "accessibility_or_command", view.actionID,
                           SessionClock.nowNanoseconds(), forceAction)
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? CursorTrackingTextView else { return }
            emit(view)
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? CursorTrackingTextView else { return }
            emit(view)
        }
    }
}

final class CursorTrackingTextView: NSTextView {
    var inspectAt: ((Int) -> Void)?
    var deletionOffsets: [Int] = []
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        for offset in deletionOffsets {
            let point: NSPoint
            if offset < (string as NSString).length {
                let glyph = layoutManager.glyphIndexForCharacter(at: offset)
                let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                point = NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
            } else {
                let rect = layoutManager.extraLineFragmentRect
                if rect.height > 0 { point = NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y) }
                else if layoutManager.numberOfGlyphs > 0 {
                    let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: layoutManager.numberOfGlyphs - 1, length: 1), in: textContainer)
                    point = NSPoint(x: rect.maxX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
                } else { point = textContainerOrigin }
            }
            NSColor.systemOrange.setFill()
            NSBezierPath(roundedRect: NSRect(x: point.x - 2, y: point.y, width: 4, height: 18), xRadius: 2, yRadius: 2).fill()
        }
    }
    var actionSource: String?
    var actionID: UUID?
    var changedDuringAction = false
    var actionEnded: ((CursorTrackingTextView) -> Void)?
    private func action(_ source: String, perform: () -> Void) {
        actionSource = source; actionID = UUID(); changedDuringAction = false
        perform()
        actionEnded?(self)
        actionSource = nil; actionID = nil
    }
    override func mouseDown(with event: NSEvent) {
        action("mouse") { super.mouseDown(with: event) }
        if selectedRange().length == 0 { inspectAt?(characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))) }
    }
    override func keyDown(with event: NSEvent) { action("keyboard") { super.keyDown(with: event) } }
}
