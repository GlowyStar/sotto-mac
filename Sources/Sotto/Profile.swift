import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import SottoCore
import SwiftUI
import UniformTypeIdentifiers

// The profile of DESIGN.md 12 and the avatars with a photo of DESIGN.md 16.

/// The profile being edited on the Edit profile page; nothing is sent before "Save".
struct ProfileDraft: Equatable {
    var name: String
    /// The avatar the page shows: the saved one, a new one from the crop box, or none.
    var avatar: ProfilePhoto?
}

/// The picture the crop box works on.
struct CropSource {
    let image: CGImage
}

/// Decoded avatars, kept for the next draw.
@MainActor
enum AvatarPictures {
    private static let cache = NSCache<NSString, NSImage>()

    /// The picture of an avatar at `side` points, at 2x: the picture when it decodes as a JPEG
    /// or a PNG, else the thumbnail when it decodes as a JPEG, else nil (protocol 36.4).
    static func image(_ photo: ProfilePhoto, side: CGFloat) -> NSImage? {
        let pixels = Int(side * 2)
        let key = "\(photo.key)#\(photo.picture == nil ? "t" : String(pixels))" as NSString
        if let kept = cache.object(forKey: key) { return kept }
        let made = photo.picture.flatMap { decode($0, pixels: pixels) } ?? Thumbnail.decode(photo.thumbnail)
        guard let made else { return nil }
        let image = NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
        cache.setObject(image, forKey: key)
        return image
    }

