import AgentsKit
import Foundation

/// A server asked for a credential this window has none of (043, FR-015): asked of the
/// person in place, before the agent starts, and answered once.
struct TokenAsk: Identifiable {
    let id = UUID()
    let runtimeID: String
    let host: HostID
    let label: String
    let answer: CheckedContinuation<Bool, Never>
}

extension AppModel {
    /// What a server may be lent from here, sent on every connect (043). Names only.
    func credentialOffer(_ id: HostID) -> DaemonAPI.CredentialsOffer {
        let ownOnly = hosts.host(id)?.ownSignInOnly ?? false
        let runtimes = ownOnly ? [] : ServerCredentials.runtimes.filter { credentials.record($0) != nil }
        return DaemonAPI.CredentialsOffer(runtimes: runtimes, ownSignInOnly: ownOnly)
    }

    /// A server's daemon wants a credential to start a runtime (043, R6). Lends the one in
    /// Settings; with none, asks the person first. True when it lent one, and the call
    /// that was refused is then sent again.
    func answerCredentialWanted(_ wanted: DaemonAPI.CredentialWanted, on id: HostID) async -> Bool {
        guard id != .mac, !(hosts.host(id)?.ownSignInOnly ?? false) else { return false }
        if credentials.secretToLend(wanted.runtime) == nil {
            let saved = await withCheckedContinuation { answer in
                tokenAsk = TokenAsk(runtimeID: wanted.runtime, host: id, label: hosts.label(id), answer: answer)
            }
            guard saved else { return false }
        }
        guard let secret = credentials.secretToLend(wanted.runtime) else { return false }
        // The offer made on connect did not name a runtime there was no credential for.
        if !wanted.offered { await hosts.offerCredentials(id) }
        return await hosts.lend(id, runtime: wanted.runtime, secret)
    }

    /// The person answered the ask: pasted and saved (true), or cancelled.
    func finishTokenAsk(saved: Bool) {
        guard let ask = tokenAsk else { return }
        tokenAsk = nil
        ask.answer.resume(returning: saved)
    }
}
