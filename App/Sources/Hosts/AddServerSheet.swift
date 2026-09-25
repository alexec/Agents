import AgentsKit
import SwiftUI

/// Add a server (037, wireframes/mac-add-server.svg): one field, then a checklist that
/// ticks down in place. Nothing opens a second window, and Cancel at any point leaves
/// nothing behind.
struct AddServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: AddServerFlow?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let flow {
                content(flow)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if flow == nil { flow = AddServerFlow(locations: .default, hosts: model.hosts) }
            isFocused = true
        }
    }

    @ViewBuilder
    private func content(_ flow: AddServerFlow) -> some View {
        @Bindable var flow = flow
        switch flow.phase {
        case .name:
            Text("Add a server").appText(.reading).fontWeight(.semibold)
            TextField("devbox", text: $flow.name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { connect(flow) }
            VStack(alignment: .leading, spacing: 4) {
                Text("An alias from ~/.ssh/config, or user@host.")
                Text("Agents uses your own ssh setup: keys, agent, jump hosts.")
            }
            .appText(.fine).foregroundStyle(.secondary)
            buttons {
                Button("Connect") { connect(flow) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canConnect)
            }

        case .trust(let fingerprint):
            Text("Add \(flow.label)").appText(.reading).fontWeight(.semibold)
            step("Connect", .current)
            VStack(alignment: .leading, spacing: 6) {
                Text("First time connecting to \(flow.label).")
                Text("Its host key fingerprint is").foregroundStyle(.secondary)
                Text(fingerprint).appText(.code).textSelection(.enabled)
                Text("Check it matches the server.").foregroundStyle(.secondary)
            }
            .appText(.fine)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            step("Check the system", .waiting)
            buttons {
                Button("Trust and continue") { Task { await flow.trust() } }
                    .keyboardShortcut(.defaultAction)
            }

        case .working(let current):
            Text("Add \(flow.label)").appText(.reading).fontWeight(.semibold)
            checklist(flow, current: current)
            buttons { EmptyView() }

        case .ready(let runtimes):
            Text("Add \(flow.label)").appText(.reading).fontWeight(.semibold)
            step("Connect", .done)
            step("Check the system", .done, detail: flow.system)
            step("Set up", .done)
            if runtimes.isEmpty {
                step("Find agent runtimes", .warning,
                     detail: "No agent runtime on \(flow.label). Install one there and log in, then choose Check again.")
                HStack {
                    Spacer()
                    Button("Check again") { Task { await flow.findRuntimes() } }
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                step("Find agent runtimes", .done, detail: runtimes.joined(separator: " · "))
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }

        case .failed(let problem, let at):
            Text("Add \(flow.label)").appText(.reading).fontWeight(.semibold)
            step(title(at), .failed, detail: problem.sentence(name: flow.trimmedName, label: flow.label))
            TextField("devbox", text: $flow.name)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
            buttons {
                if problem.offersTryAgain {
                    Button("Try again") { connect(flow) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ServerHost.isValid(flow.trimmedName))
                }
            }
        }
    }

    private func connect(_ flow: AddServerFlow) {
        guard ServerHost.isValid(flow.trimmedName) else { return }
        Task { await flow.connect() }
    }

    @ViewBuilder
    private func checklist(_ flow: AddServerFlow, current: ServerConnection.Step) -> some View {
        ForEach([ServerConnection.Step.connect, .checkSystem, .setUp, .findRuntimes], id: \.self) { step in
            let mark: Mark = flow.done.contains(step) ? .done : step == current ? .current : .waiting
            self.step(title(step), mark, detail: step == .checkSystem && mark == .done ? flow.system : nil)
        }
    }

    private func title(_ step: ServerConnection.Step) -> String {
        switch step {
        case .connect: "Connect"
        case .checkSystem: "Check the system"
        case .setUp: "Set up"
        case .findRuntimes: "Find agent runtimes"
        }
    }

    private enum Mark { case done, current, waiting, warning, failed }

    private func step(_ title: String, _ mark: Mark, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                switch mark {
                case .done: Image(systemName: "checkmark").tinted(.vouched)
                case .current: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .warning: Image(systemName: "exclamationmark").tinted(.attention)
                case .failed: Image(systemName: "xmark").tinted(.failure)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.reading).foregroundStyle(mark == .waiting ? .tertiary : .primary)
                if let detail {
                    Text(detail).appText(.fine)
                        .foregroundStyle((mark == .failed ? StateTint.failure : .none).style(or: .secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func buttons<Extra: View>(@ViewBuilder _ extra: () -> Extra) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                let flow = flow
                dismiss()
                Task { await flow?.cancel() }
            }
            .keyboardShortcut(.cancelAction)
            extra()
        }
        .padding(.top, 4)
    }
}
