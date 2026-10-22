import AgentsKitCore
import SwiftUI

/// Control plane ▸ Policy (#998, spec 998 FR-021, FR-022): the organisation's rules in words, read
/// only, with the last change and who made it. An admin also gets **Edit in Console**, which opens
/// Console ▸ Policy on the web page, and the kill switch, because an incident does not wait for a desk.
///
/// One view for the Mac's Settings pane and the Remote's Settings page (the web page's is
/// `Web/src/views/settings/Policy.tsx`).
struct OrgPolicyPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let isAdmin: Bool

    @Environment(\.openURL) private var openURL
    @State private var view: DaemonAPI.PolicyView?
    /// The routes this person may use (#999); nil from a control plane before them, which shows none.
    @State private var routes: [DaemonAPI.OrgRouteMine]?
    @State private var console: URL?
    @State private var problem: String?
    @State private var isChanging = false
    /// The question before the kill switch moves, with the running agents it names.
    @State private var asking: Ask?

    private struct Ask: Identifiable {
        var on: Bool
        var running: Int?
        var id: Bool { on }
    }

    var body: some View {
        Form {
            if let problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            if let view {
                if let stop = view.policy?.stopAll, stop.on {
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(OrgPolicyWords.stoppedStrip).appText(.reading).bold()
                            Text(OrgPolicyWords.stoppedBy(stop)).appText(.fine)
                            if let note = stop.note, !note.isEmpty { Text(note).appText(.fine) }
                        }
                        .tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .paperListRow()
                }
                Section {
                    let rules = view.policy.map(OrgPolicyWords.rules) ?? []
                    if rules.isEmpty {
                        Text(OrgPolicyWords.none).appText(.supporting).foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        LabeledContent(rule.title) {
                            Text(rule.words).multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let policy = view.policy {
                            Text(OrgPolicyWords.changed(policy))
                        }
                        Text(OrgPolicyWords.foot)
                    }
                    .appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
                if let routes {
                    Section {
                        if routes.isEmpty {
                            Text(OrgAccountWords.noRoutes).appText(.supporting).foregroundStyle(.secondary)
                        }
                        ForEach(routes) { route in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(route.name).appText(.reading)
                                Text(OrgAccountWords.mineLine(route)).appText(.fine).foregroundStyle(.secondary)
                                Text(OrgAccountWords.fromOrganisation).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(OrgAccountWords.routesTitle)
                    } footer: {
                        Text(OrgAccountWords.routesFoot).appText(.fine).foregroundStyle(.secondary)
                    }
                    .paperListRow()
                }
                if isAdmin {
                    Section {
                        if let console {
                            Button(OrgPolicyWords.editInConsole) { openURL(console) }
                        }
                        let on = view.policy?.isStopped == true
                        Button(on ? OrgPolicyWords.resumeAll : OrgPolicyWords.stopAll, role: on ? nil : .destructive) {
                            Task { await ask(on: !on) }
                        }
                        .disabled(isChanging || control == nil)
                    } footer: {
                        Text(OrgPolicyWords.stopFoot).appText(.fine).foregroundStyle(.secondary)
                    }
                    .paperListRow()
                }
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: control != nil) {
            while !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
        .confirmationDialog(asking.map { $0.on ? OrgPolicyWords.stopTitle : OrgPolicyWords.resumeTitle } ?? "",
                            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { ask in
            Button(ask.on ? OrgPolicyWords.stopAll : OrgPolicyWords.resumeAll, role: ask.on ? .destructive : nil) {
                Task { await stopAll(ask.on) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { ask in
            Text(ask.on ? OrgPolicyWords.stopMessage(running: ask.running) : OrgPolicyWords.resumeMessage)
        }
    }

    /// False when the control plane did not answer at all, so it is worth asking again.
    @discardableResult
    private func load() async -> Bool {
        guard let control else {
            problem = "The control plane can’t be reached."
            return true
        }
        do {
            view = try await control.call(DaemonAPI.Method.policyMine, DaemonAPI.Empty(), returning: DaemonAPI.PolicyView.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
            return error is JSONRPCError
        }
        routes = (try? await control.call(DaemonAPI.Method.orgRoutesMine, DaemonAPI.Empty(),
                                          returning: DaemonAPI.OrgRoutesMine.self))?.routes
        if isAdmin {
            let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
            console = OrgPolicyWords.consoleURL(status)
        }
        return true
    }

    /// The question first, naming the agents running now when the control plane can say.
    private func ask(on: Bool) async {
        var running: Int?
        if on, let control {
            running = OrgPolicyWords.running(try? await control.call(DaemonAPI.Method.consoleFleet, DaemonAPI.Empty(),
                                                                     returning: DaemonAPI.FleetBoard.self))
        }
        asking = Ask(on: on, running: running)
    }

    private func stopAll(_ on: Bool) async {
        guard let control else { return }
        isChanging = true
        defer { isChanging = false }
        do {
            let kept = try await control.call(DaemonAPI.Method.policyStopAll, DaemonAPI.PolicyStopAllRequest(on: on),
                                              returning: DaemonAPI.PolicyKept.self)
            view = DaemonAPI.PolicyView(policy: kept.policy)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}
