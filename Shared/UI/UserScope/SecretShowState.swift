import AgentsKitCore
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Reveal and Copy on Settings ▸ You ▸ Secrets (#5112, #5115;
/// `specs/5112-view-copy-secrets-accounts/wireframes.md`, sections 1 to 6). The window asks the
/// control plane for its own sealed copy (`user/sealedSecret`, which writes the audit entry
/// first), opens it with its own key, and shows or copies the value. It keeps the value only
/// while it shows: one at a time, for 30 seconds, and never on disk. The web page does the same
/// in `Web/src/views/UserScope.tsx`. The Remote does not have it (tier Mac + web): it gives no
/// `key`, so the pane draws no Reveal or Copy.
@MainActor @Observable
final class SecretShowState {
    /// The value shown, and when it hides.
    struct Shown: Equatable {
        var name: String
        var version: Int
        var value: String
        /// The card's parts, when it is a card (#3531).
        var card: CardSecret?
        var until: Date
    }

    /// What was just copied: the row, and a card's part.
    struct Copied: Equatable {
        var name: String
        var part: DaemonAPI.UserSealedSecretRequest.Part?
    }

    /// This client's key and id (`ControlConfig.sealing`), or nil when it has none.
    @ObservationIgnored let key: () -> (key: DeviceKey, client: UUID)?

    private(set) var shown: Shown?
    private(set) var copied: Copied?
    /// The row whose copy is being fetched, for its spinner.
    private(set) var fetching: String?
    /// Why a row could not show or copy, by name.
    private(set) var problems: [String: String] = [:]
    /// The rows the control plane keeps no copy of for this app yet.
    private(set) var noCopy: Set<String> = []
    /// The person, for the associated data: asked once.
    @ObservationIgnored private var person: String?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    #if os(macOS)
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    #endif

    init(key: @escaping () -> (key: DeviceKey, client: UUID)?) {
        self.key = key
    }

    /// Reveal, or Hide when it shows already. Reveal on another row hides the first.
    func toggle(_ row: DaemonAPI.UserSecretRow, on control: DaemonClient?) async {
        if shown?.name == row.name {
            hide()
            return
        }
        hide()
        guard let value = await fetch(row, purpose: .reveal, part: nil, on: control) else { return }
        shown = Shown(name: row.name, version: row.version ?? 0, value: value, card: row.isCard ? CardSecret(value: value) : nil,
                      until: Date().addingTimeInterval(TimeInterval(UserScopeWords.shownSeconds)))
        let name = row.name
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UserScopeWords.shownSeconds))
            guard !Task.isCancelled, self?.shown?.name == name else { return }
            self?.hide()
        }
    }

    /// Copy: the value, or a card's part (the row's Copy is the card number). It does not reveal.
    func copy(_ row: DaemonAPI.UserSecretRow, part: DaemonAPI.UserSealedSecretRequest.Part? = nil, on control: DaemonClient?) async {
        let part = part ?? (row.isCard ? .number : nil)
        guard let value = await fetch(row, purpose: .copy, part: part, on: control) else { return }
        let text: String
        if row.isCard {
            guard let card = CardSecret(value: value) else {
                problems[row.name] = UserScopeWords.didNotOpen
                return
            }
            text = card.part(part ?? .number)
        } else {
            text = value
        }
        put(text)
        // A card's own row copies the number; the line names the part only for a part's own Copy.
        copied = Copied(name: row.name, part: shown?.name == row.name ? part : nil)
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UserScopeWords.copiedSeconds))
            guard !Task.isCancelled else { return }
            self?.copied = nil
        }
    }

    /// Drops the value shown: Hide, the 30 seconds, the pane closing, the window going to the back.
    func hide() {
        hideTask?.cancel()
        hideTask = nil
        shown = nil
    }

    /// The secrets were read again: a value shown hides when its secret changed or went.
    func secretsChanged(_ rows: [DaemonAPI.UserSecretRow]) {
        // A replaced secret is sealed again, to this app too: ask again.
        noCopy = noCopy.filter { name in rows.contains { $0.name == name } }
        guard let shown else { return }
        if rows.first(where: { $0.name == shown.name })?.version ?? -1 != shown.version { hide() }
    }

    private func fetch(_ row: DaemonAPI.UserSecretRow, purpose: DaemonAPI.UserSealedSecretRequest.Purpose,
                       part: DaemonAPI.UserSealedSecretRequest.Part?, on control: DaemonClient?) async -> String? {
        guard let control else {
            problems[row.name] = "The control plane can’t be reached."
            return nil
        }
        guard let (key, client) = key() else {
            problems[row.name] = UserScopeWords.noCopyYet
            return nil
        }
        fetching = row.name
        defer { fetching = nil }
        problems[row.name] = nil
        do {
            if person == nil {
                person = try await control.call(DaemonAPI.Method.userSecretRecipients, DaemonAPI.Empty(),
                                                returning: DaemonAPI.SealRecipients.self).user
            }
            let sealed = try await control.call(DaemonAPI.Method.userSealedSecret,
                                                DaemonAPI.UserSealedSecretRequest(name: row.name, purpose: purpose, part: part),
                                                returning: DaemonAPI.UserSealedSecret.self)
            do {
                return try ClientSealing.open(sealed, user: person ?? "", with: key, client: client)
            } catch {
                problems[row.name] = UserScopeWords.didNotOpen
                return nil
            }
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.noClientCopy {
            noCopy.insert(row.name)
            return nil
        } catch let error as JSONRPCError where error.code == JSONRPCError.methodNotFound {
            problems[row.name] = UserScopeWords.revealNeedsNewerPlane
            return nil
        } catch {
            problems[row.name] = UserScopeWords.refusal(error)
            return nil
        }
    }

    /// On the general pasteboard, marked concealed so clipboard managers that obey it keep no
    /// copy, and cleared after 90 seconds when it still holds this value.
    private func put(_ text: String) {
        #if os(macOS)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = board.changeCount
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(UserScopeWords.clipboardSeconds))
            guard !Task.isCancelled, NSPasteboard.general.changeCount == count else { return }
            NSPasteboard.general.clearContents()
        }
        #endif
    }
}
