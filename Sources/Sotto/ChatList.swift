import SwiftUI

/// The left column: the bar with the menu and the search, the connection bar and the rows.
struct ChatListColumn: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let rows = model.visibleContacts
        let searching = !model.search.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            ListTopBar(model: model)
            if model.connection != .connected && model.connection != .idle {
                ConnectionBar(model: model)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
            if searching {
                SearchResults(model: model)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !model.archiveOpen, !model.archivedContacts.isEmpty {
                            ArchiveRow(model: model)
                        }
                        ForEach(rows) { contact in
                            ChatRow(model: model, contact: contact)
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
        Group {
            if model.archiveOpen && model.search.isEmpty && !focused {
                archiveBar
            } else {
                searchBar
            }
        }
        .frame(height: Metrics.topBarHeight)
        .background(Color.topBarBg)
        .onChange(of: focused) { _, value in model.searchFocused = value }
        .onChange(of: model.searchFocused) { _, value in focused = value }
        .onChange(of: model.searchFocusTick) { _, _ in
            model.archiveOpen = false
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: model.search) { _, _ in model.searchSelection = 0 }
    }

    /// The bar of the archive: back to the list and the title (DESIGN.md 19.3).
    private var archiveBar: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "chevron.left", size: 17, label: "Back to chats") { model.archiveOpen = false }
                .padding(.leading, 6)
            Text("Archived chats")
                .font(Fonts.headerTitle)
                .foregroundStyle(Color.windowBoldFg)
                .padding(.leading, 6)
            Spacer()
            IconButton(symbol: "magnifyingglass", size: 16, label: "Search") { model.searchFocusTick += 1 }
                .padding(.trailing, 8)
        }
    }

    private var searchBar: some View {
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
                    model.openSettings()
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
                    model.searchSelection = min(model.searchSelection + 1, max(model.searchRows.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.searchSelection = max(model.searchSelection - 1, 0)
                    return .handled
                }
                .onSubmit {
                    let rows = model.searchRows
                    guard rows.indices.contains(model.searchSelection) else { return }
                    model.open(rows[model.searchSelection])
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
    /// A message found by the search: the row shows it instead of the last one.
    var found: Message?
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        let active = model.openChatID == contact.id && found == nil
        let last = found ?? model.messages[contact.id]?.last
        let draft = found == nil && contact.unread == 0 && model.openChatID != contact.id
            ? model.drafts[contact.id].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } : nil
        HStack(alignment: .top, spacing: Metrics.rowTextX - Metrics.rowPadding - Metrics.rowAvatar) {
            Avatar(id: contact.id, name: contact.name, size: Metrics.rowAvatar)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Metrics.rowGap) {
                    HStack(spacing: Metrics.rowMuteGap) {
                        Text(contact.name)
                            .font(Fonts.rowName)
                            .foregroundStyle(active ? Color.rowFgActive : Color.rowNameFg)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if contact.muted {
                            RowMark(symbol: "speaker.slash.fill", active: active, label: "Muted")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let last {
                        HStack(spacing: Metrics.rowMarkGap) {
                            if last.outgoing && draft == nil {
                                StatusMark(
                                    state: last.state,
                                    waitingColor: active ? .rowFgActive : .windowSubFg,
                                    storedColor: active ? .rowFgActive : .rowSentIconFg
                                )
                                .frame(width: Metrics.rowMarkBox, height: Metrics.rowMarkBox)
                            }
                            Text(Formats.row(last.date, h24: model.clock24))
                                .font(Fonts.rowText)
                                .foregroundStyle(active ? Color.rowFgActive : Color.rowDateFg)
                                .fixedSize()
                        }
                    }
                }
                .frame(height: 18)
                .padding(.top, Metrics.rowNameTop - Metrics.rowPadTop)
                HStack(spacing: Metrics.rowGap) {
                    previewText(last, draft: draft, active: active)
                        .font(Fonts.rowText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if found == nil, contact.unread > 0 {
                        Badge(count: contact.unread, active: active, muted: contact.muted)
                    } else if found == nil, contact.pinned != nil {
                        RowMark(symbol: "pin.fill", active: active, label: "Pinned")
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
        .onTapGesture {
            if let found { model.focus(found.id, in: contact.id) } else { model.openChat(contact.id) }
        }
        .contextMenu {
            Button {
                model.setPinned(contact.id, contact.pinned == nil)
            } label: {
                Label(contact.pinned == nil ? "Pin" : "Unpin", systemImage: contact.pinned == nil ? "pin" : "pin.slash")
            }
            .disabled(contact.archived)
            Button {
                model.setMuted(contact.id, !contact.muted)
            } label: {
                Label(contact.muted ? "Unmute" : "Mute notifications", systemImage: contact.muted ? "speaker.wave.2" : "speaker.slash")
            }
            Button {
                model.setArchived(contact.id, !contact.archived)
            } label: {
                Label(contact.archived ? "Unarchive" : "Archive", systemImage: contact.archived ? "tray.and.arrow.up" : "archivebox")
            }
            Divider()
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

    /// "Draft: " and the draft, or the last (or found) message as one line (DESIGN.md 19.2).
    private func previewText(_ message: Message?, draft: String?, active: Bool) -> Text {
        let color = active ? Color.rowFgActive : Color.rowTextFg
        if let draft {
            return Text("Draft: ").foregroundColor(active ? .draftFgActive : .draftFg)
                + Text(oneLine(draft)).foregroundColor(color)
        }
        guard let message else { return Text("No messages yet").foregroundColor(color) }
        return Text(oneLine(message.preview)).foregroundColor(color)
    }

    private func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// The pin or mute mark of a row, in the colours of a muted badge.
struct RowMark: View {
    let symbol: String
    let active: Bool
    let label: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Metrics.rowMarkSymbol))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(active ? Color.badgeBgMutedActive : Color.badgeBgMuted)
            .accessibilityLabel(label)
    }
}

/// The row that opens the archived chats, on top of the list (DESIGN.md 19.3).
struct ArchiveRow: View {
    let model: AppModel
    @State private var hover = false

    var body: some View {
        let archived = model.archivedContacts
        let unread = archived.reduce(0) { $0 + $1.unread }
        HStack(alignment: .top, spacing: Metrics.rowTextX - Metrics.rowPadding - Metrics.rowAvatar) {
            Circle()
                .fill(Color.archiveAvatarBg)
                .frame(width: Metrics.rowAvatar, height: Metrics.rowAvatar)
                .overlay {
                    Image(systemName: "archivebox.fill").font(.system(size: 20)).foregroundStyle(Color.avatarFg)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text("Archived chats")
                    .font(Fonts.rowName)
                    .foregroundStyle(Color.rowNameFg)
                    .lineLimit(1)
                    .frame(height: 18)
                    .padding(.top, Metrics.rowNameTop - Metrics.rowPadTop)
                HStack(spacing: Metrics.rowGap) {
                    Text(archived.map(\.name).joined(separator: ", "))
                        .font(Fonts.rowText)
                        .foregroundStyle(Color.archiveFg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if unread > 0 { Badge(count: unread, muted: true) }
                }
                .frame(height: Metrics.badgeHeight)
                .padding(.top, Metrics.rowPreviewTop - Metrics.rowNameTop - 18)
            }
            .frame(minWidth: 150)
        }
        .padding(.horizontal, Metrics.rowPadding)
        .padding(.top, Metrics.rowPadTop)
        .frame(height: Metrics.rowHeight, alignment: .top)
        .background(hover ? Color.rowBgOver : Color.listBg)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .onTapGesture { model.archiveOpen = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Archived chats")
        .accessibilityAddTraits(.isButton)
    }
}

/// Chats found by name, then the bar "Found N messages" and the messages found by text
/// (DESIGN.md 5.2 and 19.4).
struct SearchResults: View {
    let model: AppModel

    var body: some View {
        let rows = model.searchRows
        let firstMessage = rows.firstIndex { if case .message = $0 { true } else { false } }
        let found = firstMessage.map { rows.count - $0 } ?? 0
        if rows.isEmpty {
            VStack(spacing: 0) {
                Text("Nothing found")
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.windowSubFg)
                    .padding(.top, 20)
                Spacer()
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index == firstMessage {
                            Text(found == 1 ? "Found 1 message" : "Found \(found) messages")
                                .font(Fonts.rowText)
                                .foregroundStyle(Color.searchedBarFg)
                                .padding(Metrics.searchedBarText)
                                .frame(maxWidth: .infinity, minHeight: Metrics.searchedBar, alignment: .topLeading)
                                .background(Color.searchedBarBg)
                        }
                        let selected = model.searchFocused && index == model.searchSelection
                        switch row {
                        case .chat(let contact):
                            ChatRow(model: model, contact: contact, keyboardSelected: selected)
                        case .message(let contact, let message):
                            ChatRow(model: model, contact: contact, keyboardSelected: selected, found: message)
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }
}
