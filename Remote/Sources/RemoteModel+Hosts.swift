import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: A control plane's other hosts (058, US4)

    /// The client a call belongs to: another host's for an agent or a folder there,
    /// this phone's own host's for everything else. Worked out from what the call names,
    /// so no call site has to know there is more than one host.
    ///
    /// Another host this phone cannot reach now is `HostAway` at once: the call used to
    /// go to the home host, which could mean a whole catch-up there before failing
    /// anyway (#208).
    ///
    /// `host` names it outright, for a call whose folder could be at the same path on
    /// another machine (#3446).
    func client(for params: some Encodable, on host: MachineRef? = nil) throws -> DaemonClient {
        let host = host ?? otherHost(named: params) ?? .mac
        guard host != .mac else { return client }
        guard let other = otherHosts[host], reachableHosts.contains(host) else { throw HostAway(host: host) }
        return other
    }

    /// The host other than this phone's own that a call names, by its agent or its folder.
    func otherHost(named params: some Encodable) -> MachineRef? {
        guard !controlHosts.isEmpty, let value = try? JSONValue.encoding(params) else { return nil }
        if let id = (value["agentID"] ?? value["id"])?.stringValue.flatMap(UUID.init(uuidString:)),
           let host = work.agent(id)?.host, host != .mac {
            return host
        }
        for key in ["folder", "cwd"] {
            guard let folder = value[key]?.stringValue else { continue }
            if let folder = work.folders.first(where: { $0.folder.folder.absoluteString == folder && $0.host != .mac }) {
                return folder.host
            }
        }
        return nil
    }

    /// Another of the control plane's hosts, not reachable from here now (#208).
    struct HostAway: Error {
        let host: MachineRef
    }

    /// The home host did not come back within `sendPatience` (#208).
    struct MacAway: Error {}

    /// Whether what is shown of `host`'s work can be trusted, and acted on: the home host's
    /// staleness for its own, that host's link for another's (#208).
    func isStale(on host: MachineRef) -> Bool {
        host == .mac ? isStale : !reachableHosts.contains(host)
    }

    /// When what the phone holds of `host` was last live (#5143), while it is stale: the
    /// last read from the Mac or the control plane while that link is down, else the time
    /// the server went. Nil while it answers.
    func hostReadAt(_ host: MachineRef) -> Date? {
        if isStale { return lastReadAt }
        return host == .mac ? nil : hostDownSince[host]
    }

    func isStale(_ agent: Agent) -> Bool { isStale(on: agent.host) }

    /// Who something sent to `host` goes to, as the in-flight mark (`Telling`) names it:
    /// the Mac as "your Mac", a server by its name, as the window says it (#239).
    func recipient(on host: MachineRef) -> String {
        host == .mac ? "your Mac" : hostName(host)
    }

    /// Who something sent to this agent goes to (#239).
    func answerRecipient(_ agentID: UUID) -> String {
        recipient(on: work.agent(agentID)?.host ?? .mac)
    }

    /// The host of the folder the start page is open on: where the new agent starts.
    var startHost: MachineRef {
        startingIn?.host ?? .mac
    }

    /// Whether a host can do what `capability` names (#1748): its row's list, with `.mac`
    /// read as this phone's home host. True when the host said no list, or is not a
    /// control plane's.
    func host(_ host: MachineRef, has capability: String) -> Bool {
        let id = host == .mac ? (controlHome ?? host) : host
        return controlHosts.first { $0.id == id }?.has(capability) ?? true
    }

    /// Whether the host of an agent can do what `capability` names.
    func agent(_ id: UUID?, has capability: String) -> Bool {
        host(work.agent(id)?.host ?? .mac, has: capability)
    }

    /// A host's row as `machines/list` last said it: its state, and the workspace it runs on (#691).
    func controlHost(_ host: MachineRef) -> DaemonAPI.ControlMachine? {
        controlHosts.first { $0.id == host }
    }

    /// Whether a prompt or a start for `host` now is kept rather than refused: it is linked
    /// to a workspace that is stopped or starting, and starts when used (FR-020).
    func startsWhenUsed(_ host: MachineRef) -> Bool {
        guard let row = controlHosts.first(where: { $0.id == host }), row.workspace?.startWhenUsed == true else { return false }
        return row.state == "stopped" || row.state == "starting"
    }

    func kept(for agentID: UUID) -> [DaemonAPI.KeptRequest] {
        kept.filter { !$0.isStart && $0.agentID == agentID }
    }

    func keptStarts(in folder: URL) -> [DaemonAPI.KeptRequest] {
        let folder = Folder.standardize(folder)
        return kept.filter { $0.isStart && $0.folder.map(Folder.standardize) == folder }
    }

    /// A prompt or a start for a stopped workspace's host, whose link is closed while it is
    /// down, sent to the control plane to keep (#691 US3). What was kept, or nil with why not.
    func keepThroughControl(_ host: MachineRef, _ method: String, _ params: some Encodable) async -> DaemonAPI.KeptRequest? {
        guard let control = controlPlane, let params = try? JSONValue.encoding(params) else {
            problem = "The control plane isn’t answering, so that was not sent."
            return nil
        }
        // Signed by this device, so a host that holds the lock takes it when it connects (#3492).
        let signed = await lock.channelSigner().flatMap { try? LockChannel.delivery($0.key, to: host.rawValue, method: method, params: params) }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsKeep, DaemonAPI.KeepRequest(host: host, method: method, params: params, signed: signed))
            return nil
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.kept {
            guard let said = try? error.data?.decode(DaemonAPI.KeptRequest.self) else { return nil }
            if !kept.contains(where: { $0.id == said.id }) { kept.append(said) }
            return said
        } catch {
            problem = sentence(for: error)
            return nil
        }
    }

    /// Approve or Deny on a machine's card (#994): a refusal is the app's alert.
    func answerJoin(_ request: DaemonAPI.JoinRequest, approve: Bool) async {
        if let refused = await people.answer(request, approve: approve, on: controlPlane) {
            problem = refused
        }
    }

    /// Approve or Deny on a GitHub sign-in's card (#995): a refusal is the app's alert.
    /// Compare Digits, Approve or Deny on a lock card, and Ask Again on this device's own (#3490).
    func compareLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.compare(request, on: controlPlane) }

    func approveLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.approve(request, on: controlPlane) }

    func denyLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.deny(request, on: controlPlane) }

    func askLockAgain() async { await lock.askAgain(on: controlPlane) }

    /// The recovery key (#3493, D4): Use Recovery Key, Start a New Lock, Make Recovery Key, and
    /// I Saved It or Skip.
    func useLockRecovery(_ text: String) async -> String? { await lock.useRecoveryKey(text, on: controlPlane) }

    func startNewLock() async { await lock.startNewLock(on: controlPlane) }

    func makeLockRecovery() async { await lock.makeRecoveryKey(on: controlPlane) }

    func dismissLockRecovery() { lock.dismissRecovery() }

    func answerSignIn(_ request: DaemonAPI.SignInRequest, approve: Bool, code: String? = nil) async {
        if let refused = await signIn.answer(request, approve: approve, code: code, on: controlPlane) {
            problem = refused
        }
    }

    /// Pair with no code, by signing in (#995): as `pair(scanned:)` does once paired.
    func pairBySigningIn(at url: URL, with signIn: @escaping ControlSignIn.Provider,
                         waiting: @escaping @Sendable (DaemonAPI.SignInWaiting) -> Void) async throws {
        let id = deviceID
        _ = try await RemoteControl.signIn(at: url, id: id, with: signIn, waiting: waiting)
        pairing = .paired
        note("pairing: paired with the control plane at \(url.host() ?? "?") by signing in")
        pairedWithControlPlane = true
    }

    /// Approve, Deny or Send on a channel link's card (#1762): a refusal is the app's alert.
    func answerLink(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to person: String?) async {
        if let refused = await people.answerLink(request, approve: approve, to: person, on: controlPlane) {
            problem = refused
        }
    }

    func loadKept(_ control: DaemonClient) async {
        kept = (try? await control.call(DaemonAPI.Method.hostsListKept, returning: DaemonAPI.KeptList.self))?.kept ?? []
    }

    func heardKept(_ method: String, _ params: JSONValue?) async {
        if method == DaemonAPI.Notification.controlKeptChanged {
            kept = (try? params?.decode(DaemonAPI.KeptList.self))?.kept ?? []
            return
        }
        // A kept start reached its host: the agent it made opens, if this phone showed it.
        guard let delivered = try? params?.decode(DaemonAPI.KeptDelivered.self),
              keptStartsShown.remove(delivered.id) != nil, let agentID = delivered.agentID,
              let folder = startingIn else { return }
        await started(agentID, in: folder, open: true)
    }

    /// × on a kept prompt: it isn't sent, and the workspace keeps starting (US3 AS3).
    func dropKept(_ request: DaemonAPI.KeptRequest) async {
        kept.removeAll { $0.id == request.id }
        await keptCall(DaemonAPI.Method.hostsDropKept, request)
    }

    /// Try Again on one that wasn't sent: kept again, and the workspace started.
    func retryKept(_ request: DaemonAPI.KeptRequest) async {
        await keptCall(DaemonAPI.Method.hostsRetryKept, request)
    }

    func keptCall(_ method: String, _ request: DaemonAPI.KeptRequest) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering."
            return
        }
        do {
            _ = try await control.call(method, DaemonAPI.KeptRequestID(host: request.host, id: request.id))
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Start the workspace `host` runs on (#691, the strip's Start). The control plane answers
    /// at once; the start's progress comes as `control/hostChanged`, and a refusal is said
    /// in `problem`.
    func startHost(_ host: MachineRef) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so \(hostName(host)) could not be started."
            return
        }
        hostsBeingStarted.insert(host)
        defer { hostsBeingStarted.remove(host) }
        do {
            let row = try await control.call(DaemonAPI.Method.hostsStart, DaemonAPI.MachineRequest(host: host),
                                             returning: DaemonAPI.ControlMachine.self)
            if let index = controlHosts.firstIndex(where: { $0.id == row.id }) { controlHosts[index] = row }
        } catch {
            problem = sentence(for: error)
        }
    }
}
