import AppKit
import SottoCore
import SwiftUI
import UniformTypeIdentifiers

/// A file picked, dropped or pasted, waiting in the send box (DESIGN.md 14.2).
struct Pick: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int
    /// A picture that is sent as a photo unless "Send as file" is checked.
    let isPicture: Bool

    /// Nil for a folder or a file that cannot be read.
    init?(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), values.isDirectory == false
        else { return nil }
        self.url = url
        size = values.fileSize ?? 0
        isPicture = ChatFile.isPhoto(Self.mediaType(url) ?? "")
    }

    static func mediaType(_ url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    /// Why the file is left out when sending.
    var problem: String? {
        if size > Blob.maxFileBytes { return "Too large (largest is 100 MB)" }
        if size == 0 { return "The file is empty." }
        return nil
    }
}

enum DropZone: Equatable {
    case files, photos
}

/// Files dragged over the chat area: `pictures` when every one is a picture, which splits the
/// card into a files zone and a photos zone.
struct DropState: Equatable {
    var pictures: Bool
    var hover: DropZone?
}

struct ViewerItem: Equatable {
    let chatID: String
    let messageID: String
}

/// A file handed to the messenger, shown as a message until its own message is logged.
struct LocalSend {
    var message: Message
    /// The id of the logged message once the messenger returned it.
    var resolved: String?
    var cancelled = false
    /// Hands the file to the messenger; cancelled with the message.
    var task: Task<Void, Never>?
}

extension AppModel {
    // MARK: Attaching (DESIGN.md 14)

    func openPicker(photos: Bool) {
        attachMenuOpen = false
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if photos { panel.allowedContentTypes = [.png, .jpeg, .heic, .gif] }
        guard panel.runModal() == .OK else { return }
        stage(panel.urls)
    }

    /// Opens the send box with the files; a folder is left out with a toast.
    func stage(_ urls: [URL], asFile: Bool = false) {
        guard openChatID != nil else { return }
        let picked = urls.compactMap(Pick.init)
        if picked.count < urls.count { showToast("Folders can not be sent.") }
        guard !picked.isEmpty else { return }
        attachMenuOpen = false
        picks = picked
        sendAsFile = asFile
        modal = .sendFiles
    }

    /// A picture from the pasteboard, kept as a PNG in the data folder so that the photo can
    /// be shown and sent again later.
    func stagePasted(_ png: Data) {
        let folder = (dataDirectory ?? FileManager.default.temporaryDirectory).appendingPathComponent("Pasted", isDirectory: true)
        let stamp = Self.fileStamp.string(from: Date())
        let url = folder.appendingPathComponent("Pasted image \(stamp).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .withoutOverwriting)
            stage([url])
        } catch {
            showToast("The picture could not be kept: \(error.localizedDescription)")
        }
    }

    static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()

    /// The send box closed with Send: its files go to the open chat, the caption with the first.
    func sendPicks(caption: String) {
        guard let chat = openChatID else { return }
        modal = nil
        let replyTo = replies.removeValue(forKey: chat)
        send(picks, caption: caption.trimmingCharacters(in: .whitespacesAndNewlines), asFile: sendAsFile, to: chat, replyTo: replyTo)
        picks = []
    }

