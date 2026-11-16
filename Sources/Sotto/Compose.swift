import AppKit
import SwiftUI

/// The bar under the messages: a growing field and the send button (DESIGN.md 5.8).
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text("Write a message...")
                        .font(Fonts.rowText)
                        .foregroundStyle(focused ? Color.placeholderFgActive : Color.placeholderFg)
                        .padding(.top, (Metrics.fieldMin - 16) / 2)
                        .allowsHitTesting(false)
                }
                GrowingTextView(
                    text: text, height: $height, focused: $focused, focusTick: model.composeFocusTick,
                    onSend: { model.send(text.wrappedValue, to: chatID) },
                    onEscape: { model.escape() }
                )
                .frame(height: height)
                .accessibilityLabel("Message")
            }
            .padding(.leading, Metrics.fieldLeft)
            .padding(.vertical, Metrics.fieldPadV)
            if canSend {
                Button {
                    model.send(text.wrappedValue, to: chatID)
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accent)
                        .frame(width: Metrics.sendWidth, height: Metrics.composeHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, Metrics.sendRight)
                .accessibilityLabel("Send")
                .transition(.opacity)
            } else {
                Color.clear.frame(width: Metrics.sendWidth + Metrics.sendRight, height: Metrics.composeHeight)
            }
        }
        .background(Color.composeBg)
        .overlay(alignment: .top) { Rectangle().fill(Color.divider).frame(height: 1) }
        .animation(Motion.pick(Motion.compose, reduce: reduceMotion), value: canSend)
        .animation(Motion.pick(Motion.compose, reduce: reduceMotion), value: height)
    }
}

/// An `NSTextView` that grows with its text, sends on Enter and breaks the line on Shift+Enter.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    let focusTick: Int
    let onSend: () -> Void
    let onEscape: () -> Void

    final class Field: NSTextView {
        var focusChanged: ((Bool) -> Void)?
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
            let next = min(max(used, Metrics.fieldMin), Metrics.fieldMax)
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = next }
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.shift) {
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
        field.font = Fonts.compose
        field.textColor = NSColor(Color.windowFg)
        field.insertionPointColor = NSColor(Color.accent)
        field.textContainerInset = NSSize(width: 0, height: (Metrics.fieldMin - 18) / 2)
        field.textContainer?.lineFragmentPadding = 0
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        field.defaultParagraphStyle = paragraph
        field.typingAttributes = [.font: Fonts.compose, .paragraphStyle: paragraph, .foregroundColor: NSColor(Color.windowFg)]
        field.string = text
        field.focusChanged = { [weak coordinator = context.coordinator] value in
            DispatchQueue.main.async { coordinator?.parent.focused = value }
        }
        scroll.documentView = field
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let field = scroll.documentView as? NSTextView else { return }
        if field.string != text {
            field.string = text
            context.coordinator.measure(field)
        }
        if context.coordinator.lastTick != focusTick {
            context.coordinator.lastTick = focusTick
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }
}
