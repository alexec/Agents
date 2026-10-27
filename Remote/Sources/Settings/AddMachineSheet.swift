import AgentsKitCore
import SwiftUI
import UIKit

/// Add a Machine… (#2131), as the window's: a provider first, then a server by one command,
/// then another Mac by a code. A phone has no ssh, so a server is added by its command only.
struct AddMachineSheet: View {
    typealias Words = AddMachine.Words

    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addingProvider = false
    /// The providers there were before Add Provider…, to pick the new one after it.
    @State private var before: Set<ProviderID> = []
    @State private var picked: ProviderID?
    @State private var making = false

    private var oneCopy: Bool { model.machineProvidersProblem == MachineProviderWords.oneCopy }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { NewMachinePage(picked: nil, close: { dismiss() }) } label: { row(.provider) }
                        .disabled(oneCopy)
                    // Only an admin adds one (#1761).
                    if model.isAdmin, !oneCopy {
                        Button(Words.addProvider) { addProvider() }
                    }
                }
                Section {
                    NavigationLink { EnrollCodePage(command: true) } label: { row(.server) }
                    NavigationLink { EnrollCodePage(command: false) } label: { row(.code) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle(Words.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(isPresented: $making) { NewMachinePage(picked: picked, close: { dismiss() }) }
        }
        .task { await model.loadMachineProviders() }
        .sheet(isPresented: $addingProvider, onDismiss: providerAdded) { AddMachineProviderSheet(editing: nil) }
    }

    private func row(_ way: AddMachine.Way) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Words.choice(way))
            Text(way == .provider && oneCopy ? Words.needsControlPlane : Words.note(way, ssh: false))
                .appText(.supporting).foregroundStyle(.secondary)
        }
    }

    private func addProvider() {
        before = Set((model.machineProviders ?? []).map(\.id))
        addingProvider = true
    }

    /// A provider added here goes on to its New Machine (#2131), as the window's does.
    private func providerAdded() {
        Task {
            await model.loadMachineProviders()
            guard let added = model.machineProviders?.first(where: { !before.contains($0.id) }) else { return }
            picked = added.id
            making = true
        }
    }
}

/// New Machine on a provider: the shared sheet, with the repository optional (#2131).
struct NewMachinePage: View {
    @Environment(RemoteModel.self) private var model
    let picked: ProviderID?
    let close: () -> Void

    var body: some View {
        ScrollView {
            if let calls = model.machineCalls {
                MachineFromRepositorySheet(calls: calls, close: close, sentence: model.refusal, machine: true, picked: picked)
            } else {
                Text("The control plane isn’t answering.").padding()
            }
        }
        .background(Paper.ground)
        .navigationTitle(AddMachine.Words.machineTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A server's one command, or another Mac's code: `machines/startEnroll`, to copy.
private struct EnrollCodePage: View {
    typealias Words = AddMachine.Words

    @Environment(RemoteModel.self) private var model
    /// The command for a server; else the code.
    let command: Bool
    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var problem: String?
    @State private var copied = false

    private var line: String? { shown.map { command ? ($0.command ?? $0.text) : $0.text } }

    var body: some View {
        Form {
            Section {
                if let line {
                    Text(line).appText(.code).textSelection(.enabled)
                        .accessibilityLabel(command ? "Command" : "Code")
                    Button(copied ? "Copied" : "Copy") {
                        UIPasteboard.general.string = line
                        copied = true
                    }
                } else if let problem {
                    Text(problem).tinted(.failure)
                } else {
                    Text(Words.makingCode).foregroundStyle(.secondary)
                }
            } footer: {
                Text(command ? Words.serverNote : Words.codeNote)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(command ? Words.serverTitle : Words.codeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await make() }
    }

    private func make() async {
        guard let control = model.controlPlane else { return problem = "The control plane isn’t answering." }
        do {
            shown = try await control.call(DaemonAPI.Method.hostsStartEnroll, returning: DaemonAPI.ControlCodeShown.self)
        } catch {
            problem = model.refusal(error)
        }
    }
}