    /// Sends files as separate messages in their order. A picture goes as a photo with its
    /// size and thumbnail; as a file it goes with an empty media type, so it shows as a file.
    /// The first file answers the message `replyTo` when one is given (DESIGN.md 20.2).
    func send(_ picks: [Pick], caption: String, asFile: Bool, to chat: String, replyTo: String? = nil) {
        let jobs = picks.filter { $0.problem == nil }.enumerated().map { index, pick in
            let photo = pick.isPicture && !asFile ? Thumbnail.make(pick.url) : nil
            let mediaType = pick.isPicture && asFile ? "" : Pick.mediaType(pick.url)
            let file = ChatFile(
                name: pick.url.lastPathComponent, size: pick.size, mediaType: mediaType ?? "",
                state: messenger == nil ? .sent : .sending, savedAs: pick.url.path,
                width: photo?.width ?? 0, height: photo?.height ?? 0, thumbnail: photo?.jpeg ?? Data())
            var message = Message(
                id: "local-\(UUID().uuidString)", outgoing: true, text: index == 0 ? caption : "", date: Date(),
                state: .waiting, file: file)
            if index == 0 {
                message.quote = replyTo.flatMap { quote(of: $0, in: chat) }
            }
            return (message, pick.url, mediaType, photo)
        }
        withAnimation(Motion.reorder) {
            for (message, _, _, _) in jobs {
                messages[chat, default: []].append(message)
                if messenger != nil { localSends[chat, default: []].append(LocalSend(message: message)) }
            }
        }
        guard let messenger else {
            jobs.forEach { store($0.0.id, in: chat) }
            return
        }
        for (message, url, mediaType, photo) in jobs {
            let before = lastFileSend
            let task = Task { [weak self] in
                await before?.value
                do {
                    try Task.checkCancellation()
                    let position = try await messenger.sendFile(
                        url, caption: message.text, to: chat, mediaType: mediaType,
                        width: photo?.width ?? 0, height: photo?.height ?? 0, thumbnail: photo?.jpeg ?? Data(),
                        replyTo: message.quote?.messageID.flatMap { Int64($0) })
                    // Cancelled while the upload was being made: its message goes at once.
                    if Task.isCancelled || position == 0 {
                        if position != 0 { try? await messenger.deleteMessage(position) }
                        self?.dropLocal(message.id, in: chat)
                    } else {
                        self?.resolve(message.id, as: String(position), in: chat)
                    }
                } catch is CancellationError {
                    self?.dropLocal(message.id, in: chat)
                } catch {
                    self?.dropLocal(message.id, in: chat)
                    self?.messages[chat]?.removeAll { $0.id == message.id }
                    self?.showToast(Messenger.describe(error))
                }
            }
            if let index = localSends[chat]?.firstIndex(where: { $0.message.id == message.id }) {
                localSends[chat]?[index].task = task
            }
            lastFileSend = task
        }
    }

    private func resolve(_ localID: String, as id: String, in chat: String) {
        guard let index = localSends[chat]?.firstIndex(where: { $0.message.id == localID }) else { return }
        localSends[chat]?[index].resolved = id
        if messages[chat]?.contains(where: { $0.id == id }) == true {
            dropLocal(localID, in: chat)
            messages[chat]?.removeAll { $0.id == localID }
        }
    }

    private func dropLocal(_ localID: String, in chat: String) {
        localSends[chat]?.removeAll { $0.message.id == localID }
        messages[chat]?.removeAll { $0.id == localID }
    }

    // MARK: Photo and file actions (DESIGN.md 13)

    /// A click on a photo or on a file row: the action of its state.
    func tap(_ message: Message, in chat: String) {
        guard let file = message.file else { return }
        switch file.state {
        case .offered, .notReceived: run { try await $0.download(Self.position(message)) }
        case .receiving: run { try await $0.pauseDownload(Self.position(message)) }
        // A file not logged yet is dropped when the messenger returns it; a logged one is
        // deleted, which ends its upload (protocol section 33.2).
        case .sending: deleteMessage(message.id, in: chat)
        case .notSent: run { try await $0.resendFile(Self.position(message)) }
        case .sent, .received:
            if file.isPhoto {
                withAnimation(Motion.viewer) { viewer = ViewerItem(chatID: chat, messageID: message.id) }
            } else if let url = Media.localURL(file) {
                NSWorkspace.shared.open(url)
            }
        case .notAvailable: break
        }
    }

    private static func position(_ message: Message) -> Int64 {
        Int64(message.id) ?? 0
    }

