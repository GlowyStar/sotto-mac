import SwiftUI

/// The left column: the bar with the menu and the search, the connection bar and the rows.
struct ChatListColumn: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = model.visibleContacts
        VStack(spacing: 0) {
            ListTopBar(model: model)
            if model.connection != .connected && model.connection != .idle {
                ConnectionBar(model: model)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if rows.isEmpty && !model.search.isEmpty {
                Text("No contacts found")
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.windowSubFg)
                    .padding(.top, 20)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, contact in
                            ChatRow(
                                model: model, contact: contact,
                                keyboardSelected: model.searchFocused && !model.search.isEmpty
                                    && index == model.searchSelection)
                        }
                    }
                    .animation(Motion.pick(Motion.reorder, reduce: reduceMotion), value: rows.map(\.id))
                }
                .scrollIndicators(.automatic)
            }
        }
        .background(Color.listBg)
        .clipped()
        .animation(Motion.pick(Motion.connection, reduce: reduceMotion), value: model.connection)
    }
}

/// "Connecting..." under the search while the relay is unreachable (DESIGN.md 5.2); when the
/// client stopped for good, the reason and a button that connects again.
struct ConnectionBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if case .stopped(let reason) = model.connection {
                Text(reason)
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.accentText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Retry") { model.reconnect() }
                    .buttonStyle(.plain)
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.accentText)
            } else {
                ProgressView().controlSize(.small)
                Text("Connecting...").font(Fonts.rowText).foregroundStyle(Color.accentText)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: Metrics.connectionBar)
        .background(Color.windowBgOver)
    }
}

struct ListTopBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button {
                    model.modal = .addContact
                } label: {
                    Label("Add contact", systemImage: "person.badge.plus")
                }
                Button {
                    model.modal = .myID
                } label: {
                    Label("My id", systemImage: "person.text.rectangle")
                }
                Button {
                    model.modal = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.composeIconFg)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Metrics.menuButton, height: Metrics.menuButton)
            .padding(.leading, Metrics.menuButtonLeft)
            .accessibilityLabel("Menu")
            .help("Menu")

            searchField
                .padding(Metrics.searchOuter)
        }
        .frame(height: Metrics.topBarHeight)
        .background(Color.topBarBg)
        .onChange(of: focused) { _, value in model.searchFocused = value }
        .onChange(of: model.searchFocused) { _, value in focused = value }
        .onChange(of: model.searchFocusTick) { _, _ in focused = true }
        .onChange(of: model.search) { _, _ in model.searchSelection = 0 }
    }

    private var searchField: some View {
        ZStack(alignment: .leading) {
            if model.search.isEmpty {
                Text("Search")
                    .font(Fonts.rowText)
                    .foregroundStyle(focused ? Color.placeholderFgActive : Color.placeholderFg)
                    .padding(.leading, Metrics.searchTextLeft)
                    .allowsHitTesting(false)
            }
            TextField("", text: $model.search)
                .textFieldStyle(.plain)
                .font(Fonts.rowText)
                .foregroundStyle(Color.windowFg)
                .focused($focused)
                .padding(.leading, Metrics.searchTextLeft)
                .padding(.trailing, Metrics.searchTextRight)
                .accessibilityLabel("Search")
                .onKeyPress(.downArrow) {
                    model.searchSelection = min(model.searchSelection + 1, max(model.visibleContacts.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.searchSelection = max(model.searchSelection - 1, 0)
                    return .handled
                }
                .onSubmit {
                    let rows = model.visibleContacts
                    guard rows.indices.contains(model.searchSelection) else { return }
                    model.openChat(rows[model.searchSelection].id)
                }
            if !model.search.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.placeholderFg)
                            .frame(width: Metrics.searchTextRight, height: Metrics.searchHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
        }
        .frame(height: Metrics.searchHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.searchRadius)
                .fill(focused ? Color.searchBgActive : Color.searchBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.searchRadius)
                .strokeBorder(focused ? Color.searchBorderActive : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// One chat in the list (DESIGN.md 5.1).
struct ChatRow: View {
    let model: AppModel
    let contact: Contact
    var keyboardSelected = false
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        let active = model.openChatID == contact.id
        let last = model.messages[contact.id]?.last
        HStack(alignment: .top, spacing: Metrics.rowTextX - Metrics.rowPadding - Metrics.rowAvatar) {
            Avatar(id: contact.id, name: contact.name, size: Metrics.rowAvatar)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Metrics.rowGap) {
                    Text(contact.name)
                        .font(Fonts.rowName)
                        .foregroundStyle(active ? Color.rowFgActive : Color.rowNameFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let last {
                        HStack(spacing: Metrics.rowMarkGap) {
                            if last.outgoing {
                                StatusMark(
                                    state: last.state,
                                    waitingColor: active ? .rowFgActive : .windowSubFg,
                                    storedColor: active ? .rowFgActive : .rowSentIconFg
                                )
                                .frame(width: Metrics.rowMarkBox, height: Metrics.rowMarkBox)
                            }
                            Text(Formats.row(last.date))
                                .font(Fonts.rowText)
                                .foregroundStyle(active ? Color.rowFgActive : Color.rowDateFg)
                                .fixedSize()
                        }
                    }
                }
                .frame(height: 18)
                .padding(.top, Metrics.rowNameTop - Metrics.rowPadTop)
                HStack(spacing: Metrics.rowGap) {
                    Text(preview(last))
                        .font(Fonts.rowText)
                        .foregroundStyle(active ? Color.rowFgActive : Color.rowTextFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if contact.unread > 0 {
                        Badge(count: contact.unread, active: active)
                    }
                }
                .frame(height: Metrics.badgeHeight)
                .padding(.top, Metrics.rowPreviewTop - Metrics.rowNameTop - 18)
            }
            .frame(minWidth: 150)
        }
        .padding(.horizontal, Metrics.rowPadding)
        .padding(.top, Metrics.rowPadTop)
        .frame(height: Metrics.rowHeight, alignment: .top)
        .background(background(active: active))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .onTapGesture { model.openChat(contact.id) }
        .contextMenu {
            Button {
                model.openChat(contact.id)
                model.modal = .contactInfo(contact.id)
            } label: {
                Label("Contact info", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                model.modal = .delete(contact.id)
            } label: {
                Label("Delete contact", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func background(active: Bool) -> Color {
        if active { return .rowBgActive }
        if hover || keyboardSelected { return .rowBgOver }
        return .listBg
    }

    private func preview(_ message: Message?) -> String {
        guard let message else { return "No messages yet" }
        return message.text.replacingOccurrences(of: "\n", with: " ")
    }
}
