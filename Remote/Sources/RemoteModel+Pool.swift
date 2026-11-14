import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: The pool (052)

    func agent(_ id: UUID) -> Agent? { work.agent(id) }

    /// Every runtime's state on the Mac (065, US4).
    var runtimeAllowances: RuntimeAllowances? { work.runtimeAllowances }

    func refreshRuntimeAllowances() async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesAllowances, Optional<String>.none,
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The person says a runtime is back. The phone may: it costs one turn if wrong.
    func markRuntimeAvailable(_ credentialKey: String) async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesMarkAvailable,
                                                      DaemonAPI.MarkRuntimeAvailable(credentialKey: credentialKey),
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// What each agent holds and waits for (036). The phone only reads it: the
    /// Resources page and ending a lease are the Mac's (FR-011).
    func refreshLeases() async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.resourcesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
        // The servers the Mac hosts for every agent (#488), read with them for their page (#589).
        if let hosted = try? await client.call(DaemonAPI.Method.mcpHosted, Optional<String>.none,
                                               returning: DaemonAPI.HostedMCPSnapshot.self) {
            work.replaceHostedMCP(hosted)
        }
        // Every MCP server on the Mac and how each is doing (#753).
        if let health = try? await client.call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                               returning: DaemonAPI.MCPHealthSnapshot.self) {
            work.replaceMCPHealth(health)
        }
        // The Mac's capacity level, for its row (#4748).
        if let capacity = try? await client.call(DaemonAPI.Method.capacityState, Optional<String>.none,
                                                 returning: DaemonAPI.CapacityState.self) {
            work.replaceCapacity(capacity, from: .mac)
        }
    }

    /// The files the Mac's host could not read in this run (#205, #223), then heard as
    /// they change. A Mac too old to know the method leaves the list empty, as it would
    /// be with nothing to say.
    func refreshStoreNotes() async {
        guard let notes = try? await client.call(DaemonAPI.Method.storeNotes, Optional<String>.none,
                                                 returning: DaemonAPI.StoreNotes.self) else { return }
        work.replaceStoreNotes(notes)
    }

    /// The newest events and who is waiting (042). The phone only reads them.
    func refreshEvents(_ filter: EventFilter? = nil) async {
        let filter = filter ?? work.eventsFilter
        work.eventsFilter = filter
        guard let page = try? await client.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter)
    }

    /// The page before the oldest event the phone has, for scrolling back.
    func loadOlderEvents() async {
        let filter = work.eventsFilter
        guard work.moreEvents, let oldest = work.recentEvents.last?.position else { return }
        guard let page = try? await client.call(DaemonAPI.Method.eventsList,
                                                DaemonAPI.EventsListRequest(before: oldest, filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter, appending: true)
    }

    /// What the Mac is still bringing back after a restart.
    ///
    /// A daemon too old to know the method answers method-not-found, which is the
    /// same as nothing coming back — not a connection that failed.
    /// Every folder's, in one call, the way the window asks for them. `workflow/changed`
    /// keeps them current afterwards; without this first fetch the section would stay
    /// empty until something happened to a workflow, which on a quiet folder is never.
    func refreshWorkflows() async {
        guard let listed = try? await client.call(DaemonAPI.Method.workflowsList,
                                                  DaemonAPI.WorkflowsListRequest(),
                                                  returning: [WorkflowSummary].self) else { return }
        work.replaceWorkflows(listed)
    }

    /// One of a view's calls (#187), to the Mac.
    func viewCall(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        try await client.call(method, params)
    }
}