    /// The system save panel, then a copy of the file where it says.
    func saveAs(_ message: Message) {
        guard let file = message.file, let source = Media.localURL(file) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name.isEmpty ? "Photo \(Self.fileStamp.string(from: message.date)).jpg" : file.name
        panel.directoryURL = downloadFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let target = panel.url else { return }
        // Saved onto itself: removing the target would remove the only copy.
        guard target.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else {
            return showToast("Saved to \(target.deletingLastPathComponent().lastPathComponent)")
        }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            showToast("Saved to \(target.deletingLastPathComponent().lastPathComponent)")
        } catch {
            showToast("Could not save: \(error.localizedDescription)")
        }
    }

    func copyImage(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showToast("Image copied")
    }

    /// The photos of a chat, oldest first: the pictures of the media viewer.
    func photos(in chat: String) -> [Message] {
        (messages[chat] ?? []).filter { $0.file?.isPhoto == true && !$0.id.hasPrefix("local-") }
    }

    /// Moves the viewer to the previous (-1) or next (1) photo of its chat.
    func stepViewer(_ by: Int) {
        guard let item = viewer else { return }
        let list = photos(in: item.chatID)
        guard let index = list.firstIndex(where: { $0.id == item.messageID }), list.indices.contains(index + by) else { return }
        viewer = ViewerItem(chatID: item.chatID, messageID: list[index + by].id)
    }
}

/// The popup of the attach button: Photo, File (DESIGN.md 14.1).
struct AttachMenu: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            item("photo", "Photo") { model.openPicker(photos: true) }
            item("doc", "File") { model.openPicker(photos: false) }
        }
        .padding(.vertical, 5)
        .frame(width: Metrics.attachMenuWidth)
        .background(
            RoundedRectangle(cornerRadius: Metrics.boxRadius).fill(Color.windowBg).shadow(color: .shadow, radius: 6, y: 2))
    }

    private func item(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        HoverRow(height: 34, action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.menuIconFg)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 15)
                Text(title)
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.windowFg)
                    .padding(.leading, 15)
                Spacer(minLength: 17)
            }
        }
    }
}

/// The box before sending: the previews or rows, "Send as file", the caption (DESIGN.md 14.2).
struct SendBox: View {
    @Bindable var model: AppModel
    @State private var caption = ""
    @FocusState private var captionFocused: Bool

    private var sendable: [Pick] { model.picks.filter { $0.problem == nil } }
    private var allPictures: Bool { !model.picks.isEmpty && model.picks.allSatisfy(\.isPicture) }

    private var title: String {
        let photos = allPictures && !model.sendAsFile
        let count = model.picks.count
        return count == 1 ? (photos ? "Send photo" : "Send file") : "Send \(count) \(photos ? "photos" : "files")"
    }

    var body: some View {
        ModalBox(title: title, wide: true) {
            VStack(alignment: .leading, spacing: 0) {
                items
                if model.picks.contains(where: \.isPicture) {
                    Button { model.sendAsFile.toggle() } label: {
                        HStack(spacing: 12) {
                            CheckSquare(checked: model.sendAsFile, size: 18)
                            Text("Send as file").font(Fonts.settingsRow).foregroundStyle(Color.windowBoldFg)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 20)
                    .accessibilityValue(model.sendAsFile ? "On" : "Off")
                }
                TextField("", text: $caption, prompt: Text("Add a caption...").foregroundStyle(Color.placeholderFg), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.windowFg)
                    .lineLimit(1...3)
                    .focused($captionFocused)
                    .padding(.vertical, 7)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(captionFocused ? Color.activeLine : Color.divider).frame(height: captionFocused ? 2 : 1)
                    }
                    .padding(.top, 8)
                    .onSubmit { send() }
                    .accessibilityLabel("Caption")
            }
            .padding(.horizontal, Metrics.sendBodyPad - Metrics.boxPad)
            .padding(.top, 6)
            .padding(.bottom, 10)
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: "Send", enabled: !sendable.isEmpty, action: send).keyboardShortcut(.defaultAction)
        }
        .onChange(of: caption) { _, value in
            if value.utf8.count > Envelope.maxCaptionBytes {
                var cut = value
                while cut.utf8.count > Envelope.maxCaptionBytes { cut.removeLast() }
                caption = cut
            }
        }
        .onAppear { DispatchQueue.main.async { captionFocused = true } }
        .onChange(of: model.picks) { _, picks in
            if picks.isEmpty { model.modal = nil }
        }
    }

    private func send() {
        guard !sendable.isEmpty else { return }
        model.sendPicks(caption: caption)
    }

    @ViewBuilder
    private var items: some View {
        if model.picks.count == 1, let pick = model.picks.first {
            if pick.isPicture, !model.sendAsFile, let image = Media.picture(pick.url, side: Metrics.sendPreview) {
                let scale = min(1, Metrics.sendPreview / image.size.width, Metrics.sendPreview / image.size.height)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity)
            } else {
                PickRow(pick: pick, remove: nil)
            }
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.picks) { pick in
                        PickRow(pick: pick) { model.picks.removeAll { $0.id == pick.id } }
                    }
                }
            }
            .frame(maxHeight: Metrics.fileTile * 5 + 40)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A file of the send box: a tile with the extension (or the picture), the name and the size.
