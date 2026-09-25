import AgentsKit
import Foundation
import Observation

/// The credentials this window lends to servers, as Settings shows them (043, US2).
///
/// A thin face on `CredentialStore`: the records to draw, the check in flight, and what the
/// last save found. The secret itself is read from the Keychain only when it is saved,
/// checked or lent, and never kept here.
@MainActor
@Observable
final class ServerCredentials {
    /// The runtimes the app can install on a server, and so take a credential for (D3).
    static let runtimes = ["claude"]

    enum Checking: Equatable {
        case idle
        case checking
        case answered(CredentialCheck.Answer)
    }

    private(set) var records: [String: CredentialStore.Record] = [:]
    private(set) var checking: [String: Checking] = [:]

    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let checker: CredentialCheck

    init(locations: StoreLocations, checker: CredentialCheck = CredentialCheck()) {
        store = CredentialStore(locations: locations)
        self.checker = checker
        records = store.records()
    }

    func record(_ runtimeID: String) -> CredentialStore.Record? { records[runtimeID] }

    /// Nil for text that is not a Claude credential, with no side effect.
    func save(_ text: String, for runtimeID: String) async -> Bool {
        guard let secret = Secret(text) else { return false }
        do {
            try store.save(secret, for: runtimeID)
        } catch {
            checking[runtimeID] = .answered(.cannotCheck("The Keychain would not keep it (\(error))."))
            return true
        }
        records = store.records()
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
        records = store.records()
        checking[runtimeID] = .answered(answer)
    }

    func remove(_ runtimeID: String) {
        try? store.remove(runtimeID)
        records = store.records()
        checking[runtimeID] = nil
    }

    /// For lending, and only for lending (043, R6).
    func secretToLend(_ runtimeID: String) -> Secret? { store.secret(for: runtimeID) }

    func markWorked(_ runtimeID: String) {
        try? store.markWorked(runtimeID)
        records = store.records()
    }

    func markRefused(_ runtimeID: String) {
        try? store.markRefused(runtimeID)
        records = store.records()
    }
}
