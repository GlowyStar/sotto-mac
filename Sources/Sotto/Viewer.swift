import AppKit
import SottoCore
import SwiftUI

/// The photo viewer over the whole window (DESIGN.md 15): the picture fitted, zoom, the
/// neighbours of the chat, the name and date, the caption and the buttons.
struct MediaViewer: View {
    @Bindable var model: AppModel
    let item: ViewerItem
    /// Nil fits the window; otherwise the scale of the picture's pixels, 1 is 100%.
    @State private var scale: CGFloat?
    @State private var pinch: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var controls = true
    @State private var hide: Task<Void, Never>?
    /// The photo the store keeps, decoded at the size of the viewer, with its message.
    @State private var large: (id: String, image: NSImage)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let date: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    var body: some View {
        let list = model.photos(in: item.chatID)
        let index = list.firstIndex { $0.id == item.messageID }
        GeometryReader { window in
            ZStack {
                Color.viewerBg
                    .contentShape(Rectangle())
                    .onTapGesture { close() }
                if let index, let file = list[index].file {
                    picture(list[index], file, in: window.size)
                    arrows(hasPrevious: index > 0, hasNext: index + 1 < list.count)
                    bottom(list[index], width: window.size.width)
                }
                buttons(index.map { list[$0] })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, Metrics.titleStrip + 8)
                    .padding(.trailing, 8)
                    .opacity(controls ? 1 : 0)
                if let toast = model.toast {
                    savedToast(toast).frame(maxHeight: .infinity, alignment: .top).padding(.top, 24)
                }
            }
        }
        .onContinuousHover { _ in showControls() }
        .onAppear { showControls() }
        .onChange(of: item) { _, _ in
            scale = nil
            pan = .zero
            panStart = .zero
        }
        .background { shortcuts(index.map { list[$0] }) }
        .onChange(of: index == nil) { _, gone in if gone { close() } }
    }

    private func close() {
        withAnimation(Motion.pick(Motion.viewer, reduce: reduceMotion)) { model.viewer = nil }
    }

    private func showControls() {
        if !controls { withAnimation(Motion.controlsIn) { controls = true } }
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: Metrics.viewerControlsHold)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.controlsOut) { controls = false }
        }
    }

    // MARK: Picture

    @ViewBuilder
    private func picture(_ message: Message, _ file: ChatFile, in window: CGSize) -> some View {
        let image = Media.localURL(file).flatMap { Media.picture($0, side: Metrics.viewerSide) }
            ?? large.flatMap { $0.id == message.id ? $0.image : nil }
            ?? (file.kept ? Media.cachedPicture(Media.keptKey(message.id), side: Metrics.mediaMax) : nil)
        let pixels = image?.size ?? Media.pixelSize(file) ?? CGSize(width: 400, height: 400)
        let fit = min(1, window.width / pixels.width, window.height / pixels.height)
        let shown = min(max((scale ?? fit) * pinch, fit * 0.5), 8)
        let size = CGSize(width: pixels.width * shown, height: pixels.height * shown)
        ZStack {
            if let image {
                if image.hasAlpha { Checkerboard() }
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Group {
                    if let thumbnail = Media.thumbnail(file.thumbnail) {
                        Image(nsImage: thumbnail).resizable().blur(radius: min(size.width, size.height) / 10, opaque: true)
                    } else {
                        Color.imageBg.opacity(0.15)
                    }
                }
                .overlay {
                    if let look = CircleLook.of(file, connected: model.connection == .connected) {
                        Button { model.tap(message, in: item.chatID) } label: {
                            MediaCircle(look: look, fill: .mediaOverlayBg, fillOver: .mediaOverlayBgOver, glyph: .mediaOverlayGlyph)
                        }
                        .buttonStyle(.plain)
                        .help(look.help)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .offset(size.width > window.width || size.height > window.height ? pan : .zero)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            withAnimation(Motion.pick(Motion.viewer, reduce: reduceMotion)) {
                scale = scale == nil && fit < 1 ? 1 : nil
                pan = .zero
                panStart = .zero
            }
        }
        .onTapGesture {}
        .gesture(
            MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    scale = min(max((scale ?? fit) * value.magnification, fit), 8)
                    pinch = 1
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { pan = CGSize(width: panStart.width + $0.translation.width, height: panStart.height + $0.translation.height) }
                .onEnded { _ in panStart = pan }
        )
        .contextMenu { menuItems(message) }
        .accessibilityLabel(message.outgoing ? "Your photo" : "Photo")
        .task(id: message.id + (file.kept ? "#kept" : "")) {
            guard file.kept, large?.id != message.id else { return }
            if let image = await model.keptPicture(message, side: Metrics.viewerSide) { large = (message.id, image) }
        }
    }

    // MARK: Controls

    private func arrows(hasPrevious: Bool, hasNext: Bool) -> some View {
        HStack(spacing: 0) {
            ArrowZone(symbol: "chevron.left", shown: hasPrevious && controls) { model.stepViewer(-1) }
            Spacer()
            ArrowZone(symbol: "chevron.right", shown: hasNext && controls) { model.stepViewer(1) }
        }
    }

    private func bottom(_ message: Message, width: CGFloat) -> some View {
        let name = message.outgoing ? "You" : model.contact(item.chatID)?.name ?? ""
        let date = Self.date.string(from: message.date) + ", " + Formats.clock(message.date, h24: model.clock24)
        return VStack(spacing: 0) {
            Spacer()
            if !message.text.isEmpty {
                ScrollView {
                    Text(MessageRow.attributed(message.text, out: false))
                        .font(Fonts.rowText)
                        .foregroundStyle(Color.viewerCaptionFg)
                        .tint(Color.viewerLinkFg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 4 * 18)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 11))
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.viewerCaptionBg))
                .frame(maxWidth: min(Metrics.viewerCaptionWidth, width - 2 * Metrics.viewerArrowZone))
                .padding(.bottom, 11)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(Fonts.rowName)
                    Text(date).font(Fonts.rowText)
                }
                .foregroundStyle(Color.viewerControlFg)
                .shadow(color: .shadow, radius: 1)
                .opacity(controls ? 1 : 0)
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.bottom, 13)
        }
    }

    private func buttons(_ message: Message?) -> some View {
        HStack(spacing: 0) {
            if let message, let file = message.file, model.hasContents(file) {
                viewerButton("square.and.arrow.down", "Save as...") { model.saveAs(message) }
            }
            if let message {
                Menu {
                    menuItems(message)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.viewerControlFg)
                        .frame(width: Metrics.viewerButton, height: Metrics.viewerButton)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More")
            }
            viewerButton("xmark", "Close") { close() }
        }
        .shadow(color: .shadow, radius: 1)
    }

    private func viewerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.viewerControlFg)
                .frame(width: Metrics.viewerButton, height: Metrics.viewerButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder
    private func menuItems(_ message: Message) -> some View {
        let url = message.file.flatMap(Media.localURL)
        if let file = message.file, model.hasContents(file) {
            Button("Save as...") { model.saveAs(message) }
            Button("Copy image") { model.copyImage(message) }
        }
        Button("Show in chat") {
            model.viewer = nil
            model.focus(message.id, in: item.chatID)
        }
        if let url {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Button("Delete for me", role: .destructive) {
            let list = model.photos(in: item.chatID)
            if let index = list.firstIndex(where: { $0.id == message.id }) {
                let next = list.indices.contains(index + 1) ? index + 1 : index - 1
                model.viewer = list.indices.contains(next) ? ViewerItem(chatID: item.chatID, messageID: list[next].id) : nil
            }
            model.deleteMessage(message.id, in: item.chatID)
        }
    }

    private func savedToast(_ text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 18)).foregroundStyle(Color.toastFg)
            Text(text).font(Fonts.rowText).foregroundStyle(Color.toastFg)
        }
        .padding(EdgeInsets(top: 19, leading: 23, bottom: 20, trailing: 29))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.toastBg))
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// Left and Right, Cmd+S, Cmd+C and the zoom keys while the viewer is open.
    private func shortcuts(_ message: Message?) -> some View {
        Group {
            Button("") { model.stepViewer(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.stepViewer(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { if let message { model.saveAs(message) } }.keyboardShortcut("s")
            Button("") {
                if let message, let file = message.file, model.hasContents(file) { model.copyImage(message) }
            }.keyboardShortcut("c")
            Button("") { scale = (scale ?? 0.5) * 1.25 }.keyboardShortcut("=")
            Button("") { scale = max((scale ?? 1) / 1.25, 0.05) }.keyboardShortcut("-")
            Button("") {
                scale = nil
                pan = .zero
                panStart = .zero
            }.keyboardShortcut("0")
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// A zone of 90 at the side of the viewer with an arrow that gets a circle on hover.
struct ArrowZone: View {
    let symbol: String
    let shown: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(Color.viewerControlFg)
                .frame(width: 46, height: 54)
                .background(Circle().fill(hover ? Color.viewerControlBg : .clear).frame(width: 36, height: 36))
                .frame(width: Metrics.viewerArrowZone)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .disabled(!shown)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous photo" : "Next photo")
    }
}

/// Squares of 8 behind a picture with transparency, as one tile repeated.
struct Checkerboard: View {
    private static let tile: NSImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        NSColor(hex: "cccccc").setFill()
        NSRect(x: 8, y: 0, width: 8, height: 8).fill()
        NSRect(x: 0, y: 8, width: 8, height: 8).fill()
        return true
    }

    var body: some View {
        Rectangle().fill(ImagePaint(image: Image(nsImage: Self.tile)))
    }
}

extension NSImage {
    var hasAlpha: Bool {
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        return ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }
}
