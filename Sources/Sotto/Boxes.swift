import SottoCore
import SwiftUI

/// The frame of every dialog: title, body and a right-aligned button row (DESIGN.md 5.10).
struct ModalBox<Content: View, Buttons: View>: View {
    let title: String
    var wide = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Fonts.boxTitle)
                .foregroundStyle(Color.boxTitleFg)
                .padding(.leading, Metrics.boxPad)
                .frame(maxWidth: .infinity, minHeight: Metrics.boxTitleHeight, alignment: .leading)
            content()
                .padding(.horizontal, Metrics.boxPad)
                .padding(.top, 2)
                .padding(.bottom, 8)
            HStack(spacing: 8) {
                Spacer()
                buttons()
            }
            .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 10))
        }
        .frame(width: wide ? Metrics.boxWideWidth : Metrics.boxWidth)
        .background(
            RoundedRectangle(cornerRadius: Metrics.boxRadius).fill(Color.boxBg).shadow(color: .shadow, radius: 12, y: 4)
        )
    }
}

/// A field of a box: label above, underline, error below.
struct BoxField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var error: String?
    var monospaced = false
    var focusOnAppear = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !label.isEmpty {
                Text(label).font(Fonts.label).foregroundStyle(Color.windowSubFg)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Color.placeholderFg))
                .textFieldStyle(.plain)
                .font(monospaced ? Fonts.idField : Fonts.boxBody)
                .foregroundStyle(Color.windowFg)
                .focused($focused)
                .frame(height: Metrics.fieldHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(error != nil ? Color.fieldError : focused ? Color.activeLine : Color.divider)
                        .frame(height: focused || error != nil ? 2 : 1)
                }
                .accessibilityLabel(label.isEmpty ? placeholder : label)
            if let error {
                Text(error).font(Fonts.label).foregroundStyle(Color.fieldError)
            }
        }
        .onAppear { if focusOnAppear { focused = true } }
    }
}

struct AddContactBox: View {
    let model: AppModel
    @State private var name = ""
    @State private var id = ""
    @State private var nameError: String?
    @State private var idError: String?
    @State private var tried = false

    init(model: AppModel, name: String = "", id: String = "", showErrors: Bool = false) {
        self.model = model
        _name = State(initialValue: name)
        _id = State(initialValue: id)
        _tried = State(initialValue: showErrors)
    }

    var body: some View {
        ModalBox(title: "Add contact", wide: true) {
            VStack(alignment: .leading, spacing: 16) {
                BoxField(label: "Name", placeholder: "Local name", text: $name, error: nameError, focusOnAppear: true)
                BoxField(label: "Id", placeholder: "64 hex characters", text: $id, error: idError, monospaced: true)
            }
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: "Add", action: add).keyboardShortcut(.defaultAction)
        }
        .onChange(of: name) { _, value in
            if value.count > 64 { name = String(value.prefix(64)) }
            if tried { validate() }
        }
        .onChange(of: id) { _, value in
            let clean = AppModel.normalizedID(value)
            if clean != value { id = clean }
            if tried { validate() }
        }
        .onAppear { if tried { validate() } }
    }

    private func validate() {
        let saved = Dictionary(model.contacts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        nameError = Messenger.nameProblem(name.trimmingCharacters(in: .whitespacesAndNewlines), saved: saved)?.message
        idError = AppModel.idError(AppModel.normalizedID(id), own: model.myID, existing: model.contacts)
    }

    private func add() {
        tried = true
        let result = model.addContact(name: name, id: id)
        nameError = result.name
        idError = result.id
    }
}

struct MyIDBox: View {
    let model: AppModel

    var body: some View {
        ModalBox(title: "My id", wide: true) {
            VStack(spacing: 0) {
                Avatar(id: model.myID, name: "Me", size: Metrics.bigAvatar)
                IDBlock(id: model.myID).padding(.top, 16)
                CopyIDButton { model.copyID(model.myID) }.padding(.top, 12)
            }
            .frame(maxWidth: .infinity)
        } buttons: {
            BoxButton(title: "Close") { model.modal = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

struct CopyIDButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.doc").font(.system(size: 14))
                Text("Copy id").font(Fonts.button)
            }
            .foregroundStyle(Color.accentText)
            .padding(.horizontal, Metrics.buttonPadH)
            .frame(height: Metrics.buttonHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.buttonRadius).fill(hover ? Color.lightButtonBgOver : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
    }
}

struct SettingsBox: View {
    @Bindable var model: AppModel
    @State private var relay: String
    @State private var relayError: String?

    init(model: AppModel) {
        self.model = model
        _relay = State(initialValue: model.relayAddress)
    }

    var body: some View {
        ModalBox(title: "Settings", wide: true) {
            VStack(alignment: .leading, spacing: 0) {
                section("Relay")
                BoxField(label: "", placeholder: "wss://relay.example", text: $relay, error: relayError)
                Text(model.connection.label)
                    .font(Fonts.label)
                    .foregroundStyle(model.connection == .connected ? Color.windowSubFg : Color.accentText)
                    .padding(.top, 6)
                separator
                section("Theme")
                ForEach(ThemeChoice.allCases) { choice in
                    HoverRow(height: 40, action: { model.theme = choice }) {
                        HStack(spacing: 12) {
                            RadioCircle(selected: model.theme == choice)
                            Text(choice.title).font(Fonts.boxBody).foregroundStyle(Color.windowFg)
                        }
                    }
                    .accessibilityAddTraits(model.theme == choice ? .isSelected : [])
                }
                separator
                section("Identity")
                HoverRow(height: 40, action: { model.modal = .myID }) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.text.rectangle").font(.system(size: 16)).foregroundStyle(Color.menuIconFg)
                        Text("My id").font(Fonts.boxBody).foregroundStyle(Color.windowFg)
                    }
                }
            }
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: "Save", enabled: relay != model.relayAddress) {
                relayError = model.setRelay(relay)
                if relayError == nil { model.modal = nil }
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Fonts.sectionLabel).foregroundStyle(Color.accentText).padding(.bottom, 4)
    }

