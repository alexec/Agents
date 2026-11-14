import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: A server's key (#344)

    /// The home host's asks: the control plane's, which may be a server. No runtime takes
    /// a pasted key now that Gemini, the only one that did, is retired (#3043), and this
    /// device has no sign-in of its own to relay (that is the Mac window's alone), so
    /// there is nothing to lend here.
    func answerHomeCredentialWanted(_ wanted: DaemonAPI.CredentialWanted) async -> Bool { false }

    /// A server's daemon wants a key to start a runtime (043, R6): nothing to lend (#3043).
    func answerCredentialWanted(_ wanted: DaemonAPI.CredentialWanted, on id: MachineRef) async -> Bool { false }

    /// Put what the person typed on a page on disk, through the daemon, which is the one
    /// writer and the one that tells the agent (022). The same request the Mac's page
    /// makes, so a phone's edit is the person's in exactly the same way (034 FR-006).
    /// Answers why it did not land, or nil.
    /// The editor's save that checks the file first (#1858).
    func writeArtifact(agentID: UUID, path: String, text: String, base: String) async -> SaveOutcome {
        guard !isStale else { return .failed(controlPlaneReach.notAnswering) }
        do {
            let request = DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text, base: base)
            try await client(for: request).call(DaemonAPI.Method.artifactWrite, request)
            return .saved
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileChanged {
            return .changedOnDisk
        } catch let error as JSONRPCError {
            return .failed(error.message)
        } catch {
            return .failed(controlPlaneReach.notAnswering)
        }
    }

    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        guard !isStale else { return controlPlaneReach.notAnswering }
        do {
            let request = DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text)
            try await client(for: request).call(DaemonAPI.Method.artifactWrite, request)
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return controlPlaneReach.notAnswering
        }
    }

    /// The Mac predates the panes, and the phone does what it did before them (FR-029).
    var macLacksPanes: Bool { files.macLacksPanes }
}
