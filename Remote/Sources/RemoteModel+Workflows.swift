import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Driving a workflow

    /// Run one now. The Mac still applies the in-flight, ceiling and archive rules and
    /// says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        do {
            let request = DaemonAPI.WorkflowRequest(folder: summary.folder, workflowID: summary.workflowID)
            try await client(for: request).call(DaemonAPI.Method.workflowsRun, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Put one away, or bring it back. `workflow/changed` redraws the page.
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async {
        do {
            let request = DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                           workflowID: summary.workflowID,
                                                           archived: archived)
            try await client(for: request).call(DaemonAPI.Method.workflowsArchive, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// An edited ready-made copy (#4075): the newer ready-made version over it, or the copy
    /// kept and the notice hidden until the next version. `workflow/changed` redraws the page.
    func answerReadyMade(_ summary: WorkflowSummary, take: Bool) async {
        do {
            let request = DaemonAPI.WorkflowRequest(folder: summary.folder, workflowID: summary.workflowID)
            try await client(for: request).call(take ? DaemonAPI.Method.workflowsReadyMadeTake
                                                     : DaemonAPI.Method.workflowsReadyMadeKeep, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Let a waiting one run as its file now reads (#142): the digest is what the page
    /// was showing, so a file changed since is still waiting afterwards.
    func approveWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsApprove)
    }

    /// Deny it on its host only (#391): it does not run there, its file is not touched,
    /// and Approve takes it back.
    func denyWorkflow(_ summary: WorkflowSummary) async {
        await answerWorkflow(summary, DaemonAPI.Method.workflowsDeny)
    }

    func answerWorkflow(_ summary: WorkflowSummary, _ method: String) async {
        guard let waiting = summary.approvable else { return }
        do {
            let request = DaemonAPI.WorkflowApproveRequest(folder: summary.folder,
                                                            workflowID: summary.workflowID,
                                                            digest: waiting.digest)
            let updated: WorkflowSummary = try await client(for: request).call(
                method, request, returning: WorkflowSummary.self)
            keepWorkflow(updated, named: request)
        } catch {
            problem = sentence(for: error)
            await refreshWorkflows()
        }
    }

    /// Turn one on or off, keeping its place on the list (#100).
    func setWorkflowEnabled(_ summary: WorkflowSummary, _ enabled: Bool) async {
        do {
            let request = DaemonAPI.WorkflowEnableRequest(folder: summary.folder,
                                                          workflowID: summary.workflowID,
                                                          enabled: enabled)
            try await client(for: request).call(DaemonAPI.Method.workflowsEnable, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Whether a workflow's host can mute its runs: one from before #2003 cannot.
    func canMute(_ summary: WorkflowSummary) -> Bool {
        let host = work.folders.first { $0.folder.folder.absoluteString == summary.folder.absoluteString }?.host ?? .mac
        return !summary.isArchived && self.host(host, has: Capability.mute1)
    }

    /// Mute Notifications for a workflow's runs, or Unmute (#2003): `muted: true` in its file.
    func setWorkflowMuted(_ summary: WorkflowSummary, _ muted: Bool) async {
        do {
            let request = DaemonAPI.WorkflowMuteRequest(folder: summary.folder, workflowID: summary.workflowID, muted: muted)
            try await client(for: request).call(DaemonAPI.Method.workflowsSetMuted, request)
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Keep a workflow the host still runs (#317). The host is the one the call named.
    func keepWorkflow(_ summary: WorkflowSummary, named params: some Encodable) {
        let host = otherHost(named: params) ?? controlHome ?? .mac
        if !summary.workflow.runs(on: controlHosts.first(where: { $0.id == host })?.machineID) {
            work.removeWorkflow(summary.workflowID, in: summary.folder)
        } else {
            work.upsert(summary)
        }
    }

    func makeDisplayMirror() -> DisplayPreferenceMirror {
        DisplayPreferenceMirror(defaults: .standard) { [weak self] changes in
            guard let self else { throw CancellationError() }
            return try await client.call(DaemonAPI.Method.preferencesSet, changes, returning: DaemonAPI.DisplayPreferences.self)
        } failed: { [weak self] error in
            guard let self else { return }
            problem = DisplayPreferenceMirror.failure(sentence(for: error))
        }
    }

    /// A Mac too old to know the method leaves this device's own choices as they are.
    func refreshDisplayPreferences() async {
        guard let preferences = try? await client.call(DaemonAPI.Method.preferencesGet, Optional<Int>.none,
                                                       returning: DaemonAPI.DisplayPreferences.self) else { return }
        displayMirror.hostSaid(preferences)
    }

    func refreshModes() async {
        guard let modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                                 returning: DaemonAPI.RememberedModes.self) else { return }
        work.replaceRememberedModes(modes)
    }

    /// The Runtimes page's pass-through names; none from a Mac too old to say.
    func refreshPassThrough() async {
        passThrough = (try? await client.call(DaemonAPI.Method.settingsPassThrough, DaemonAPI.Empty(),
                                              returning: DaemonAPI.PassThroughState.self)) ?? DaemonAPI.PassThroughState()
    }

    /// A Mac too old to know the method has no policy to follow.
    func refreshPolicyState() async {
        policyState = try? await client.call(DaemonAPI.Method.daemonPolicyState, DaemonAPI.Empty(),
                                             returning: DaemonAPI.PolicyState.self)
    }

    /// A Mac too old to know the method leaves every runtime as configured, which is
    /// what it does.
    func refreshSandboxSettings() async {
        guard let settings = try? await client.call(DaemonAPI.Method.sandboxState, Optional<String>.none,
                                                    returning: SandboxSettings.self) else { return }
        sandboxSettings = settings
    }

    /// The permission choice is Mac-wide, even when the open folder is on a server.
    func refreshClientPermissions() async {
        guard let settings = try? await client.call(DaemonAPI.Method.clientPermissionsState,
                                                    Optional<String>.none,
                                                    returning: ClientPermissionSettings.self) else { return }
        clientPermissions = settings
    }

    /// One agent's own sandbox choice from the phone (064); nil follows the default.
    func setAgentSandbox(_ agentID: UUID, _ choice: SandboxChoice?) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let request = DaemonAPI.SetSandboxRequest(agentID: agentID, choice: choice)
            try await client(for: request).call(DaemonAPI.Method.agentsSetSandbox, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// A running agent's own answer to permission requests; nil follows Settings (#2658).
    func setAgentClientPermission(_ agentID: UUID, _ mode: ClientPermissionMode?) async {
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let request = SetClientPermissionRequest(agentID: agentID, mode: mode)
            try await client(for: request).call(DaemonAPI.Method.agentsSetClientPermission, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// Where Auto would start an Auto session's successor now (FR-022).
    func autoPreview(for agent: Agent) async -> AutoPreview? {
        guard let pick = agent.auto else { return nil }
        let request = AutoPreviewRequest(cwd: agent.cwd, levels: pick.levels, sandbox: agent.sandboxOverride)
        guard let client = try? client(for: DaemonAPI.AgentRequest(agentID: agent.id)) else { return nil }
        return try? await client.call(DaemonAPI.Method.autoPreview, request, returning: AutoPreview.self)
    }

    /// A running agent's model level or permission mode, mapped on its own runtime (#2658).
    func setAgentLevel(_ agentID: UUID, _ field: AutoField, _ level: String) async {
        var levels = Levels()
        switch field {
        case .model: levels.model = ModelLevel(rawValue: level)
        case .permission: levels.permission = PermissionLevel(rawValue: level)
        default: return
        }
        guard !isStale else {
            problem = "Your Mac is not answering, so that could not be changed."
            return
        }
        do {
            let request = SetLevelsRequest(agentID: agentID, levels: levels)
            try await client(for: request).call(DaemonAPI.Method.agentsSetLevels, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    /// The sandbox card's answer, from the phone (064, FR-007a).
    func answerSandbox(_ agentID: UUID, carryOn: Bool) async {
        do {
            let request = DaemonAPI.AnswerSandboxRequest(agentID: agentID, carryOn: carryOn)
            try await client(for: request).call(DaemonAPI.Method.agentsAnswerSandbox, request)
        } catch {
            problem = (error as? JSONRPCError)?.message ?? "That did not reach your Mac."
        }
    }

    func refreshRuntimes() async {
        do {
            let listed = try await client.call(DaemonAPI.Method.runtimesList,
                                               Optional<String>.none,
                                               returning: [RuntimeStatus].self)
            runtimes = RuntimeCatalog.sortedByName(listed)
            runtimesFailure[.mac] = nil
        } catch {
            runtimesFailure[.mac] = sentence(for: error)
        }
        if let listed = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                               Optional<Int>.none,
                                               returning: [RuntimeAccount].self) {
            accounts = Dictionary(uniqueKeysWithValues: listed.map { ($0.runtimeID, $0) })
        }
        await refreshAccountProfiles()
    }

    /// A folder archived on the Mac while it is being read here moves the selection
    /// rather than leaving an empty screen.
    func settleSelection() {
        guard let selectedKey else { return }
        if !folders.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = nil
        }
    }
}
