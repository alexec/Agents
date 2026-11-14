import AgentsKitCore
import UIKit
import UniformTypeIdentifiers

/// Share ▸ Agent Loops (#4915): what another app shares goes to the Remote's New session.
///
/// The extension does no more than it must, inside a share extension's small memory limit:
/// it turns each item into what the paperclip would attach (`SharedItems`, by
/// `PhoneAttachment`'s rules), leaves it in the app group (`SharedInbox`), and opens the
/// Remote at `agents://start`. It has no link to the Mac, no sign-in and no folder list: the
/// person picks the folder and the runtime on New session, with the chips they know.
///
/// iOS gives a share extension no supported way to open its app, so the save is what always
/// works, and the open is a shortcut on top of it. When the open does not happen, the sheet
/// says so, and the Remote takes the items the next time it comes to the front.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Sending to Agent Loops…"
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.layoutMarginsGuide.trailingAnchor),
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await share(providers) }
    }

    private func share(_ providers: sending [NSItemProvider]) async {
        let items = await ShareReader.read(providers)
        guard SharedInbox.add(items) else {
            finish(saying: items.isEmpty ? "There was nothing here Agent Loops can take." : "Agent Loops could not save this.")
            return
        }
        if await openRemote() {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            finish(saying: "Saved. Open Agent Loops to finish.")
        }
    }

    /// Said for a moment, then the sheet goes.
    private func finish(saying words: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = words
        UIAccessibility.post(notification: .announcement, argument: words)
        Task {
            try? await Task.sleep(for: .seconds(2))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// The Remote, through the responder chain: the application an extension's view is
    /// hosted in is on it. Whether it opened.
    private func openRemote() async -> Bool {
        var responder: UIResponder? = self
        while let next = responder {
            if let application = next as? UIApplication {
                return await application.open(SharedInbox.startURL)
            }
            responder = next.next
        }
        return false
    }
}

/// One item shared, read into `SharedItems` by the paperclip's rules.
enum ShareReader {
    /// One at a time, in the order shared: a picture is read and shrunk, and let go of,
    /// before the next is read.
    static func read(_ providers: sending [NSItemProvider]) async -> SharedItems {
        var items = SharedItems()
        for provider in providers { await read(provider, into: &items) }
        return items
    }

    private static func read(_ provider: NSItemProvider, into items: inout SharedItems) async {
        let name = provider.suggestedName ?? "Shared item"
        // A picture first: Photos and a screenshot's preview offer a file too.
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            guard let data = await data(of: .image, from: provider) else { return items.unreadable(name) }
            if items.refuse(name: name, size: data.count, type: .image) { return }
            items.add(picture: data, name: name)
        } else if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                  provider.canLoadObject(ofClass: URL.self) {
            guard let url = await object(URL.self, from: provider) else { return items.unreadable(name) }
            items.add(text: url.absoluteString)
        } else if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                  provider.canLoadObject(ofClass: String.self) {
            guard let text = await object(String.self, from: provider) else { return items.unreadable(name) }
            items.add(text: text)
        } else if let type = provider.registeredContentTypes.first {
            // A file: one the paperclip takes, or refuses in its words.
            items.append(await file(of: type, from: provider, name: name))
        }
    }

    /// Its size is looked at before it is read (#930), as the paperclip's Files does. Read
    /// in the handler: the copy the system makes is gone once it returns.
    private static func file(of type: UTType, from provider: NSItemProvider, name: String) async -> SharedItems {
        await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(for: type) { url, _, _ in
                var items = SharedItems()
                guard let url else {
                    items.unreadable(name)
                    return done.resume(returning: items)
                }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let type = values?.contentType ?? type
                if !items.refuse(name: name, size: values?.fileSize ?? 0, type: type) {
                    if let data = try? Data(contentsOf: url) {
                        items.add(file: data, name: name, type: type)
                    } else {
                        items.unreadable(name)
                    }
                }
                done.resume(returning: items)
            }
        }
    }

    private static func object<T: _ObjectiveCBridgeable & Sendable>(_ kind: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { done in
            _ = provider.loadObject(ofClass: kind) { object, _ in done.resume(returning: object) }
        }
    }

    private static func data(of type: UTType, from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { done in
            _ = provider.loadDataRepresentation(for: type) { data, _ in done.resume(returning: data) }
        }
    }
}
