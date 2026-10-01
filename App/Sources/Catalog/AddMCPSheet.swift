import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// Add an MCP server from the registry (060, frames B and C).
struct AddMCPSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let destination: DaemonAPI.SkillDestination
    var onAdded: () -> Void = {}

    @State private var query = ""
    @State private var results: [DaemonAPI.MCPCatalogResult] = []
    @State private var searched = false
    @State private var searchError: DaemonAPI.MCPCatalogError?
    @State private var preview: DaemonAPI.MCPPreview?
    @State private var previewError: DaemonAPI.MCPCatalogError?
    @State private var opening: DaemonAPI.MCPCatalogResult?
    @State private var secretValues: [String: String] = [:]
    @State private var adding = false
    @State private var addError: String?

    static let size = CGSize(width: 720, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            if let preview {
                detailPane(preview)
            } else {
                searchPane
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Paper.ground)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add an MCP server").appText(.title)
                Spacer()
                Text("MCP servers").appText(.fine).foregroundStyle(.secondary)
            }
            TextField("Search the registry", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if let searchError {
                        Text(MCPCatalogWords.sentence(searchError)).appText(.fine).foregroundStyle(.secondary)
                    } else if results.isEmpty && searched {
                        Text("No servers match.").appText(.fine).foregroundStyle(.secondary)
                    }
                    ForEach(results) { result in
                        Button {
                            Task { await open(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(result.title).fontWeight(.semibold)
                                    if result.known {
                                        Text("known").appText(.fine).padding(.horizontal, 6)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    }
                                    Text(result.publisher.label).appText(.fine).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(result.version).appText(.fine).foregroundStyle(.secondary)
                                }
                                Text(result.description).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
                                HStack {
                                    ForEach(result.runs, id: \.self) { run in
                                        Text(run.rawValue).appText(.fine)
                                            .padding(.horizontal, 6).background(Color.secondary.opacity(0.12), in: Capsule())
                                    }
                                    if let host = result.remoteHost {
                                        Text("remote · \(host)").appText(.fine).tinted(.attention)
                                    }
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(opening?.id == result.id)
                    }
                }
            }
            HStack {
                Text("From registry.modelcontextprotocol.io. Choose one to see exactly what would run before adding.")
                    .appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
    }

    private func detailPane(_ preview: DaemonAPI.MCPPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("‹ Results") { self.preview = nil; secretValues = [:] }.buttonStyle(.paper)
                Text(preview.result.title).appText(.title)
                Spacer()
            }
            Text(preview.commandOrURL).appText(.code)
            if let host = preview.host {
                Text(host).appText(.fine).foregroundStyle(.secondary)
            }
            ForEach(preview.variables, id: \.name) { variable in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(variable.name).appText(.code)
                        Text(variable.kind == .secret ? "secret" : "optional").appText(.fine)
                        if variable.alreadySet { Text("set").appText(.fine).foregroundStyle(.secondary) }
                    }
                    Text(variable.description).appText(.fine).foregroundStyle(.secondary)
                    if variable.kind == .secret && !variable.alreadySet {
                        SecureField(variable.name, text: Binding(
                            get: { secretValues[variable.name] ?? "" },
                            set: { secretValues[variable.name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(8)
                .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if let addError { Text(addError).appText(.fine).tinted(.failure) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper)
                Button(addLabel(preview)) { Task { await add(preview) } }
                    .buttonStyle(.paperProminent)
                    .disabled(!canAdd(preview) || adding)
            }
        }
        .padding(18)
    }

    private func addLabel(_ preview: DaemonAPI.MCPPreview) -> String {
        switch destination {
        case .personal: return "Add to ~/.agents"
        case .project: return "Add to project"
        }
    }

    private func canAdd(_ preview: DaemonAPI.MCPPreview) -> Bool {
        if case .unmanaged = preview.destinationState { return false }
        for v in preview.variables where v.kind == .secret && v.required && !v.alreadySet {
            if (secretValues[v.name] ?? "").isEmpty { return false }
        }
        return preview.problems.isEmpty
    }

    private func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []; searched = false; searchError = nil; return
        }
        let answer = await model.mcpSearch(trimmed)
        results = answer.results
        searchError = answer.error
        searched = true
    }

    private func open(_ result: DaemonAPI.MCPCatalogResult) async {
        opening = result
        defer { opening = nil }
        let answer = await model.mcpPreview(result, for: destination, run: result.runs.first)
        if let preview = answer.preview {
            self.preview = preview
            previewError = nil
        } else {
            previewError = answer.error
        }
    }

    private func add(_ preview: DaemonAPI.MCPPreview) async {
        adding = true
        defer { adding = false }
        let replace = {
            switch preview.destinationState {
            case .managedSame, .managedOther: return true
            default: return false
            }
        }()
        switch await model.mcpAdd(preview.previewID, to: destination, secrets: secretValues, plain: [:], replace: replace) {
        case .success:
            onAdded()
            dismiss()
        case .failure(let error):
            addError = MCPCatalogWords.sentence(error)
        }
    }
}