    private static func decode(_ data: Data, pixels: Int) -> CGImage? {
        let types = [UTType.jpeg.identifier, UTType.png.identifier]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?, types.contains(type)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The avatar the app sends: a square JPEG of 512 and a 128 thumbnail (DESIGN.md 12.3),
/// within the limits of protocol section 35.2.
enum AvatarPicture {
    static let side = 512
    static let thumbnailSide = 128
    static let quality = 0.85
    /// The largest file the picker takes (DESIGN.md 12.2).
    static let largestFile = 20_000_000
    /// The longest side a chosen picture is read at.
    static let readSide = 2048

    enum Problem: Error {
        case notAPicture, tooLarge
    }

    /// The picture of a file, its orientation applied, at most `readSide` on its longest side.
    static func load(_ url: URL) throws -> CGImage {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= largestFile else { throw Problem.tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: readSide,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw Problem.notAPicture }
        return image
    }

    /// The square of `image` at `crop` (pixels, origin at the top left) as the avatar.
    static func make(_ image: CGImage, crop: CGRect) -> ProfilePhoto? {
        guard let square = image.cropping(to: crop.integral), let big = draw(square, side: side),
            let small = draw(big, side: thumbnailSide),
            let picture = jpeg(big, within: Envelope.maxAvatarBytes),
            let thumbnail = jpeg(small, within: Envelope.maxThumbnailBytes)
        else { return nil }
        return ProfilePhoto(key: UUID().uuidString, picture: picture, thumbnail: thumbnail, state: .received)
    }

    /// The largest centered square of an image.
    static func centered(_ image: CGImage) -> CGRect {
        let side = min(image.width, image.height)
        return CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
    }

    /// The image turned a quarter clockwise.
    static func turned(_ image: CGImage) -> CGImage {
        let (w, h) = (image.width, image.height)
        guard let context = CGContext(
            data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.translateBy(x: 0, y: CGFloat(w))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }

    /// The pixel size of a picture, 0 by 0 when it does not decode.
    static func pixelSize(_ data: Data) -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return (0, 0) }
        return (properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    private static func draw(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// A JPEG at `quality`, lower until it fits `limit` bytes.
    private static func jpeg(_ image: CGImage, within limit: Int) -> Data? {
        var quality = Self.quality
        while quality > 0.1 {
            if let data = Thumbnail.jpeg(image, quality: quality), data.count <= limit { return data }
            quality -= 0.15
        }
        return nil
    }
}

/// The QR code of the id (DESIGN.md 12.4), drawn with Core Image.
@MainActor
enum QRCode {
    /// The code without the margin of the generator, `scale` pixels per module; level M.
    static func modules(_ text: String, scale: Int = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.samplingNearest() else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        // The generator adds a margin of one module.
        let code = scaled.extent.insetBy(dx: CGFloat(scale), dy: CGFloat(scale))
        return CIContext().createCGImage(scaled, from: code)
    }

    /// The plate as a PNG: white, the code with a quiet zone of `Metrics.qrSavedQuiet`, at 2x.
    static func png(_ text: String) -> Data? {
        guard let code = modules(text, scale: 1) else { return nil }
        let scale = 2
        let inner = Int(Metrics.qrPlate - 2 * Metrics.qrQuiet) * scale
        let side = inner + Int(Metrics.qrSavedQuiet) * 2 * scale
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .none
        let quiet = (side - inner) / 2
        context.draw(code, in: CGRect(x: quiet, y: quiet, width: inner, height: inner))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: Actions

extension AppModel {
    /// The own avatar and its initials, for every place that draws it.
    var ownName: String { profile.name.isEmpty ? "Me" : profile.name }

    func openProfile() {
        profileDraft = ProfileDraft(name: profile.name, avatar: profile.avatar)
        settingsPage = .profile
    }

    var profileChanged: Bool {
        guard let draft = profileDraft else { return false }
        return draft.name.trimmingCharacters(in: .whitespacesAndNewlines) != profile.name || draft.avatar?.key != profile.avatar?.key
    }

    /// Back, Escape or close on a settings page: the Edit profile page asks first when it
    /// holds changes (DESIGN.md 12.1).
    func leavePage() {
        if settingsPage == .profile, profileChanged {
            settingsDialog = .discardProfile
            return
        }
        profileDraft = nil
        settingsPage = nil
    }

    func discardProfile() {
        settingsDialog = nil
        profileDraft = nil
        settingsPage = nil
    }

    /// The system file panel, then the crop box (DESIGN.md 12.2); from the settings cover it
    /// opens the Edit profile page under the crop box.
    func pickAvatar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        pickingAvatar = true
        defer { pickingAvatar = false }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startCrop(url)
    }

    func startCrop(_ url: URL) {
        do {
            let image = try AvatarPicture.load(url)
            if settingsPage != .profile { openProfile() }
            cropSource = CropSource(image: image)
            settingsDialog = .crop
        } catch AvatarPicture.Problem.tooLarge {
            showToast("The picture is too large.")
        } catch {
            showToast("Choose a picture.")
        }
    }

    func applyCrop(_ image: CGImage, _ crop: CGRect) {
        settingsDialog = nil
        cropSource = nil
        guard let photo = AvatarPicture.make(image, crop: crop) else { return showToast("Choose a picture.") }
        withAnimation(Motion.picture) { profileDraft?.avatar = photo }
    }

    func saveProfile() {
        guard let draft = profileDraft, profileChanged else { return }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profileDraft = nil
        settingsPage = nil
        guard messenger != nil else {
            profile = UserProfile(name: name, avatar: draft.avatar)
            return showToast("Profile saved")
        }
        setProfile(name: name, avatar: draft.avatar) { [weak self] in self?.showToast("Profile saved") }
    }

    func setProfile(name: String, avatar: ProfilePhoto?, saved: (@MainActor () -> Void)? = nil) {
        let picture = avatar?.picture
        let thumbnail = avatar?.thumbnail ?? Data()
        let size = picture.map(AvatarPicture.pixelSize) ?? (width: 0, height: 0)
        run { messenger in
            try await messenger.setProfile(name: name, avatar: picture, thumbnail: thumbnail, width: size.width, height: size.height)
            await saved?()
        }
    }

    /// `--profile NAME PATH`: the profile set as "Save" sets it, the picture cut to its
    /// centered square; an empty path is no picture.
    func setScriptedProfile(name: String, path: String) {
        var avatar: ProfilePhoto?
        if !path.isEmpty {
            guard let image = try? AvatarPicture.load(URL(fileURLWithPath: path)),
                let made = AvatarPicture.make(image, crop: AvatarPicture.centered(image))
            else {
                FileHandle.standardError.write(Data("--profile: no picture at \(path)\n".utf8))
                return
            }
            avatar = made
        }
        setProfile(name: name, avatar: avatar)
    }

    func saveQRCode() {
        guard let png = QRCode.png(myID) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Sotto id.png"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                showToast(Messenger.describe(error))
            }
        }
    }
}

// MARK: Views

/// The avatar of the Edit profile page and the settings cover: a click opens the picker,
/// hover shows the change overlay, a picture dropped on it opens the crop box.
struct EditableAvatar: View {
    let model: AppModel
    let photo: ProfilePhoto?
    let name: String
    let size: CGFloat
    let action: () -> Void
    @State private var hover = false
    @State private var dropping = false

    var body: some View {
        Button(action: action) {
            Avatar(id: model.myID, name: name, size: size, photo: photo)
                .overlay {
                    Circle()
                        .fill(Color.mediaOverlayBgOver)
                        .overlay(Image(systemName: "camera.fill").font(.system(size: 28)).foregroundStyle(Color.mediaOverlayFg))
                        .opacity(hover || model.pickingAvatar ? 1 : 0)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .overlay {
            Circle().strokeBorder(Color.accent, lineWidth: 2).padding(-5).opacity(dropping ? 1 : 0)
        }
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.startCrop(url) }
            }
            return true
        }
        .accessibilityLabel("Change photo")
    }
}

/// The Edit profile page (DESIGN.md 12.1).
struct EditProfilePage: View {
    @Bindable var model: AppModel

    private var name: Binding<String> {
        Binding(
            get: { model.profileDraft?.name ?? "" },
            set: { model.profileDraft?.name = Self.cleaned($0) }
        )
    }

    /// Without control characters, at most 64 characters and the bytes of protocol 35.2.
    static func cleaned(_ text: String) -> String {
        var name = String(String.UnicodeScalarView(text.unicodeScalars.filter { !Envelope.isControl($0) }))
        name = String(name.prefix(Metrics.nameLimit))
        while name.utf8.count > Envelope.maxProfileNameBytes { name.removeLast() }
        return name
    }

    var body: some View {
        let draft = model.profileDraft
        let count = draft?.name.count ?? 0
        VStack(spacing: 0) {
            EditableAvatar(
                model: model, photo: draft?.avatar, name: draft?.name.isEmpty == false ? draft!.name : "Me",
                size: Metrics.editAvatar
            ) { model.pickAvatar() }
            .padding(.top, 20)
            BoxButton(title: "Set new photo") { model.pickAvatar() }.padding(.top, 12)
            if draft?.avatar != nil {
                BoxButton(title: "Remove photo", danger: true) {
                    withAnimation(Motion.picture) { model.profileDraft?.avatar = nil }
                }
                .padding(.top, 4)
            }
            HStack {
                Text("Display name").font(Fonts.label).foregroundStyle(Color.windowSubFg)
                Spacer()
                if count >= Metrics.nameCounterFrom {
                    Text("\(Metrics.nameLimit - count)").font(Fonts.label).foregroundStyle(Color.windowSubFg).monospacedDigit()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            BoxField(label: "", placeholder: "Your name", text: name)
                .padding(.horizontal, 22)
                .padding(.top, 6)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        Hint(text: "Your name and photo are sent, encrypted, to your contacts. They can still rename you on their side.")
        SectionTitle(text: "Id")
        IDBlock(id: model.myID).padding(.horizontal, 22)
        VStack(spacing: 0) {
            ProfileRow(symbol: "doc.on.doc", title: "Copy id") { model.copyID(model.myID) }
            ProfileRow(symbol: "qrcode", title: "Show QR code") { model.settingsDialog = .qrCode }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

/// An action row of DESIGN.md 7.4: height 44, icon 18 at left 24, text at left 60.
struct ProfileRow: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.menuIconFg)
                    .frame(width: 36, alignment: .leading)
                Text(title).font(Fonts.boxBody).foregroundStyle(Color.windowFg)
            }
            .padding(.leading, 24)
        }
    }
}

/// "Discard changes?" when the Edit profile page is left with changes.
struct DiscardProfileBox: View {
    let model: AppModel

    var body: some View {
        ModalBox(title: "Discard changes?") {
            Text("The new name and photo are not saved.")
                .font(Fonts.boxBody)
                .foregroundStyle(Color.windowFg)
                .fixedSize(horizontal: false, vertical: true)
        } buttons: {
            BoxButton(title: "Keep editing") { model.settingsDialog = nil }
            BoxButton(title: "Discard", danger: true) { model.discardProfile() }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The QR code box (DESIGN.md 12.4).
struct QRCodeBox: View {
    let model: AppModel

    var body: some View {
        ModalBox(title: "QR code", wide: true) {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.qrBg)
                    .frame(width: Metrics.qrPlate, height: Metrics.qrPlate)
                    .overlay {
                        if let code = QRCode.modules(model.myID) {
                            Image(decorative: code, scale: 1)
                                .resizable()
                                .interpolation(.none)
                                .padding(Metrics.qrQuiet)
                        }
                    }
                    .accessibilityLabel("QR code of your id")
                IDBlock(id: model.myID)
            }
            .frame(maxWidth: .infinity)
        } buttons: {
            BoxButton(title: "Copy id") { model.copyID(model.myID) }
            Button { model.saveQRCode() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 14))
                    Text("Save image").font(Fonts.button)
                }
                .foregroundStyle(Color.accentText)
                .padding(.horizontal, Metrics.buttonPadH)
                .frame(height: Metrics.buttonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            BoxButton(title: "Close") { model.settingsDialog = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The crop box (DESIGN.md 12.3): the picture under a circle that is moved and resized,
/// zoomed by a scroll or a pinch, moved by a two-finger drag and turned a quarter.
struct CropBox: View {
    let model: AppModel
    let source: CGImage
    @State private var image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var pinchStart: CGFloat?
    /// The center of the picture on the canvas.
    @State private var center = CGPoint(x: Metrics.cropCanvas.width / 2, y: Metrics.cropCanvas.height / 2)
    /// The square of the circle on the canvas.
    @State private var frame = CGRect.zero
    @State private var dragStart: CGRect?
    @State private var dragging = false
    @State private var monitor: Any?

    private let canvas = Metrics.cropCanvas

    var body: some View {
        let shown = image ?? source
        let picture = pictureRect(shown)
        ModalBox(title: "Choose the area", wide: true) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Color.imageBg
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: picture.width, height: picture.height)
                        .position(x: picture.midX, y: picture.midY)
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: canvas))
                        path.addEllipse(in: frame)
                    }
                    .fill(Color.cropFadeBg, style: FillStyle(eoFill: true))
                    grid.opacity(dragging ? 1 : 0).animation(Motion.cropGrid, value: dragging)
                    Rectangle()
                        .strokeBorder(Color.cropHandleFg, lineWidth: 1)
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .gesture(move(bounds(picture)))
                    ForEach(0..<4, id: \.self) { corner in
                        Rectangle()
                            .fill(Color.cropHandleFg)
                            .frame(width: Metrics.cropHandle, height: Metrics.cropHandle)
                            .contentShape(Rectangle().inset(by: -6))
                            .position(point(of: corner, in: frame))
                            .gesture(resize(corner, bounds(picture)))
                    }
                }
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? zoom
                            pinchStart = start
                            setZoom(start * value.magnification)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                HStack {
                    Button { turn() } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.viewerControlFg)
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rotate")
                }
                .frame(width: canvas.width, height: 48)
                .background(Color.imageBg)
            }
            .padding(.horizontal, -Metrics.boxPad)
            .padding(.top, -2)
        } buttons: {
            BoxButton(title: "Cancel") {
                model.cropSource = nil
                model.settingsDialog = nil
            }
            BoxButton(title: "Apply") { model.applyCrop(shown, cropInPixels(shown)) }.keyboardShortcut(.defaultAction)
        }
        .onAppear {
            image = source
            reset(source)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                MainActor.assumeIsolated { scrolled(event) }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    private var grid: some View {
        Path { path in
            for third in 1...2 {
                let x = frame.minX + frame.width * CGFloat(third) / 3
                let y = frame.minY + frame.height * CGFloat(third) / 3
                path.move(to: CGPoint(x: x, y: frame.minY))
                path.addLine(to: CGPoint(x: x, y: frame.maxY))
                path.move(to: CGPoint(x: frame.minX, y: y))
                path.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(Color.cropHandleFg, lineWidth: 1)
        .allowsHitTesting(false)
    }

    /// The picture fitted into the canvas less its margins, times the zoom.
    private func pictureRect(_ image: CGImage, zoom: CGFloat? = nil, center: CGPoint? = nil) -> CGRect {
        let (zoom, center) = (zoom ?? self.zoom, center ?? self.center)
        let inner = CGSize(width: canvas.width - 2 * Metrics.cropMargin, height: canvas.height - 2 * Metrics.cropMargin)
        let fit = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * fit * zoom, height: CGFloat(image.height) * fit * zoom)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the circle may go: the picture, as far as the canvas shows it.
    private func bounds(_ picture: CGRect) -> CGRect {
        picture.intersection(CGRect(origin: .zero, size: canvas))
    }

    private func reset(_ image: CGImage) {
        let middle = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
        zoom = 1
        center = middle
        let picture = pictureRect(image, zoom: 1, center: middle)
        let side = min(picture.width, picture.height, Metrics.cropStart)
        frame = CGRect(x: picture.midX - side / 2, y: picture.midY - side / 2, width: side, height: side)
    }

    private func turn() {
        let turned = AvatarPicture.turned(image ?? source)
        image = turned
        reset(turned)
    }

    private func point(of corner: Int, in rect: CGRect) -> CGPoint {
        CGPoint(x: corner % 2 == 0 ? rect.minX : rect.maxX, y: corner < 2 ? rect.minY : rect.maxY)
    }

    /// The circle inside the picture: no larger than it and moved back within it.
    private func fitted(_ rect: CGRect, in picture: CGRect) -> CGRect {
        let side = min(rect.width, picture.width, picture.height)
        let x = min(max(rect.midX - side / 2, picture.minX), picture.maxX - side)
        let y = min(max(rect.midY - side / 2, picture.minY), picture.maxY - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    private func move(_ picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? frame
                dragStart = start
                dragging = true
                frame = fitted(start.offsetBy(dx: drag.translation.width, dy: drag.translation.height), in: picture)
            }
            .onEnded { _ in
                dragStart = nil
                dragging = false
            }
    }

    /// A corner moves while the opposite one stays.
    private func resize(_ corner: Int, _ picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let start = dragStart ?? frame
                dragStart = start
                dragging = true
                let fixed = point(of: 3 - corner, in: start)
                let moved = point(of: corner, in: start)
                let towardsX: CGFloat = corner % 2 == 0 ? -1 : 1
                let towardsY: CGFloat = corner < 2 ? -1 : 1
                let wanted = max(
                    (moved.x + drag.translation.width - fixed.x) * towardsX,
                    (moved.y + drag.translation.height - fixed.y) * towardsY)
                let room = min(
                    towardsX > 0 ? picture.maxX - fixed.x : fixed.x - picture.minX,
                    towardsY > 0 ? picture.maxY - fixed.y : fixed.y - picture.minY)
                let side = min(max(wanted, min(Metrics.cropMinimum, room)), room)
                frame = CGRect(
                    x: towardsX > 0 ? fixed.x : fixed.x - side, y: towardsY > 0 ? fixed.y : fixed.y - side,
                    width: side, height: side)
            }
            .onEnded { _ in
                dragStart = nil
                dragging = false
            }
    }

    /// A trackpad scroll moves the picture, a wheel zooms it.
    private func scrolled(_ event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            keepCovered(center: CGPoint(x: center.x + event.scrollingDeltaX, y: center.y + event.scrollingDeltaY))
        } else {
            setZoom(zoom * (1 + event.scrollingDeltaY * 0.1))
        }
    }

    /// The zoom between 1x and the largest, about the center of the circle.
    private func setZoom(_ wanted: CGFloat) {
        let next = min(max(wanted, 1), Metrics.cropMaxZoom)
        let ratio = next / zoom
        let moved = CGPoint(x: frame.midX + (center.x - frame.midX) * ratio, y: frame.midY + (center.y - frame.midY) * ratio)
        zoom = next
        center = moved
        keepCovered(zoom: next, center: moved)
    }

    /// The circle no larger than the picture, and the picture moved so that it covers it.
    private func keepCovered(zoom: CGFloat? = nil, center wanted: CGPoint? = nil) {
        let size = pictureRect(image ?? source, zoom: zoom).size
        let side = min(frame.width, size.width, size.height)
        let circle = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        let middle = wanted ?? center
        frame = circle
        center = CGPoint(
            x: min(max(middle.x, circle.maxX - size.width / 2), circle.minX + size.width / 2),
            y: min(max(middle.y, circle.maxY - size.height / 2), circle.minY + size.height / 2))
    }

    /// The circle's square in the pixels of the picture, origin at the top left.
    private func cropInPixels(_ image: CGImage) -> CGRect {
        let picture = pictureRect(image)
        let scale = CGFloat(image.width) / picture.width
        return CGRect(
            x: (frame.minX - picture.minX) * scale, y: (frame.minY - picture.minY) * scale,
            width: frame.width * scale, height: frame.height * scale)
    }
}

/// The photo of a contact over the whole window, from the contact panel (DESIGN.md 16).
struct AvatarViewer: View {
    let model: AppModel
    let photo: ProfilePhoto

    var body: some View {
        GeometryReader { window in
            ZStack {
                Color.viewerBg
                if let image = AvatarPictures.image(photo, side: 1024) {
                    let fit = min(1, window.size.width / image.size.width, (window.size.height - 80) / image.size.height)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: image.size.width * fit, height: image.size.height * fit)
                }
                IconButton(
                    symbol: "xmark", size: 20, label: "Close", color: .viewerControlFg, hoverColor: .viewerControlFg, side: 48
                ) { model.avatarViewer = nil }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, Metrics.titleStrip + 8)
                .padding(.trailing, 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.avatarViewer = nil }
        }
    }
}
