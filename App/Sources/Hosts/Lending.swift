import AgentsKitCore
import Foundation

/// A server asked for a sign-in this Mac relays (058, T091): asked of the person, once per
/// server and runtime, before the control plane lets the server reach this Mac's relay.
struct SignInLendAsk: Identifiable {
    let id = UUID()
    let runtimeName: String
    let label: String
    let answer: CheckedContinuation<Bool, Never>
}

extension AppModel {
    /// The first git ask no window here has answered yet (#1122). Any client may answer it;
    /// the control plane takes the first answer.
    var gitLendAsk: GitLendAsk? {
        GitLendAsk.first(in: controlPlaneHosts ?? [], thisMac: thisMacHostID, answered: gitAsksAnswered)
    }

    /// Allow or Don’t Allow (#1122): said to the control plane, which answers the waiting git.
    func answerGitLend(_ ask: GitLendAsk, allowed: Bool) {
        gitAsksAnswered.insert(ask.id)
        lendGit(host: ask.host, from: ask.from, server: ask.server, allowed: allowed)
    }

    /// Settings ▸ Machines: a host stops using a Mac's git access for a server.
    func lendGit(host: MachineRef, from: MachineRef, server: String, allowed: Bool) {
        guard let control = controlPlaneClient() else { return }
        Task {
            defer { Task { await control.disconnect() } }
            try? await control.connect(startIfNeeded: false, timeout: .seconds(5))
            _ = try? await control.call(DaemonAPI.Method.hostsLendGit,
                                        DaemonAPI.LendGit(host: host, from: from, server: server, allowed: allowed))
        }
    }

    /// A server of the control plane wants a sign-in this Mac relays (T091). Asks the
    /// person the first time; then the control plane lets the server tunnel to this Mac's
    /// host, which relays the sign-in, and the server is told where its gate goes. The
    /// token never leaves this Mac. Nil when this is not such a case.
    func relaySignInThroughControl(_ wanted: DaemonAPI.CredentialWanted, to id: MachineRef) async -> Bool? {
        guard reachesThroughControl(id), ToolPolicyCatalog.policy(for: wanted.runtime).relay != nil,
              let lender = thisMacHostID, lender != id, let control = controlPlaneClient() else { return nil }
        defer { Task { await control.disconnect() } }
        let allowed = controlPlaneHosts?.first { $0.id == id }?.signInFrom?[wanted.runtime] == lender
        if !allowed {
            let name = RuntimeCatalog.runtime(id: wanted.runtime)?.name ?? wanted.runtime
            let yes = await withCheckedContinuation { answer in
                signInLendAsk = SignInLendAsk(runtimeName: name, label: hosts.label(id), answer: answer)
            }
            guard yes else { return false }
            do {
                try await control.connect(startIfNeeded: false, timeout: .seconds(5))
                _ = try await control.call(DaemonAPI.Method.hostsLendSignIn,
                                           DaemonAPI.LendSignIn(host: id, from: lender, runtime: wanted.runtime, allowed: true))
            } catch {
                return false
            }
        }
        do {
            let grant = try await client(for: lender).call(DaemonAPI.Method.relayGrant,
                                                          DaemonAPI.RelayGrantRequest(runtime: wanted.runtime),
                                                          returning: DaemonAPI.RelayGrantReply.self)
            _ = try await client(for: id).call(DaemonAPI.Method.relayOffer, DaemonAPI.RelayOffer(
                runtime: wanted.runtime, socketPath: "tunnel", caCertificate: grant.caCertificate, standIn: grant.standIn))
            return true
        } catch {
            return false
        }
    }

    /// The person answered the lend ask: the one the window showed, which a second ask
    /// may since have replaced (#101). The second is still asked. Once per ask: its
    /// answer is a continuation.
    func finishSignInLendAsk(_ ask: SignInLendAsk, allowed: Bool) {
        if signInLendAsk?.id == ask.id { signInLendAsk = nil }
        ask.answer.resume(returning: allowed)
    }

    /// What a server may be lent from here, sent on every connect (043). Names only.
    func credentialOffer(_ id: MachineRef) -> DaemonAPI.CredentialsOffer {
        let ownOnly = hosts.host(id)?.ownSignInOnly ?? false
        let runtimes = ownOnly ? [] : ServerCredentials.runtimes.filter { credentials.record($0) != nil }
        // The window relays no sign-in and lends no sign-in file: Agents Host does, on its
        // Mac (T091).
        return DaemonAPI.CredentialsOffer(runtimes: runtimes, ownSignInOnly: ownOnly, notRelayed: nil, signIns: nil)
    }

    /// A server's daemon wants a credential to start a runtime (043, R6): a sign-in this
    /// Mac relays, to a server of the control plane (T091). No runtime takes a pasted key
    /// now that Gemini, the last one that did, is retired (#3043), so there is no other way
    /// to answer one.
    func answerCredentialWanted(_ wanted: DaemonAPI.CredentialWanted, on id: MachineRef) async -> Bool {
        guard id != .mac, !(hosts.host(id)?.ownSignInOnly ?? false) else { return false }
        return await relaySignInThroughControl(wanted, to: id) ?? false
    }

    /// What this Mac's own agents are lent (046, D3): no runtime takes a pasted key now
    /// that Gemini, the last one that did, is retired (#3043), so this always offers none.
    /// Offered then lent on every connect and whenever a key is saved or removed; an offer
    /// without it tells the daemon to stop lending it.
    func lendToThisMac() async {
        let runtimes = ServerCredentials.runtimes.filter { id in
            credentials.record(id) != nil && CredentialKind.kinds(for: id).contains(where: \.isLentOnTheMac)
        }
        _ = try? await client(for: .mac).call(DaemonAPI.Method.credentialsOffer,
                                   DaemonAPI.CredentialsOffer(runtimes: runtimes, ownSignInOnly: false))
    }

    /// This Mac's daemon wants a key it was not lent (a start raced the connect's lend, or
    /// the key was just added): lend what Settings has. With none, the start's refusal says
    /// where to add one.
    func answerMacCredentialWanted(_ wanted: DaemonAPI.CredentialWanted) async -> Bool {
        guard credentials.secretToLend(wanted.runtime) != nil else { return false }
        await lendToThisMac()
        return true
    }
}
