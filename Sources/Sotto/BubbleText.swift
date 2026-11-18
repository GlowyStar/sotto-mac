import AppKit
import SwiftUI

/// The text of a bubble or a caption (DESIGN.md 5.4), drawn by an AppKit text view so that a
/// selection takes `msgInSelectBg` / `msgOutSelectBg` and a link is underlined under the pointer.
struct BubbleText: NSViewRepresentable {
    struct Content: Equatable {
        let text: String
        let out: Bool
        /// The transparent copy of the time line kept at the end (`TimeMark.reserve`).
        let reserve: String
        let size: Int
    }

    let content: Content

    func makeNSView(context: Context) -> BubbleTextView { BubbleTextView() }

    func updateNSView(_ view: BubbleTextView, context: Context) { view.show(content) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BubbleTextView, context: Context) -> CGSize? {
        nsView.show(content)
        return nsView.fitting(width: proposal.width ?? .greatestFiniteMagnitude)
    }
}

final class BubbleTextView: NSTextView {
    /// A selection and a hovered link drawn by `--snapshot`, by message text.
    static var staged: [String: (selection: NSRange, hover: Bool)] = [:]

    private var content: BubbleText.Content?
    private var length = 0
    private var hovered: NSRange?
    fileprivate var selectionColor = NSColor.selectedTextBackgroundColor

    init() {
        let storage = NSTextStorage()
        let layout = SelectionLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.heightTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ new: BubbleText.Content) {
        guard new != content, let textStorage else { return }
        content = new
        hovered = nil
        length = (new.text as NSString).length
        textStorage.setAttributedString(Self.attributed(new))
        selectionColor = NSColor(new.out ? Color.msgOutSelectBg : Color.msgInSelectBg)
        selectedTextAttributes = [.backgroundColor: selectionColor]
        if let stage = Self.staged[new.text] {
            setSelectedRange(stage.selection)
            if stage.hover { hover(firstLink()) }
        }
    }

    /// The size of the laid out text at most `width` wide.
    func fitting(width: CGFloat) -> CGSize {
        guard let textStorage else { return .zero }
        let measure = Self.measure
        measure.container.size = CGSize(width: max(width, 0), height: .greatestFiniteMagnitude)
        measure.storage.setAttributedString(textStorage)
        measure.layout.ensureLayout(for: measure.container)
        let used = measure.layout.usedRect(for: measure.container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }

    private static let measure: (storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer) = {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return (storage, layout, container)
    }()

    static func attributed(_ content: BubbleText.Content) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: CGFloat(content.size))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Fonts.messageLineSpacing(content.size)
        let result = NSMutableAttributedString(
            string: content.text,
            attributes: [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: NSColor(content.out ? Color.msgOutFg : Color.msgInFg),
            ])
        let link = NSColor(content.out ? Color.msgOutLinkFg : Color.msgInLinkFg)
        for (range, url) in MessageRow.links(in: content.text) {
            result.addAttributes([.link: url, .foregroundColor: link], range: range)
        }
        result.append(
            NSAttributedString(
                string: content.reserve,
                attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.clear]))
        return result
    }

    /// A selection never reaches into the reserved time line, so it is neither painted nor copied.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        let clamped = ranges.map { value in
            let range = value.rangeValue
            let start = min(range.location, length)
            return NSValue(range: NSRange(location: start, length: min(NSMaxRange(range), length) - start))
        }
        super.setSelectedRanges(clamped, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// Cmd+C copies the selected text as plain text.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
    }

    override func resignFirstResponder() -> Bool {
        setSelectedRange(NSRange(location: 0, length: 0))
        return super.resignFirstResponder()
    }

    /// The menu of the bubble (DESIGN.md 5.9), not the text view's own.
    override func menu(for event: NSEvent) -> NSMenu? {
        var view = superview
        while let next = view {
            if let menu = next.menu(for: event) { return menu }
            view = next.superview
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hover(link(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func link(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let textStorage, length > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard box.contains(point), index < length else { return nil }
        var range = NSRange()
        return textStorage.attribute(.link, at: index, effectiveRange: &range) == nil ? nil : range
    }

    private func firstLink() -> NSRange? {
        var found: NSRange?
        textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: length)) { value, range, stop in
            if value != nil {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    private func hover(_ range: NSRange?) {
        guard range != hovered, let textStorage else { return }
        if let hovered { textStorage.removeAttribute(.underlineStyle, range: hovered) }
        if let range { textStorage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        hovered = range
    }
}

/// Paints the selection in the colour of the bubble also while the window or the view is not
/// active, where AppKit would use its grey.
private final class SelectionLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor
    ) {
        let view = firstTextView
        let color = MainActor.assumeIsolated { (view as? BubbleTextView)?.selectionColor } ?? color
        color.setFill()
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
    }
}