struct PickRow: View {
    let pick: Pick
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            tile
            VStack(alignment: .leading, spacing: 3) {
                Text(pick.url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.windowBoldFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(pick.problem ?? Formats.bytes(pick.size))
                    .font(Fonts.rowText)
                    .foregroundStyle(pick.problem == nil ? Color.windowSubFg : Color.fieldError)
            }
            Spacer(minLength: 0)
            if let remove {
                IconButton(symbol: "xmark", size: 14, label: "Remove \(pick.url.lastPathComponent)", side: 34, action: remove)
            }
        }
        .frame(height: Metrics.fileTile)
    }

    @ViewBuilder
    private var tile: some View {
        if pick.isPicture, let image = Media.picture(pick.url, side: Metrics.fileTile) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Metrics.fileTile, height: Metrics.fileTile)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            let ext = String(pick.url.pathExtension.prefix(4)).lowercased()
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.fileTones[Int(ext.unicodeScalars.reduce(0) { $0 &+ $1.value }) % Color.fileTones.count])
                .frame(width: Metrics.fileTile, height: Metrics.fileTile)
                .overlay { Text(ext).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
        }
    }
}

/// The card over the chat area while files are dragged over it (DESIGN.md 14.3).
struct DropOverlay: View {
    let state: DropState

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: Metrics.dropInset) {
                if state.pictures {
                    card("Drop files here", "to send them as files", lit: state.hover == .files)
                        .frame(height: (geometry.size.height - 3 * Metrics.dropInset) / 3)
                    card("Drop photos here", "to send them as photos", lit: state.hover == .photos)
                } else {
                    card("Drop files here", "to send them in the chat", lit: state.hover != nil)
                }
            }
            .padding(Metrics.dropInset)
        }
        .allowsHitTesting(false)
    }

    private func card(_ title: String, _ subtitle: String, lit: Bool) -> some View {
        GeometryReader { geometry in
            let colour = lit ? Color.accentText : Color.windowSubFg
            VStack(spacing: 4) {
                if geometry.size.height >= Metrics.dropBlock + 2 * 28 + 56 + 4 {
                    Image(systemName: "arrow.down.doc").font(.system(size: 56)).foregroundStyle(colour)
                }
                VStack(spacing: 0) {
                    Text(title).font(.system(size: 27, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(subtitle).font(.system(size: 19, weight: .semibold))
                }
                .foregroundStyle(colour)
                .frame(height: Metrics.dropBlock)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(
                RoundedRectangle(cornerRadius: Metrics.boxRadius).fill(Color.boxBg).shadow(color: .shadow, radius: 12, y: 4))
            .animation(Motion.drop, value: lit)
        }
    }
}

/// Takes the files dropped on the chat area to the send box.
struct ChatDropDelegate: DropDelegate {
    let model: AppModel
    let height: CGFloat

    private func zone(_ info: DropInfo) -> DropZone {
        model.drop?.pictures == true && info.location.y < height / 3 ? .files : .photos
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let providers = info.itemProviders(for: [.fileURL])
        let pictures = !providers.isEmpty && providers.allSatisfy { provider in
            provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
        }
        withAnimation(Motion.drop) { model.drop = DropState(pictures: pictures, hover: nil) }
        model.drop?.hover = zone(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        model.drop?.hover = zone(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        withAnimation(Motion.drop) { model.drop = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let asFile = model.drop?.pictures == true && zone(info) == .files
        withAnimation(Motion.drop) { model.drop = nil }
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                    let fileURL = URL(dataRepresentation: url, relativeTo: nil)
                {
                    urls.append(fileURL)
                }
            }
            model.stage(urls, asFile: asFile)
        }
        return true
    }
}
