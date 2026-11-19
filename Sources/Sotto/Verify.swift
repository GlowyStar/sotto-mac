import SottoCore
import SwiftUI

/// The mark of a verified contact after its name (DESIGN.md 21.1).
struct VerifiedMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size))
            .symbolRenderingMode(.palette)
            .foregroundStyle(Color.verifiedFg, Color.verifiedBg)
            .accessibilityLabel("Verified")
            .help("Verified: you compared the safety number")
    }
}

/// The safety number of a contact, its QR code and the verified mark (DESIGN.md 21.3).
struct VerifyBox: View {
    let model: AppModel
    let contact: Contact

    var body: some View {
        ModalBox(title: "Verify safety number", wide: true) {
            // Scrolls only when the window is too low for the whole box.
            ViewThatFits(in: .vertical) {
                details
                ScrollView { details }
            }
        } buttons: {
            BoxButton(title: contact.verified ? "Clear verification" : "Mark as verified") {
                model.setVerified(!contact.verified, contact.id)
            }
            BoxButton(title: "Close") { model.modal = nil }.keyboardShortcut(.defaultAction)
        }
    }

    private var details: some View {
        VStack(spacing: 0) {
            let number = model.safetyNumber(contact.id)
            QRPlate(text: number?.qrPayload ?? "", label: "QR code of the safety number with \(contact.name)")
            if let number {
                IDBlock(id: number.digits, group: SafetyNumber.groupDigits).padding(.top, 16)
            }
            Text(
                "Compare these numbers with the ones on the device of \(contact.name), in person or over a channel you trust. "
                    + "When they are the same, mark \(contact.name) as verified."
            )
            .font(Fonts.label)
            .lineSpacing(2)
            .foregroundStyle(Color.windowSubFg)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
            if contact.verified {
                HStack(spacing: 6) {
                    VerifiedMark(size: 14)
                    Text("\(contact.name) is verified").font(Fonts.sectionLabel).foregroundStyle(Color.accentText)
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The warning of a chat whose contact's identity signed a key that was refused
/// (DESIGN.md 21.4): it stays until the user closes it.
struct RefusedKeyBanner: View {
    let model: AppModel
    let contact: Contact

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.danger)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Another key of \(contact.name) was refused")
                    .font(Fonts.headerTitle)
                    .foregroundStyle(Color.danger)
                Text(meaning).font(Fonts.label).foregroundStyle(Color.windowFg)
                Text(
                    "Ask \(contact.name) in person or over a channel you trust. If they did not do it, their identity is "
                        + "lost: ask for a new id, add it, and delete this contact."
                )
                .font(Fonts.label)
                .foregroundStyle(Color.windowFg)
            }
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: Metrics.bannerClose))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.composeBg)
        .overlay(alignment: .topTrailing) {
            IconButton(
                symbol: "xmark", size: 14, label: "Close the warning", color: .replyCancelFg, hoverColor: .replyCancelFgOver,
                side: Metrics.bannerClose
            ) { model.dismissRefusedKey(contact.id) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var meaning: String {
        let mark = contact.verified ? " The verified mark stays: it is about the same identity key." : ""
        return "Someone with the secret key of the identity of \(contact.name) signed a second encryption key, and Sotto "
            + "refused it. Someone else may have that identity. The safety number does not change, so it cannot show this."
            + mark
    }
}
