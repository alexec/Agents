import AgentsKitCore
import SwiftUI

/// The parts that can be the same on every machine of the person's (#1760), at the end of
/// Machines on the Remote (#2157): each one's state, and Each Machine Its Own. The Mac has the
/// switch at the top of each part's own pane instead; the web page draws the same as this in
/// `Web/src/views/UserScope.tsx`.
struct UserPartsSection: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState

    @State private var problem: String?
    @State private var giving: DaemonAPI.UserSettingsPartName?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(UserScopeWords.agentConfigurationTitle).appText(.reading)
                Text(UserScopeWords.agentConfigurationDetail).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(UserScopeWords.agentConfigurationUpdated(state.settings?.agentConfigFiles?.updated))
                    .appText(.fine).foregroundStyle(.secondary)
            }
            ForEach(DaemonAPI.UserSettingsPartName.allCases.filter { $0 != .mcpServers && $0 != .agentConfig }, id: \.self) { part in
                VStack(alignment: .leading, spacing: 4) {
                    Text(UserScopeWords.partTitle(part)).appText(.reading)
                    Text(UserScopeWords.partDetail(part)).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(UserScopeWords.partState(state.settings?[part], updated: state.settings?.updated))
                            .appText(.fine)
                        Spacer()
                        if state.follows(part) {
                            Button(UserScopeWords.stop) { giving = part }
                                .disabled(control == nil)
                                .accessibilityIdentifier("stop-\(part.rawValue)")
                        }
                    }
                    .rowButtons()
                }
            }
            if let problem = problem ?? state.problem {
                Text(problem).appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(UserScopeWords.partsHeading)
        } footer: {
            Text(UserScopeWords.partsFoot).appText(.fine).foregroundStyle(.secondary)
        }
        .paperListRow()
        .task(id: control != nil) { await state.load(control) }
        .confirmationDialog(giving.map(UserScopeWords.stopTitle) ?? "",
                            isPresented: Binding(get: { giving != nil }, set: { if !$0 { giving = nil } }),
                            titleVisibility: .visible, presenting: giving) { part in
            Button(UserScopeWords.stop) { Task { problem = await state.set(part, to: .null, on: control) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(UserScopeWords.stopMessage)
        }
    }
}
