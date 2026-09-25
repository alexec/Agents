import AgentsKitCore
import SwiftUI

/// Which runtime, and what it offers: the Mac's start controls, as rows (029).
///
/// Only what the runtime advertises is drawn, in the order the Mac draws it
/// (`PromptControlsState.drawable`), and each row names what it chooses. A runtime that
/// cannot start is still listed, with why, because one that silently is not there reads
/// as one the phone forgot.
struct ChoiceRows: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Section {
            runtimeRow
        }
        Section {
            switch model.startChoicesState {
            case .loading:
                Label("Asking \(runtimeName) what it offers…", systemImage: "hourglass")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).appText(.supporting).tinted(.failure)
                    Button("Try again") { Task { await model.loadStartChoices() } }
                        .appText(.supporting)
                        .accessibilityHint("Asks \(runtimeName) again what it offers")
                }
            case .ready:
                if model.startOptions.isEmpty {
                    Text("\(runtimeName) has nothing to adjust.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.startOptions, id: \.id) { option in
                    row(for: option)
                }
            }
        } footer: {
            if case .failed = model.startChoicesState, model.startRuntimeID != nil {
                Text("You can still start it with what \(runtimeName) chooses by itself.")
            }
        }
    }

    private var runtimeName: String {
        model.startRuntime?.runtime.name ?? PromptControlsState.unnamedRuntime
    }

    private var runtimeRow: some View {
        Menu {
            ForEach(model.runtimes) { status in
                Button {
                    Task { await model.chooseRuntime(status.runtime.id) }
                } label: {
                    Text(status.runtime.name)
                    if let reason = status.unavailableReason { Text(reason) }
                }
                .disabled(!status.availability.isAvailable)
            }
        } label: {
            LabeledContent("Runtime") {
                Text(model.startRuntime?.runtime.name ?? "None set up on the Mac")
                    .foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .disabled(model.runtimes.isEmpty)
        .accessibilityLabel("Runtime, \(model.startRuntime?.runtime.name ?? "none")")
    }

    @ViewBuilder
    private func row(for option: ConfigOption) -> some View {
        if option.isBoolean {
            Toggle(option.name, isOn: Binding(
                get: { model.startChosen[option.id]?.boolValue ?? option.currentValue?.boolValue ?? false },
                set: { model.choose(.bool($0), for: option.id) }))
                .appText(.reading)
        } else {
            let chosen = model.startChosen[option.id]
            Menu {
                ForEach(option.options ?? [], id: \.id) { choice in
                    Button {
                        model.choose(choice.value, for: option.id)
                    } label: {
                        if choice.value == chosen {
                            Label(choice.name, systemImage: "checkmark")
                        } else {
                            Text(choice.name)
                        }
                        if let description = choice.description { Text(description) }
                    }
                }
            } label: {
                LabeledContent(option.name) {
                    Text(option.closedTitle(for: chosen)).foregroundStyle(.secondary)
                }
                .appText(.reading)
            }
            .accessibilityLabel("\(option.name), \(option.closedTitle(for: chosen))")
        }
    }
}
