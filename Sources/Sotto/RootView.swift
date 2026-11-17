import AppKit
import SwiftUI

/// The window: the title strip, then the list and the chat (two columns from 640 wide), with
/// the modal boxes and the toast drawn over everything (DESIGN.md 2).
struct RootView: View {
    @Bindable var model: AppModel
    @AppStorage("listWidth") private var listWidth = Metrics.listDefault
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()
            GeometryReader { geometry in
                if model.locked {
                    LockScreen(model: model)
                } else if model.welcome != nil {
                    WelcomeScreen(model: model)
                } else {
                    columns(width: geometry.size.width)
                }
            }
        }
        .frame(minWidth: Metrics.windowMin.width, minHeight: Metrics.windowMin.height)
        .background(Color.windowBg)
        .overlay { if !model.locked { modalLayer } }
        .overlay(alignment: .bottom) { if !model.locked && model.viewer == nil { toastLayer } }
        .overlay {
            if !model.locked, let item = model.viewer {
                MediaViewer(model: model, item: item)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .overlay {
            if !model.locked, let photo = model.avatarViewer {
                AvatarViewer(model: model, photo: photo)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .environment(\.settings, model.settings)
        .background {
            // Escape anywhere: closes a box, clears the search, leaves the chat.
            Button("") { model.escape() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .animation(Motion.pick(Motion.box, reduce: reduceMotion), value: model.modal)
        .animation(Motion.pick(Motion.box, reduce: reduceMotion), value: model.settingsDialog)
        .animation(Motion.pick(Motion.toastIn, reduce: reduceMotion), value: model.toast)
        .animation(Motion.pick(Motion.viewer, reduce: reduceMotion), value: model.viewer)
        .animation(Motion.pick(Motion.viewer, reduce: reduceMotion), value: model.avatarViewer)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func columns(width: CGFloat) -> some View {
        if width >= Metrics.twoColumnThreshold {
            let list = min(max(listWidth, Metrics.listMin), min(Metrics.listMax, width - Metrics.chatMin - 1))
            HStack(spacing: 0) {
                ChatListColumn(model: model).frame(width: list)
                ColumnDivider(width: list) { listWidth = $0 }
                chatArea(width: width - list - 1, singleColumn: false)
            }
        } else if model.openChat != nil {
            chatArea(width: width, singleColumn: true)
                .transition(.opacity)
        } else {
            ChatListColumn(model: model)
                .transition(.opacity)
        }
    }

    private func chatArea(width: CGFloat, singleColumn: Bool) -> some View {
        ZStack {
            LinearGradient(
                colors: [model.settings.background.top, model.settings.background.bottom], startPoint: .top, endPoint: .bottom)
            if let contact = model.openChat {
                ChatScreen(model: model, contact: contact, singleColumn: singleColumn, width: width)
            } else {
                EmptyChatState(model: model)
            }
        }
        .frame(width: width)
        .clipped()
    }

    @ViewBuilder
    private var modalLayer: some View {
        if let modal = model.modal {
            GeometryReader { geometry in
                ZStack {
                    Color.layerBg
                        .ignoresSafeArea()
                        .onTapGesture {
                            // The settings panel closes on the dim only from its root page.
                            if modal != .settings || model.settingsPage == nil { model.modal = nil }
                        }
                        .accessibilityHidden(true)
                    Group {
                        if modal == .settings {
                            SettingsPanel(model: model, window: geometry.size)
                        } else {
                            box(for: modal)
                        }
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    if modal == .settings, let dialog = model.settingsDialog {
                        Color.layerBg
                            .ignoresSafeArea()
                            .onTapGesture { model.settingsDialog = nil }
                            .accessibilityHidden(true)
                            .transition(.opacity)
                        settingsBox(for: dialog)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95)))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func settingsBox(for dialog: SettingsDialog) -> some View {
        switch dialog {
        case .myID: MyIDBox(model: model) { model.settingsDialog = nil }
        case .qrCode: QRCodeBox(model: model)
        case .crop:
            if let source = model.cropSource { CropBox(model: model, source: source.image) }
        case .discardProfile: DiscardProfileBox(model: model)
        case .passcode: PasscodeBox(model: model)
        case .autoLock: AutoLockBox(model: model)
        case .reset: ResetBox(model: model)
        }
    }

    @ViewBuilder
    private func box(for modal: Modal) -> some View {
        switch modal {
        case .addContact:
            AddContactBox(model: model)
        case .myID:
            MyIDBox(model: model)
        case .settings:
            EmptyView()
        case .contactInfo(let id):
            if let contact = model.contact(id) { ContactPanel(model: model, contact: contact, asBox: true) }
        case .rename(let id):
            if let contact = model.contact(id) { RenameBox(model: model, contact: contact) }
        case .reset(let id):
            if let contact = model.contact(id) {
                ConfirmBox(
                    model: model, title: "Reset session?",
                    text: "A new encrypted session will be started with \(contact.name). Messages already received stay.",
                    confirm: "Reset"
                ) { model.resetSession(id) }
            }
        case .sendFiles:
            SendBox(model: model)
        case .deleteMessage(let chat, let messageID):
            if let message = model.message(messageID, in: chat) { DeleteMessageBox(model: model, chatID: chat, message: message) }
        case .timer(let chat):
            TimerBox(model: model, chatID: chat)
        case .delete(let id):
            if let contact = model.contact(id) {
                ConfirmBox(
                    model: model, title: "Delete \(contact.name)?",
                    text: "The contact and the whole chat history will be deleted from this Mac. This cannot be undone.",
                    confirm: "Delete", danger: true
                ) { model.deleteContact(id) }
            }
        }
    }

    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            Text(toast)
                .font(Fonts.rowText)
                .foregroundStyle(Color.toastFg)
                .padding(Metrics.toastPad)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(reduceTransparency ? Color.toastBgOpaque : Color.toastBg)
                )
                .frame(maxWidth: Metrics.toastMaxWidth)
                .padding(13)
                .padding(.bottom, (model.openChat != nil ? Metrics.composeHeight : 0) + Metrics.toastAbove - 13)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                .allowsHitTesting(false)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The strip across the window top with the app name; the window is dragged by it.
struct TitleStrip: View {
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack {
            WindowDragArea()
            Text("Sotto")
                .font(Fonts.title)
                .foregroundStyle(activeState == .inactive ? Color.titleFgInactive : Color.titleFg)
                .allowsHitTesting(false)
        }
        .frame(height: Metrics.titleStrip)
        .background(Color.titleBg)
    }
}

/// The 1pt line between the columns, draggable to resize the list.
struct ColumnDivider: View {
    let width: CGFloat
    let change: (CGFloat) -> Void
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.divider)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let origin = start ?? width
                                start = origin
                                change(min(max(origin + value.translation.width, Metrics.listMin), Metrics.listMax))
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .zIndex(1)
            .accessibilityHidden(true)
    }
}

/// The chat area with no chat open (DESIGN.md 5.12).
struct EmptyChatState: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            if model.contacts.isEmpty {
                ServicePill(text: "Add a contact to start messaging")
                Button("Add contact") { model.modal = .addContact }
                    .buttonStyle(.plain)
                    .font(Fonts.button)
                    .foregroundStyle(Color.accentText)
            } else {
                ServicePill(text: "Select a chat to start messaging")
            }
        }
    }
}
