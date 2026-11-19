import AppKit
import SwiftUI

/// The bar under the messages: a growing field and the send button (DESIGN.md 5.8), with the
/// strip of a reply or an edit above them (DESIGN.md 20.2 and 20.4).
struct ComposeBar: View {
    @Bindable var model: AppModel
    let chatID: String
    @State private var height = Metrics.fieldMin
    @State private var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var text: Binding<String> {
        Binding(get: { model.drafts[chatID] ?? "" }, set: { model.drafts[chatID] = $0 })
    }

    private var canSend: Bool { !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var editing: Bool { model.edits[chatID] != nil }
    private var stripShown: Bool { editing || model.replies[chatID] != nil }

    var body: some View {
        VStack(spacing: 0) {
            ComposeStrip(model: model, chatID: chatID)
            field
        }
        .background(Color.composeBg)
        .overlay(alignment: .top) { Rectangle().fill(Color.divider).frame(height: 1) }
        .animation(Motion.pick(Motion.compose, reduce: reduceMotion), value: canSend)
        .animation(Motion.pick(Motion.compose, reduce: reduceMotion), value: height)
        .animation(Motion.pick(Motion.compose, reduce: reduceMotion), value: stripShown)
    }

    private var field: some View {
        let size = model.settings.textSize
        return HStack(alignment: .bottom, spacing: 0) {
            AttachButton(model: model)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Write a message...")
                        .font(Fonts.message(size))
                        .foregroundStyle(focused ? Color.placeholderFgActive : Color.placeholderFg)
                        .padding(.top, GrowingTextView.inset + 1)
                        .allowsHitTesting(false)
                }
                GrowingTextView(
                    text: text, height: $height, focused: $focused, focusTick: model.composeFocusTick,
                    textSize: size, commandEnterSends: model.settings.sendWithCommandEnter,
                    onSend: { model.send(text.wrappedValue, to: chatID) },
                    onEscape: { model.escape() },
                    onUpArrow: { model.editLast(in: chatID) },
                    onPasteFiles: { model.stage($0) },
                    onPasteImage: { model.stagePasted($0) }
                )
                .frame(height: height)
                .accessibilityLabel("Message")
            }
            .padding(.leading, 2)
            .padding(.vertical, Metrics.fieldPadV)
            IconButton(symbol: "face.smiling", size: 22, label: "Emoji", side: Metrics.emojiWidth) {
                // The system palette types into the first responder, so the field takes focus first.
                model.composeFocusTick += 1
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            }
            .frame(height: Metrics.composeHeight)
            if canSend || editing {
                Button {
                    model.send(text.wrappedValue, to: chatID)
                } label: {
                    Image(systemName: editing ? "checkmark" : "paperplane.fill")
                        .font(.system(size: 22, weight: editing ? .semibold : .regular))
                        .foregroundStyle(Color.accent)
                        .frame(width: Metrics.sendWidth, height: Metrics.composeHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, Metrics.sendRight)
                .accessibilityLabel(editing ? "Save the edit" : "Send")
                .transition(.opacity)
            } else {
                Color.clear.frame(width: Metrics.sendWidth + Metrics.sendRight, height: Metrics.composeHeight)
            }
        }
    }
}

/// The paperclip at the leading edge of the compose bar: opens the attach menu (DESIGN.md 14.1).
struct AttachButton: View {
    let model: AppModel
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(model.attachMenuOpen ? Motion.pick(.easeIn(duration: 0.15), reduce: reduceMotion) : Motion.pick(Motion.menuIn, reduce: reduceMotion)) {
                model.attachMenuOpen.toggle()
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 22))
                .foregroundStyle(hover ? Color.composeIconFgOver : Color.composeIconFg)
                .frame(width: 40, height: 40)
                .background(Circle().fill(hover ? Color.windowBgOver : .clear))
                .frame(width: Metrics.attachWidth, height: Metrics.composeHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .accessibilityLabel("Attach a photo or a file")
        .help("Attach")
    }
}

