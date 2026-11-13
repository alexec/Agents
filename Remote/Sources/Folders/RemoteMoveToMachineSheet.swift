import AgentsKitCore
import SwiftUI

/// Move to Machine… (#4037), from a row's long press or the chat's ···, as the window's sheet
/// (#3790): the machine, from the Machines group (#4034), and the folder there. Its host stops
/// the turn if one runs, sends the branch with its uncommitted changes, and the session goes on
/// there with this conversation.
struct RemoteMoveToMachineSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    @State private var machine: MachineRef?
    @State private var folder = ""
    @State private var moving = false
    @State private var problem: String?

    private var targets: [MachineRef] { model.moveTargets(for: agent) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                if targets.isEmpty {
                    Section {
                        Text(MoveToMachineWords.noTargets).foregroundStyle(Paper.secondary)
                    }
                } else {
                    Section {
                        Picker("Machine", selection: $machine) {
                            ForEach(targets, id: \.self) { host in
                                Text(model.machineName(host)).tag(Optional(host))
                            }
                        }
                        .disabled(moving)
                    } header: {
                        Text(MoveToMachineWords.title(agent.title)).textCase(nil)
                    }
                    Section {
                        TextField(MoveToMachineWords.folderPlaceholder, text: $folder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(moving)
                            .accessibilityLabel(MoveToMachineWords.folderLabel)
                    } header: {
                        Text(MoveToMachineWords.folderLabel)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(MoveToMachineWords.folderHelp)
                            Text(MoveToMachineWords.whatGoes(stops: model.canStop(agent)))
                            // The sheet's note (#4737): it failed, or it is moving.
                            SheetNote(tone: problem == nil ? .neutral : .failure,
                                      text: problem ?? (moving ? MoveToMachineWords.moving : nil))
                        }
                    }
                }
            }
            .navigationTitle(MoveToMachineWords.barTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(moving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if moving {
                        ProgressView()
                    } else {
                        Button("Move") { Task { await move() } }
                            .disabled(machine == nil)
                    }
                }
            }
        }
        .interactiveDismissDisabled(moving)
        .onAppear { machine = machine ?? targets.first }
    }

    private func move() async {
        guard let machine else { return }
        problem = nil
        moving = true
        do {
            try await model.moveToMachine(agent, machine: machine, folder: folder)
            dismiss()
        } catch {
            moving = false
            problem = model.moveProblem(error)
        }
    }
}

/// Move to Machine… (#4037): in a row's long press, and the chat's ···, where the session's
/// host can move it.
struct MoveToMachineButton: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        if model.moveTargets(for: agent) != nil {
            Button(MoveToMachineWords.menu, systemImage: MoveToMachineWords.symbol) { model.movingToMachine = agent }
                .disabled(model.acting(agent.id) != nil)
        }
    }
}
