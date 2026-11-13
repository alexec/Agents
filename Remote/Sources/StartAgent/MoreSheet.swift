import AgentsKitCore
import SwiftUI

/// What the ⋯ chip opens (#4556): the start's rarer choices, which a chip has no room
/// for — the runtime's own options, Permission requests, Reach and Labels. Half the
/// height, with the whole of it for a long list; a change here shows on ⋯ at once.
struct MoreSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: URL
    @Binding var labels: [String]
    /// Opened from a label's tag: scrolled to Labels.
    let atLabels: Bool

    @State private var folderPath = ""
    @State private var addingFolder = false
    @FocusState private var pathFocused: Bool
    @State private var confirmingAlwaysApprove = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    // The runtime's own choices; none on Auto, which has no runtime yet (#2658).
                    if !model.isAutoStart {
                        ownSection
                    }
                    permissionSection
                    reachSection
                    labelsSection
                        .id(Self.labelsID)
                }
                .paperForm()
                .onAppear {
                    if atLabels { proxy.scrollTo(Self.labelsID, anchor: .top) }
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private static let labelsID = "labels"

    private var runtimeName: String {
        model.startRuntime?.runtime.name ?? PromptControlsState.unnamedRuntime
    }

    private var ownSection: some View {
        Section {
            switch model.startChoicesState {
            case .loading:
                Label("Asking \(runtimeName) what it offers…", systemImage: "hourglass")
                    .appText(.supporting)
                    .foregroundStyle(Paper.secondary)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    SheetNote(text: reason, reservesSpace: false)
                    Button("Try again") { Task { await model.retryStartChoices() } }
                        .appText(.supporting)
                        .accessibilityHint("Asks \(runtimeName) again what it offers")
                }
            case .ready:
                if model.startOptions.isEmpty {
                    Text("\(runtimeName) has nothing to adjust.")
                        .appText(.supporting)
                        .foregroundStyle(Paper.secondary)
                }
                ForEach(model.startOptions, id: \.id) { option in
                    row(for: option)
                }
            }
        } header: {
            Text(LevelWords.own(runtimeName))
        } footer: {
            if case .failed = model.startChoicesState, model.startRuntimeID != nil {
                Text("You can still start it with what \(runtimeName) chooses by itself.")
            }
        }
        .paperListRow()
    }

    /// The new agent's answer to permission requests (#2658, FR-019): its own, or the value
    /// Settings gives, marked; only for Cursor, Grok and OpenCode, and not on Auto, where it
    /// follows the permission mode.
    @ViewBuilder
    private var permissionSection: some View {
        if let runtimeID = model.startRuntimeID, ClientPermissionSettings.supports(runtimeID) {
            let name = model.startRuntime?.runtime.name ?? runtimeID
            let settings = model.clientPermissions.mode(for: runtimeID)
            let mode = model.startClientPermission ?? settings
            Section {
                Menu {
                    ForEach([ClientPermissionMode.default, .alwaysApprove], id: \.self) { choice in
                        Button {
                            if choice == .alwaysApprove, mode != .alwaysApprove {
                                confirmingAlwaysApprove = true
                            } else {
                                model.startClientPermission = model.startClientPermission == nil && choice == settings ? nil : choice
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                if choice == mode {
                                    Label(ClientPermissionWords.title(choice), systemImage: "checkmark")
                                } else {
                                    Text(ClientPermissionWords.title(choice))
                                }
                                Text(model.startClientPermission == nil && choice == settings
                                     ? "\(LevelWords.followsSettings). \(ClientPermissionWords.description(choice, runtimeName: name))"
                                     : ClientPermissionWords.description(choice, runtimeName: name))
                                    .appText(.supporting)
                            }
                        }
                    }
                } label: {
                    LabeledContent(LevelWords.requestsField) {
                        Text(ClientPermissionWords.title(mode)).foregroundStyle(Paper.secondary)
                    }
                    .appText(.reading)
                }
                .accessibilityLabel("\(ClientPermissionWords.name(runtimeName: name)), \(ClientPermissionWords.title(mode))")
                .accessibilityHint(ClientPermissionWords.scope(runtimeName: name))
                // Always Approve answers every request: one more tap, as the capsule asks (#2746).
                .confirmationDialog(ClientPermissionWords.confirmTitle(runtimeName: name),
                                    isPresented: $confirmingAlwaysApprove, titleVisibility: .visible) {
                    Button(ClientPermissionWords.confirmButton, role: .destructive) {
                        model.startClientPermission = settings == .alwaysApprove ? nil : .alwaysApprove
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(ClientPermissionWords.confirmMessage(runtimeName: name))
                }
            }
            .paperListRow()
        }
    }

    /// The folder itself, then each folder added, then a way to add one: a path, typed,
    /// which is why it is here and not in a chip.
    private var reachSection: some View {
        Section("Reach") {
            // By name, as the title says it: the whole path is the long part of every row.
            LabeledContent(folder.lastPathComponent) {
                Text("This folder").foregroundStyle(Paper.secondary)
            }
            .lineLimit(1)
            ForEach(model.startFolders, id: \.self) { added in
                HStack {
                    Text(added.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove") { model.startFolders.removeAll { $0 == added } }
                }
            }
            if addingFolder {
                HStack {
                    TextField("Folder path", text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($pathFocused)
                        .onSubmit(addFolder)
                    Button("Add", action: addFolder)
                        .disabled(folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button("Add a folder…") {
                    addingFolder = true
                    pathFocused = true
                }
            }
        }
        .appText(.reading)
        .paperListRow()
    }

    private func addFolder() {
        guard !folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let added = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
        if added != folder, !model.startFolders.contains(added) { model.startFolders.append(added) }
        folderPath = ""
        addingFolder = false
    }

    private var labelsSection: some View {
        Section("Labels") {
            LabelTagField(labels: labels.map { SessionLabel(value: $0, owner: .person) },
                          suggestions: model.labelSuggestions(in: folder),
                          add: { labels += $0 },
                          remove: { value in
                              labels.removeAll { SessionLabelPolicy.key($0) == SessionLabelPolicy.key(value) }
                          })
        }
        .paperListRow()
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
                    if let mark = choice.setBy {
                        // A mode or model the organisation refuses: shown, not chosen (#998).
                        OrgPolicyMenuItem(name: choice.name, mark: mark)
                    } else {
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
                }
            } label: {
                LabeledContent(option.name) {
                    Text(option.closedTitle(for: chosen)).foregroundStyle(Paper.secondary)
                }
                .appText(.reading)
            }
            .accessibilityLabel("\(option.name), \(option.closedTitle(for: chosen))")
        }
    }
}

extension RemoteModel {
    /// Auto looked, and no runtime can take the session (#2658).
    var startAutoPicksNothing: Bool {
        isAutoStart && startAutoPreview != nil && startAutoPreview?.runtimeID == nil
    }

    /// The runtimes' allowances are the Mac's own, and would label a server's runtime with
    /// the Mac's state (#240): only a Mac folder's runtimes are split into Available and Out.
    var startSplitsByAllowance: Bool { startHost == .mac }

    /// Before the first prompt, that the runtime chosen is out (052, US3; 065), in the
    /// Mac's bar's words. Send still sends: there is no other runtime to offer.
    var startRuntimeOut: String? {
        guard !isAutoStart, startSplitsByAllowance, let startRuntimeID else { return nil }
        return runtimeAllowances?.startingOnOut(startRuntimeID)
    }
}
