import AgentsKitCore
import SwiftUI

/// **Ask an Admin…** under a catalogue sheet's policy refusal (#2355): the kind and the name filled
/// in, a why to type, and Ask sends `governance/request` on the control plane, as Settings ▸
/// Policy's ask does (#2335). Once asked, the line says where the request stands instead, loaded
/// again on `control/governanceRequested`. Nothing without a control plane, or from one before
/// governance (it does not know `governance/requests`).
struct AskAdminButton: View {
    @Environment(AppModel.self) private var model

    let kind: DaemonAPI.CatalogKind
    let name: String
    /// Where it comes from: a registry id or a skill's repository, for the admin.
    var source: String?

    /// The person's own requests; nil until read, or from a control plane before them.
    @State private var requests: [DaemonAPI.CatalogRequest]?
    @State private var asking = false
    @State private var why = ""
    @State private var sending = false
    @State private var problem: String?

    private var isAdmin: Bool { model.people.you?.isAdmin == true }

    var body: some View {
        Group {
            if let requests {
                if let request = GovernanceWords.asked(requests, kind: kind, name: name) {
                    Text(GovernanceWords.mine(request, marketplacesLimited: model.policyState?.policy?.marketplaces != nil))
                        .appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(GovernanceWords.askAdmin) { asking = true }
                        .buttonStyle(.paper)
                        .help(GovernanceWords.askAdminHelp)
                        .disabled(GovernanceWords.request(kind: kind, name: name, why: "") == nil)
                        .popover(isPresented: $asking, arrowEdge: .bottom) { form }
                }
            } else {
                // Something to hang the task on: an empty Group has no view, so it would never load.
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: model.people.governanceRevision) { await load() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GovernanceWords.askFor(kind, name)).appText(.reading).fontWeight(.semibold)
            TextField("Why", text: $why, prompt: Text(GovernanceWords.whyPrompt))
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await send() } }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            Text(GovernanceWords.askFoot).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { asking = false }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                Button(GovernanceWords.ask) { Task { await send() } }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sending)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func load() async {
        guard let control = model.controlRequests else { requests = nil; return }
        guard let list = try? await control.call(DaemonAPI.Method.governanceRequests, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.CatalogRequestList.self) else { return }
        requests = GovernanceWords.own(list.requests, user: model.people.you?.id, isAdmin: isAdmin)
    }

    private func send() async {
        guard let control = model.controlRequests,
              let ask = GovernanceWords.request(kind: kind, name: name, why: why, source: source) else { return }
        sending = true
        defer { sending = false }
        do {
            let request = try await control.call(DaemonAPI.Method.governanceRequest, ask,
                                                 returning: DaemonAPI.CatalogRequest.self)
            requests = (requests ?? []) + [request]
            problem = nil
            asking = false
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}
