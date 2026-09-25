import AgentsKitCore
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What goes with the first prompt: a picture from the library or a file from Files
/// (029). Everything goes by value — a picture shrunk, text as its contents — because a
/// file on this phone is a path the Mac cannot open. The rules are `PhoneAttachment`'s.
struct AttachButton: View {
    @Binding var attachments: [Attachment]
    /// Why something picked could not be attached, said where it was picked.
    @Binding var refusal: String?

    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingPhotos = false
    @State private var choosingFiles = false

    var body: some View {
        Menu {
            Button { choosingPhotos = true } label: { Label("Photo Library", systemImage: "photo") }
            Button { choosingFiles = true } label: { Label("Files", systemImage: "folder") }
            // A copied screenshot is the picture most often meant. There is no paste
            // into a text field for pictures on a phone, so it is offered here (033).
            if UIPasteboard.general.hasImages {
                Button { pastePicture() } label: { Label("Paste Picture", systemImage: "doc.on.clipboard") }
            }
        } label: {
            Image(systemName: "paperclip")
                .appText(.reading).fontWeight(.semibold)
                .frame(width: 22, height: 22)
        }
        // The Mac's paper circle, the size of dictate and send beside it (033).
        .menuStyle(.button)
        .buttonStyle(.paper)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Attach")
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, matching: .images)
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { take(url) }
        }
        .onChange(of: photos) {
            let picked = photos
            photos = []
            Task { for item in picked { await take(item) } }
        }
    }

    private func pastePicture() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() else {
            refusal = "There is no picture to paste."
            return
        }
        add(PhoneAttachment.picture(data, name: "Pasted picture"))
    }

    private func take(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            refusal = "That picture could not be read."
            return
        }
        let name = item.itemIdentifier.map { "Photo \($0.prefix(6))" } ?? "Photo"
        add(PhoneAttachment.picture(data, name: name))
    }

    private func take(_ url: URL) {
        let opened = url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            refusal = "\(url.lastPathComponent) could not be read."
            return
        }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        add(PhoneAttachment.file(data, name: url.lastPathComponent, type: type))
    }

    private func add(_ result: Result<Attachment, PhoneAttachment.Refusal>) {
        switch result {
        case .success(let attachment):
            attachments.append(attachment)
            refusal = nil
        case .failure(let refused):
            refusal = refused.sentence
        }
    }
}

/// What is attached, each removable, each saying under it why this runtime will not
/// take it when it will not.
struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]
    let capabilities: ACP.PromptCapabilities

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: attachment))
                                .accessibilityHidden(true)
                            // Two lines before it gives up, so a long name at the largest
                            // text size still says which file it is.
                            Text(attachment.displayName).lineLimit(2)
                                .accessibilityLabel(kind(of: attachment) + ", " + attachment.displayName)
                            Button {
                                attachments.removeAll { $0.id == attachment.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(attachment.displayName)")
                        }
                        .appText(.supporting)
                        if let refusal = PhoneAttachment.refusal(for: attachment, from: capabilities) {
                            Text(refusal).appText(.fine).tinted(.failure)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func kind(of attachment: Attachment) -> String {
        if case .image = attachment.block { return "Picture" }
        return "File"
    }

    private func icon(for attachment: Attachment) -> String {
        if case .image = attachment.block { return "photo" }
        return "doc.text"
    }
}