/// An `NSTextView` that grows with its text. It sends on Enter and breaks the line on
/// Shift+Enter, or sends on Cmd+Enter and breaks the line on Enter (DESIGN.md 11.4).
struct GrowingTextView: NSViewRepresentable {
    /// The space above and below the text; one line at size 13 makes the 36 field.
    static let inset: CGFloat = (Metrics.fieldMin - 18) / 2

    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    let focusTick: Int
    var textSize = 13
    var commandEnterSends = false
    let onSend: () -> Void
    let onEscape: () -> Void
    /// The Up arrow in an empty field; true when it was taken (DESIGN.md 20.4).
    var onUpArrow: () -> Bool = { false }
    var onPasteFiles: ([URL]) -> Void = { _ in }
    /// A picture pasted without text, as PNG bytes.
    var onPasteImage: (Data) -> Void = { _ in }

    final class Field: NSTextView {
        var focusChanged: ((Bool) -> Void)?
        var commandReturn: (() -> Void)?
        var upArrow: (() -> Bool)?
        var pasteFiles: (([URL]) -> Void)?
        var pasteImage: ((Data) -> Void)?
        var appliedSize = 0

        /// A copy of the draft is a copy of the chats (docs/key-storage.md).
        override func copy(_ sender: Any?) {
            let before = NSPasteboard.general.changeCount
            super.copy(sender)
            if NSPasteboard.general.changeCount != before { ChatPasteboard.mark() }
        }

        override func cut(_ sender: Any?) {
            let before = NSPasteboard.general.changeCount
            super.cut(sender)
            if NSPasteboard.general.changeCount != before { ChatPasteboard.mark() }
        }

        /// Files on the pasteboard and a picture without text go to the send box (DESIGN.md 14.1).
        override func paste(_ sender: Any?) {
            let board = NSPasteboard.general
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            if let urls = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
                pasteFiles?(urls)
            } else if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board),
                let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            {
                pasteImage?(png)
            } else {
                super.paste(sender)
            }
        }
        override func keyDown(with event: NSEvent) {
            let isPlainUp = event.keyCode == 126 && event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty
            if [36, 76].contains(event.keyCode), event.modifierFlags.contains(.command) {
                commandReturn?()
            } else if isPlainUp, string.isEmpty, upArrow?() == true {
                return
            } else {
                super.keyDown(with: event)
            }
        }
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { focusChanged?(true) }
            return result
        }
        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { focusChanged?(false) }
            return result
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        var lastTick: Int
        init(_ parent: GrowingTextView) {
            self.parent = parent
            lastTick = parent.focusTick
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            measure(view)
        }

        func measure(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container).height + view.textContainerInset.height * 2
            let minimum = CGFloat(parent.textSize + 5) + GrowingTextView.inset * 2
            let next = min(max(used, minimum), Metrics.fieldMax)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = next }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if parent.commandEnterSends || NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSend()
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let field = Field()
        field.delegate = context.coordinator
        field.drawsBackground = false
        field.isRichText = false
        field.allowsUndo = true
        field.textColor = NSColor(Color.windowFg)
        field.insertionPointColor = NSColor(Color.accent)
        field.textContainerInset = NSSize(width: 0, height: Self.inset)
        field.textContainer?.lineFragmentPadding = 0
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.commandReturn = { [weak coordinator = context.coordinator] in coordinator?.parent.onSend() }
        field.upArrow = { [weak coordinator = context.coordinator] in coordinator?.parent.onUpArrow() ?? false }
        field.pasteFiles = { [weak coordinator = context.coordinator] in coordinator?.parent.onPasteFiles($0) }
        field.pasteImage = { [weak coordinator = context.coordinator] in coordinator?.parent.onPasteImage($0) }
        field.string = text
        applySize(field)
        field.focusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        scroll.documentView = field
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let field = scroll.documentView as? Field else { return }
        if field.appliedSize != textSize {
            applySize(field)
            context.coordinator.measure(field)
        }
        if field.string != text {
            field.string = text
            context.coordinator.measure(field)
        }
        if context.coordinator.lastTick != focusTick {
            context.coordinator.lastTick = focusTick
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    /// The font and the line of `textSize` (line height size + 5), also for the text already typed.
    private func applySize(_ field: Field) {
        field.appliedSize = textSize
        let font = Fonts.compose(textSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = CGFloat(textSize + 5)
        paragraph.maximumLineHeight = CGFloat(textSize + 5)
        field.font = font
        field.defaultParagraphStyle = paragraph
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor(Color.windowFg),
        ]
        field.typingAttributes = attributes
        field.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: field.textStorage?.length ?? 0))
    }
}