    private var separator: some View {
        Rectangle().fill(Color.divider).frame(height: 1).padding(.vertical, 12)
    }
}

struct RadioCircle: View {
    let selected: Bool

    var body: some View {
        ZStack {
            if selected {
                Circle().fill(Color.accent)
                Circle().fill(.white).frame(width: 8, height: 8)
            } else {
                Circle().strokeBorder(Color.windowSubFg, lineWidth: 2)
            }
        }
        .frame(width: 18, height: 18)
    }
}

struct RenameBox: View {
    let model: AppModel
    let contact: Contact
    @State private var name: String
    @State private var error: String?

    init(model: AppModel, contact: Contact) {
        self.model = model
        self.contact = contact
        _name = State(initialValue: contact.name)
    }

    var body: some View {
        ModalBox(title: "Rename") {
            BoxField(label: "Name", placeholder: "Local name", text: $name, error: error, focusOnAppear: true)
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: "Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                error = model.rename(contact.id, to: String(trimmed.prefix(64)))
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// A question with a cancel and a confirming button.
struct ConfirmBox: View {
    let model: AppModel
    let title: String
    let text: String
    let confirm: String
    var danger = false
    let action: () -> Void

    var body: some View {
        ModalBox(title: title) {
            Text(text)
                .font(Fonts.boxBody)
                .foregroundStyle(Color.windowFg)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: confirm, danger: danger, action: action).keyboardShortcut(.defaultAction)
        }
    }
}

/// The contact's details and actions: a right column, or a box when the window is narrow.
struct ContactPanel: View {
    let model: AppModel
    let contact: Contact
    let asBox: Bool

    var body: some View {
        if asBox {
            ModalBox(title: "Contact info", wide: true) {
                // Scrolls only when the window is too low for the whole panel.
                ViewThatFits(in: .vertical) {
                    details
                    ScrollView { details }
                }
                .padding(.horizontal, -Metrics.boxPad)
            } buttons: {
                BoxButton(title: "Close") { model.modal = nil }.keyboardShortcut(.defaultAction)
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Contact info").font(Fonts.headerTitle).foregroundStyle(Color.windowBoldFg)
                    Spacer()
                    IconButton(symbol: "xmark", size: 14, label: "Close contact info") { model.panelOpen = false }
                }
                .padding(.leading, Metrics.boxPad)
                .padding(.trailing, 8)
                .frame(height: Metrics.topBarHeight)
                ScrollView { details.padding(.top, 24) }
            }
            .background(Color.windowBg)
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            Avatar(id: contact.id, name: contact.name, size: Metrics.bigAvatar)
            Text(contact.name)
                .font(Fonts.boxTitle)
                .foregroundStyle(Color.windowBoldFg)
                .padding(.top, 12)
            EncryptedLine().padding(.top, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text("Id").font(Fonts.sectionLabel).foregroundStyle(Color.accentText)
                IDBlock(id: contact.id)
                CopyIDButton { model.copyID(contact.id) }.padding(.leading, -Metrics.buttonPadH)
            }
            .padding(.horizontal, Metrics.boxPad)
            .padding(.top, 24)
            VStack(spacing: 0) {
                action("pencil", "Rename") { model.modal = .rename(contact.id) }
                action("arrow.triangle.2.circlepath", "Reset session") { model.modal = .reset(contact.id) }
                action("trash", "Delete contact", danger: true) { model.modal = .delete(contact.id) }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func action(_ symbol: String, _ title: String, danger: Bool = false, run: @escaping () -> Void) -> some View {
        HoverRow(action: run) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(danger ? Color.danger : Color.menuIconFg)
                    .frame(width: 36, alignment: .leading)
                Text(title).font(Fonts.boxBody).foregroundStyle(danger ? Color.danger : Color.windowFg)
            }
            .padding(.leading, Metrics.boxPad)
        }
    }
}

/// The whole window on a device without an identity (DESIGN.md 7.1).
struct WelcomeScreen: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.welcome == .created {
                Text("Your id").font(Fonts.welcomeTitle).foregroundStyle(Color.windowBoldFg)
                IDBlock(id: model.myID).padding(.top, 16)
                Text("Share this id with people who should be able to write to you.")
                    .font(Fonts.boxBody)
                    .foregroundStyle(Color.windowSubFg)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                HStack(spacing: 8) {
                    CopyIDButton { model.copyID(model.myID) }
                    FilledButton(action: { model.welcome = nil }) { Text("Continue") }
                }
                .padding(.top, 28)
            } else {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 96, height: 96)
                    .overlay(Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(.white))
                    .accessibilityHidden(true)
                Text("Welcome to Sotto")
                    .font(Fonts.welcomeTitle)
                    .foregroundStyle(Color.windowBoldFg)
                    .padding(.top, 24)
                Text("Your identity is a key pair made on this Mac. There is no phone number, no account and no profile.")
                    .font(Fonts.boxBody)
                    .lineSpacing(3)
                    .foregroundStyle(Color.windowSubFg)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                FilledButton(action: { model.createIdentity() }) {
                    if model.welcome == .creating {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("Create identity")
                    }
                }
                .disabled(model.welcome == .creating)
                .padding(.top, 28)
            }
        }
        .frame(width: 300)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBg, ignoresSafeAreaEdges: [])
    }
}
