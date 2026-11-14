import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: The Mac's runtimes (029)

    /// The accounts the start page's runtime offers beyond its own sign-in: the Mac's, so
    /// none for a server's folder. The picker shows only when there is one.
    var startAccounts: [AccountProfile] { startAccountChoices?.accounts ?? [] }

    var startAccountChoices: AccountChoices? {
        guard startHost == .mac, let startRuntimeID, startRuntimeID != LevelWords.autoID else { return nil }
        return AccountChoices(runtimeID: startRuntimeID, profiles: accountProfiles, policy: policyState?.policy)
    }

    /// Why a session on the Mac can no longer reach the model on its account (#999): the
    /// organisation removed it, or its policy refuses it now. Nil when it can.
    func accountMoveReason(_ agent: Agent) -> String? {
        guard agent.host == .mac, agent.state != .archived else { return nil }
        return AccountChoices(runtimeID: agent.runtimeID, profiles: accountProfiles, policy: policyState?.policy)
            .moveReason(accountID: agent.accountID, loaded: accountProfilesRead)
    }

    /// **Reaches the Model By** (#999): one of the Mac's runtimes' account for new sessions,
    /// nil for its own sign-in. Nil when it was set; else why not.
    func setDefaultAccount(runtimeID: String, accountID: String?) async -> String? {
        do {
            _ = try await client.call(DaemonAPI.Method.runtimesSetDefaultAccount,
                                      DaemonAPI.DefaultAccountRequest(runtimeID: runtimeID,
                                                                      accountID: accountID ?? AccountProfile.ownSignInID),
                                      returning: DaemonAPI.Empty.self)
            await refreshAccountProfiles()
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    func refreshAccountProfiles() async {
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccountProfiles, Optional<Int>.none,
                                               returning: [AccountProfile].self) {
            accountProfiles = listed
        }
    }

    /// Add an account to one of the Mac's runtimes (#840). Nil when it was added; else why not.
    func addAccount(runtimeID: String, name: String) async -> String? {
        do {
            let added = try await client.call(DaemonAPI.Method.runtimesAddAccount,
                                              DaemonAPI.AddAccountRequest(runtimeID: runtimeID, name: name),
                                              returning: AccountProfile.self)
            accountProfiles.removeAll { $0.id == added.id }
            accountProfiles.append(added)
            await refreshRuntimeAllowances()
            return nil
        } catch {
            return sentence(for: error)
        }
    }

    /// The Mac's sessions an added account is running, which removing it stops (#2264).
    func agentsHolding(account: AccountProfile) -> [Agent] {
        work.agents.filter { $0.host == .mac && $0.accountID == account.id && $0.state.holdsRuntime }
    }

    func removeAccount(_ account: AccountProfile) async {
        do {
            _ = try await client.call(DaemonAPI.Method.runtimesRemoveAccount,
                                      DaemonAPI.AccountRequest(runtimeID: account.runtimeID, accountID: account.id),
                                      returning: [UUID].self)
        } catch {
            problem = sentence(for: error)
        }
        await refreshAccountProfiles()
        await refreshRuntimeAllowances()
    }

    func runtimes(on host: MachineRef) -> [RuntimeStatus] {
        host == .mac ? runtimes : serverRuntimes[host] ?? []
    }

    func refreshServerRuntimes(_ host: MachineRef) async {
        guard let other = otherHosts[host] else { return }
        do {
            let listed = try await other.call(DaemonAPI.Method.runtimesList, Optional<String>.none,
                                              returning: [RuntimeStatus].self)
            serverRuntimes[host] = RuntimeCatalog.sortedByName(listed)
            runtimesFailure[host] = nil
        } catch {
            runtimesFailure[host] = (error as? JSONRPCError)?.message ?? "\(hostName(host)) did not answer."
        }
    }

    /// What this runtime says it will take in a prompt, as the Mac reads it. Nothing
    /// is refused on a guess: unknown is the protocol's baseline. On Auto it is the runtime
    /// Auto would pick now; before that is known, nothing is refused, as on the Mac and the
    /// web page: the host picks one that takes what is attached, or says why none can (#3162).
    func promptCapabilities(for runtimeID: String?) -> ACP.PromptCapabilities {
        let resolved = runtimeID == LevelWords.autoID ? startAutoPreview?.runtimeID : runtimeID
        if runtimeID == LevelWords.autoID, resolved == nil { return .anything }
        return resolved.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    /// The runtime a refusal names (#3162): on Auto, the one it would pick now.
    func promptRuntimeName(for runtimeID: String?) -> String? {
        let resolved = runtimeID == LevelWords.autoID ? startAutoPreview?.runtimeID : runtimeID
        return resolved.flatMap { RuntimeCatalog.runtime(id: $0)?.name ?? $0 }
    }

    /// Whether this runtime is signed in, as the window's runtime list says it (#538):
    /// "Needs signing in", else the account it is using ("Claude Max"). The accounts
    /// are the Mac's own.
    func signInNote(for runtimeID: String) -> String? {
        let account = accounts[runtimeID]
        if account?.state == .needsSignIn { return "Needs signing in" }
        return account?.signedInAs?.label
    }

    /// Whether this runtime said it takes words in the middle of a turn.
    func canSteer(_ runtimeID: String?) -> Bool {
        runtimeID.flatMap { accounts[$0]?.canSteer } ?? false
    }

    /// A folder's counts from the same grouping its page uses, so the list and the
    /// page cannot disagree about what needs attention.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }

    func counts(in key: FolderKey) -> [AgentGroup: Int] { work.counts(in: key) }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether the menu offers Stop: the same answer the Mac gives.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }

    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }

    func queuedLine(_ agent: Agent) -> String? { work.queuedLine(agent) }

    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }

    /// End a block by hand (039), as the person. See the Mac's `carryOn`.
    func carryOn(_ agentID: UUID) async { _ = await send(Block.carryOnPrompt, to: agentID) }

    /// Continue, on an event wait (#3052). See the Mac's `continueWaiting`.
    func continueWaiting(of agentID: UUID, line: ResourceName? = nil) async {
        if line != nil { await cancelWait(of: agentID) }
        _ = await send(line.map(EventWait.lineCarryOnPrompt) ?? EventWait.carryOnPrompt, to: agentID)
    }

    /// What a guarded file was and is (#502), for the person deciding.
    func readGuardedChange(_ change: GuardedChange, for key: FolderKey) async -> GuardedChangeReading? {
        let request = DaemonAPI.GuardedChangeRequest(folder: key.folder, path: change.path)
        do {
            return try await client(for: request).call(DaemonAPI.Method.foldersReadGuardedChange, request,
                                                       returning: GuardedChangeReading.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Keep (the change is used from now on) or Undo (the approved copy goes back), of the
    /// file as the person was shown it (#531). The folder's summary that comes back with
    /// it, or after it, takes the question away.
    func settleGuardedChange(_ reading: GuardedChangeReading, keep: Bool, for key: FolderKey) async {
        let request = DaemonAPI.GuardedChangeRequest(folder: key.folder, path: reading.path, digest: reading.digest)
        do {
            var summary: DaemonAPI.FolderSummary = try await client(for: request).call(
                keep ? DaemonAPI.Method.foldersKeepGuardedChange : DaemonAPI.Method.foldersUndoGuardedChange,
                request, returning: DaemonAPI.FolderSummary.self)
            summary.host = key.host
            work.upsert(summary)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// What a waiting item in Needs You is (#773), for the person deciding.
    func readApproval(_ approval: Approval, for key: FolderKey) async -> GuardedChangeReading? {
        let request = ApprovalReadRequest(folder: key.folder, kind: approval.kind, key: approval.key)
        do {
            return try await client(for: request).call(DaemonAPI.Method.approvalsRead, request,
                                                       returning: GuardedChangeReading.self)
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Approve, Deny or Request changes on a waiting item (#773), of the version shown;
    /// nil when it went, else why not, for the sheet to say.
    func answerApproval(_ approval: Approval, _ action: Approval.Action, digest: String?, note: String?,
                        for key: FolderKey) async -> String? {
        var answer = ApprovalAnswer(approval, in: key.folder, action: action, note: note)
        answer.digest = digest ?? approval.digest
        var why: String?
        // Out of its list at once, and back if the answer did not go (#4814).
        await work.answering(approval, in: key) {
            do {
                var summary: DaemonAPI.FolderSummary = try await client(for: answer).call(
                    DaemonAPI.Method.approvalsAnswer, answer, returning: DaemonAPI.FolderSummary.self)
                summary.host = key.host
                work.upsert(summary)
                return true
            } catch {
                why = sentence(for: error)
                return false
            }
        }
        return why
    }

    /// Approve or Deny from a row's long press, of the version the row shows.
    func settleApproval(_ approval: Approval, _ action: Approval.Action, for key: FolderKey) async {
        if let why = await answerApproval(approval, action, digest: approval.digest, note: nil, for: key) {
            problem = approval.failure(action, why)
        }
    }

    /// A person's answer to a secret's use (#4017), from its Needs you row or its banner: to
    /// the host of the session that asked. Whether it went; why not is the problem.
    @discardableResult
    func answerSecretUse(_ request: NeedRequest, _ action: NeedRequest.Action) async -> Bool {
        let host = request.askedBy.flatMap { work.agent($0)?.host } ?? .mac
        var approval: DaemonAPI.LockDelivery?
        // A Linux machine opens the value only for an answer this device signed (#4149).
        if let use = request.secretUse, use.signs(action) {
            guard let signer = await lock.channelSigner(),
                  let signed = try? LockChannel.secretUseApproval(signer.key, to: host.rawValue, request: request.id,
                                                                  use: use, action: action) else {
                problem = "Not sent — this machine opens the secret only for an answer your device signs, and this device is not in your lock. Answer on the Mac."
                return false
            }
            approval = signed
        }
        let answer = DaemonAPI.RequestsAnswer(id: request.id, secretUse: action, approval: approval)
        do {
            let update = try await client(for: answer, on: host)
                .call(DaemonAPI.Method.requestsAnswer, answer, returning: DaemonAPI.RequestUpdate.self)
            work.replaceRequests(work.requests.filter { $0.id != update.request.id })
            publishAttention()
            return true
        } catch {
            problem = sentence(for: error)
            return false
        }
    }

    /// Later on a request (#4235), from its Needs you row's swipe or long press: to the host
    /// of the session that asked. It stays open, in Later, until it comes back.
    @discardableResult
    func deferRequest(_ request: NeedRequest, _ later: NeedRequest.Later) async -> Bool {
        let params = later.params(id: request.id)
        let sent = await work.changing(request, to: request.deferring(params)) {
            await changeRequest(request, DaemonAPI.Method.requestsDefer, params)
        }
        // Undo is Bring Back Now (#4793).
        if sent { offer(SessionUndo.later(request)) }
        return sent
    }

    /// Bring Back Now (#4235): out of Later, to the top of Needs you.
    @discardableResult
    func undeferRequest(_ request: NeedRequest) async -> Bool {
        await work.changing(request, to: request.broughtBack) {
            await changeRequest(request, DaemonAPI.Method.requestsUndefer, DaemonAPI.RequestsUndefer(id: request.id))
        }
    }

    func changeRequest(_ request: NeedRequest, _ method: String,
                               _ params: some Encodable & Sendable) async -> Bool {
        let host = request.askedBy.flatMap { work.agent($0)?.host } ?? .mac
        do {
            let update = try await client(for: params, on: host)
                .call(method, params, returning: DaemonAPI.RequestUpdate.self)
            work.apply(.requestChanged(update.request))
            publishAttention()
            return true
        } catch {
            problem = sentence(for: error)
            return false
        }
    }

    /// Deny a session's ask to be archived (#773): the mark goes and the session stays.
    func keepSession(_ agent: Agent) async {
        let denial = ArchiveActions.denial(for: agent)
        await settleApproval(denial.approval, .deny, for: denial.folder)
    }

    /// What the agent has asked be looked at, if the conversation open is its own.
    /// Peeked rather than taken: taking it is what opening it does.
    var fileTheAgentWants: ShownFile? {
        guard let selection else { return nil }
        return work.filesToShow[selection]
    }
}
