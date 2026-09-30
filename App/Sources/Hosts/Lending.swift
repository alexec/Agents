import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
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

/// A server asked for a sign-in this Mac relays (058, T091): asked of the person, once per
/// server and runtime, before the control plane lets the server reach this Mac's relay.
struct SignInLendAsk: Identifiable {
    let id = UUID()
    let runtimeName: String
    let label: String
    let answer: CheckedContinuation<Bool, Never>
}

extension AppModel {
    /// A server of the control plane wants a sign-in this Mac relays (T091). Asks the
    /// person the first time; then the control plane lets the server tunnel to this Mac's
    /// host, which relays the sign-in, and the server is told where its gate goes. The
    /// token never leaves this Mac. Nil when this is not such a case.
    func relaySignInThroughControl(_ wanted: DaemonAPI.CredentialWanted, to id: HostID) async -> Bool? {
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

    /// The person answered the lend ask.
    func finishSignInLendAsk(allowed: Bool) {
        guard let ask = signInLendAsk else { return }
        signInLendAsk = nil
        ask.answer.resume(returning: allowed)
    }

    /// What a server may be lent from here, sent on every connect (043). Names only.
    func credentialOffer(_ id: HostID) -> DaemonAPI.CredentialsOffer {
        let ownOnly = hosts.host(id)?.ownSignInOnly ?? false
        let runtimes = ownOnly ? [] : ServerCredentials.runtimes.filter { credentials.record($0) != nil }
        // What this Mac would relay and cannot now, so the server can say why (056).
        var notRelayed: [String: DaemonAPI.SignInWanted.Reason] = [:]
        #if !AGENTS_STORE
        // The store window relays no sign-in: Agents Host does, on its Mac (T091).
        if !ownOnly {
            for runtimeID in SignInRelays.relayed {
                if let why = SignInRelays.whyNotRelayed(runtimeID) { notRelayed[runtimeID] = why }
            }
        }
        #endif
        return DaemonAPI.CredentialsOffer(runtimes: runtimes, ownSignInOnly: ownOnly,
                                          notRelayed: notRelayed.isEmpty ? nil : notRelayed)
    }

    /// A server's daemon wants a credential to start a runtime (043, R6). Lends the one in
    /// Settings; with none, asks the person first. True when it lent one, and the call
    /// that was refused is then sent again.
    func answerCredentialWanted(_ wanted: DaemonAPI.CredentialWanted, on id: HostID) async -> Bool {
        guard id != .mac, !(hosts.host(id)?.ownSignInOnly ?? false) else { return false }
        // A sign-in this Mac relays, to a server of the control plane (T091).
        if let relayed = await relaySignInThroughControl(wanted, to: id) { return relayed }
        if credentials.secretToLend(wanted.runtime) == nil {
            let saved = await withCheckedContinuation { answer in
                tokenAsk = TokenAsk(runtimeID: wanted.runtime, host: id, label: hosts.label(id), answer: answer)
            }
            guard saved else { return false }
        }
        guard let secret = credentials.secretToLend(wanted.runtime) else { return false }
        // A host the control plane reaches is lent on its channel (058, FR-020). One
        // this window still reaches over its own ssh is lent the way it always was.
        if let lent = await lendThroughControl(id, runtime: wanted.runtime, secret: secret, offered: wanted.offered) {
            return lent
        }
        #if AGENTS_STORE
        return false
        #else
        // The offer made on connect did not name a runtime there was no credential for.
        if !wanted.offered { await hosts.offerCredentials(id) }
        return await hosts.lend(id, runtime: wanted.runtime, secret)
        #endif
    }

    /// What this Mac's own agents are lent (046, D3): Gemini's key, which is the only way
    /// into Gemini for an individual. Offered then lent on every connect and whenever a key
    /// is saved or removed; an offer without it tells the daemon to stop lending it.
    func lendToThisMac() async {
        let runtimes = ServerCredentials.runtimes.filter { id in
            credentials.record(id) != nil && CredentialKind.kinds(for: id).contains(where: \.isLentOnTheMac)
        }
        _ = try? await client(for: .mac).call(DaemonAPI.Method.credentialsOffer,
                                   DaemonAPI.CredentialsOffer(runtimes: runtimes, ownSignInOnly: false))
        for id in runtimes {
            guard let secret = credentials.secretToLend(id) else { continue }
            _ = try? await client(for: .mac).call(DaemonAPI.Method.credentialsLend, DaemonAPI.CredentialsLend(runtime: id, secret: secret))
        }
    }

    /// This Mac's daemon wants a key it was not lent (a start raced the connect's lend, or
    /// the key was just added): lend what Settings has. With none, the start's refusal says
    /// where to add one.
    func answerMacCredentialWanted(_ wanted: DaemonAPI.CredentialWanted) async -> Bool {
        guard credentials.secretToLend(wanted.runtime) != nil else { return false }
        await lendToThisMac()
        return true
    }

    /// The person answered the ask: pasted and saved (true), or cancelled.
    func finishTokenAsk(saved: Bool) {
        guard let ask = tokenAsk else { return }
        tokenAsk = nil
        ask.answer.resume(returning: saved)
    }

    /// A server spent money: a model answered, so whatever sign-in it was lent worked
    /// (043, FR-011). Gemini's key is the only one lent since 056.
    func noteServerSpent(_ id: HostID) {
        guard id != .mac, !(hosts.host(id)?.ownSignInOnly ?? false),
              let record = credentials.record(RuntimeCatalog.gemini.id),
              (record.lastWorked ?? .distantPast) < Date().addingTimeInterval(-60) else { return }
        credentials.markWorked(RuntimeCatalog.gemini.id)
    }
}
