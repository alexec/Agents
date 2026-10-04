import AgentsKitCore
import Foundation
import Observation

/// The credentials this window lends. Settings shows Gemini's under Agent Runtimes
/// (046); a server is lent the same key only while an agent runs there (043, US2).
///
/// A thin face on `CredentialStore`: the records to draw, the check in flight, and what the
/// last save found. The secret itself is read from the Keychain only when it is saved,
/// checked or lent, and never kept here.
@MainActor
@Observable
final class ServerCredentials {
    /// The runtimes that take a credential from Settings, in the catalog's order.
    static let runtimes = RuntimeCatalog.builtIn.map(\.id).filter { !CredentialKind.kinds(for: $0).isEmpty }

    enum Checking: Equatable {
        case idle
        case checking
        case answered(CredentialCheck.Answer)
    }

    private(set) var records: [String: CredentialStore.Record] = [:]
    /// What to say while `credentials.json` cannot be read (#205): nothing is saved or
    /// removed over it, and no record shows, though the Keychain still has the secrets.
    var unreadableNote: String? {
        unreadable ? "This Mac's credentials file could not be read, so no credential can be saved or removed until it can. Nothing in it or in the Keychain was changed." : nil
    }
    private(set) var unreadable = false
    private(set) var checking: [String: Checking] = [:]

    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let checker: CredentialCheck

    init(locations: StoreLocations, checker: CredentialCheck = CredentialCheck()) {
        // The container is the window's own folder.
        store = CredentialStore(locations: locations, fileRoot: nil)
        self.checker = checker
        // A Claude token from before 056 (or 047's OpenAI key) is lent to nothing now.
        // Kept while 056 is after the #58 cut-off (051).
        store.forgetKindsNoLongerTaken()
        refresh()
    }

    private func refresh() {
        records = store.records()
        unreadable = store.isUnreadable
    }

    func record(_ runtimeID: String) -> CredentialStore.Record? { records[runtimeID] }

    /// False for text that is not a credential for `runtimeID`, with no side effect.
    func save(_ text: String, for runtimeID: String) async -> Bool {
        guard let secret = Secret(text), secret.kind.runtimeID == runtimeID else { return false }
        do {
            try store.save(secret, for: runtimeID)
        } catch {
            checking[runtimeID] = .answered(.cannotCheck(error is CredentialStore.Unreadable
                ? "It was not saved: \(error)." : "The Keychain would not keep it (\(error))."))
            refresh()
            return true
        }
        refresh()
        await check(runtimeID)
        return true
    }

    func check(_ runtimeID: String) async {
        guard let secret = store.secret(for: runtimeID) else { return }
        checking[runtimeID] = .checking
        let answer = await checker.check(secret)
        switch answer {
        case .works: try? store.markWorked(runtimeID)
        case .refused: try? store.markRefused(runtimeID)
        case .cannotCheck: break
        }
        refresh()
        checking[runtimeID] = .answered(answer)
    }

    func remove(_ runtimeID: String) {
        try? store.remove(runtimeID)
        refresh()
        checking[runtimeID] = nil
    }

    /// For lending, and only for lending (043, R6).
    func secretToLend(_ runtimeID: String) -> Secret? { store.secret(for: runtimeID) }

    func markWorked(_ runtimeID: String) {
        try? store.markWorked(runtimeID)
        refresh()
    }

    func markRefused(_ runtimeID: String) {
        try? store.markRefused(runtimeID)
        refresh()
    }
}
