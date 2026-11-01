import AgentsKitCore
import SwiftUI

/// Add a Machine… (#2131): one sheet with three ways in, a provider first. It is reached from
/// Settings ▸ Machines, Connectors set-up ▸ Where agents run, and a provider's New Machine…
/// (which opens it at that provider). Each way goes on in the same sheet, as the sheet it was
/// before: New Machine, Add Provider, Add a Machine, or the code.
struct AddMachineSheet: View {
    typealias Words = AddMachine.Words

    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel

    enum Step {
        case choose
        case provider(ProviderID)
        case addProvider
        case server(ControlAddServerSheet.Prefill?)
        case code
    }

    @State private var step: Step
    @State private var way: AddMachine.Way = .provider
    @State private var picked: ProviderID?

    /// `start` opens it at a step: New Machine… on a provider opens `.provider`.
    init(control: ControlSettingsModel, start: Step = .choose, way: AddMachine.Way = .provider) {
        self.control = control
        _step = State(initialValue: start)
        _way = State(initialValue: way)
    }

    var body: some View {
        switch step {
        case .choose:
            choose
        case .provider(let id):
            if let provider = control.providers.first(where: { $0.id == id }) {
                NewMachineSheet(control: control, provider: provider) { prefill in step = .server(prefill) }
            } else {
                choose
            }
        case .addProvider:
            AddProviderSheet(control: control) { added in
                picked = added ?? picked
                step = .choose
            }
        case .server(let prefill):
            ControlAddServerSheet(control: control, prefill: prefill)
        case .code:
            CodeSheet(control: control, purpose: .host)
        }
    }

    // MARK: Choose a way

    private var makers: [DaemonAPI.ProviderSummary] { MachineFromRepository.makers(control.providers) }
    private var chosenMaker: ProviderID? { picked.flatMap { id in makers.first { $0.id == id }?.id } ?? makers.first?.id }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(Words.title).appText(.title).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AddMachine.Way.allCases) { each in
                    wayRow(each)
                }
            }
            if way == .provider { providerPart }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(Words.next) { next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(way == .provider && (!control.providersHere || chosenMaker == nil))
            }
        }
        .padding(28)
        .frame(width: 560)
        .task { await control.listMachinesAgain() }
    }

    private func wayRow(_ each: AddMachine.Way) -> some View {
        Button { way = each } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: way == each ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(way == each ? Paper.accent : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Words.choice(each)).appText(.reading).fontWeight(.semibold)
                    Text(each == .provider ? control.providersOff ?? Words.note(each, ssh: true) : Words.note(each, ssh: true))
                        .appText(.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(way == each ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var providerPart: some View {
        if !control.providersHere {
            EmptyView()
        } else if makers.isEmpty {
            HStack(spacing: 10) {
                Text(control.isAdmin ? Words.noProviders : Words.noProvidersAskAdmin)
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if control.isAdmin {
                    Button(Words.addProvider) { step = .addProvider }.buttonStyle(.paper)
                }
            }
        } else {
            HStack(spacing: 10) {
                Picker("Provider", selection: Binding(get: { chosenMaker }, set: { picked = $0 })) {
                    ForEach(makers) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                if control.isAdmin {
                    Button(Words.addProvider) { step = .addProvider }.buttonStyle(.link)
                }
            }
            existing
        }
    }

    /// A machine the provider has already, running and not joined: today's Add as Machine….
    @ViewBuilder
    private var existing: some View {
        let provider = control.providers.first { $0.id == chosenMaker }
        let ready = provider?.workspaces.filter { $0.host == nil && $0.ssh != nil && $0.state == "running" } ?? []
        if let provider, !ready.isEmpty {
            Text(Words.existing).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(ready) { workspace in
                HStack {
                    Text(workspace.name).appText(.supporting)
                    Spacer()
                    Button("Add as Machine…") {
                        step = .server(.init(destination: workspace.ssh ?? "", name: workspace.name,
                                             tunnel: workspace.tunnel ?? false, provider: provider.id,
                                             workspace: workspace.id))
                    }
                    .buttonStyle(.paper)
                }
            }
        }
    }

    private func next() {
        switch way {
        case .provider: if let chosenMaker { step = .provider(chosenMaker) }
        case .server: step = .server(nil)
        case .code: step = .code
        }
    }
}
