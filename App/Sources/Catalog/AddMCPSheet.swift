import AgentsKitCore
import SwiftUI

/// Add an MCP server from a marketplace (060, frames B and C; #687), or by hand (#305). The
/// connectors Agents makes are rows of the Agents marketplace like any other (#2155), and every
/// row shows the five levels it reaches (#1428).
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
    /// The result whose preview was refused, for Ask an Admin (#2355).
    @State private var refused: DaemonAPI.MCPCatalogResult?
    @State private var secretValues: [String: String] = [:]
    @State private var adding = false
    @State private var addError: String?
    @State private var byHand = false
    @State private var marketplaces: [DaemonAPI.Marketplace] = []
    @State private var managing = false
    /// The marketplace last searched, kept across sheets (#687).
    @AppStorage("catalog.mcp.marketplace", store: WindowDefaults.store) private var chosen = "provided:github-mcp"

    static let size = CGSize(width: 720, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            if managing {
                MarketplacesPane(kind: .mcp, destination: destination, back: {
                    managing = false
                    Task { await loadMarketplaces() }
                })
            } else if byHand {
                AddMCPByHandPane(destination: destination, onBack: { byHand = false },
                                 onCancel: { dismiss() }, onAdded: { onAdded(); dismiss() })
            } else if let preview {
                detailPane(preview)
            } else {
                searchPane
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Paper.ground)
        .task { await loadMarketplaces() }
        .task(id: SearchKey(query: query, marketplace: marketplace?.id)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private var searchPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add a connector").appText(.title)
                Spacer()
                MarketplaceMenu(marketplaces: marketplaces, chosen: $chosen, manage: { managing = true })
            }
            TextField("Search connectors", text: $query)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if marketplace == nil && !marketplaces.isEmpty {
                        Text("Every connector marketplace is off. Manage Marketplaces… in the menu turns one on.")
                            .appText(.fine).foregroundStyle(.secondary)
                    } else if let searchError {
                        Text(MCPCatalogWords.sentence(searchError)).appText(.fine).foregroundStyle(.secondary)
                    } else if let previewError {
                        previewProblem(previewError)
                    } else if results.isEmpty && searched {
                        Text("No connectors match.").appText(.fine).foregroundStyle(.secondary)
                    } else if !searched && marketplace?.format != .file {
                        Text("Type two letters or more to search.").appText(.fine).foregroundStyle(.secondary)
                    }
                    ForEach(results) { resultRow($0) }
                }
            }
            HStack {
                Text("From \(marketplace?.host ?? "no marketplace"). Choose one to see exactly what would run before adding.")
                    .appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Button("Add by hand…") { byHand = true }.buttonStyle(.paper)
                Button("Cancel") { dismiss() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
    }

    /// Why the chosen connector cannot be shown; the organisation's refusal offers Ask an Admin.
    private func previewProblem(_ error: DaemonAPI.MCPCatalogError) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(MCPCatalogWords.sentence(error)).appText(.fine)
                .foregroundStyle(error.policyWords == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if error.policyWords != nil, let refused {
                AskAdminButton(kind: .mcp, name: refused.title, source: refused.id)
            }
        }
    }

    private func resultRow(_ result: DaemonAPI.MCPCatalogResult) -> some View {
        Button {
            Task { await open(result) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(result.title).fontWeight(.semibold)
                    if result.known {
                        Text("known").appText(.fine).padding(.horizontal, 6)
                            .background(Paper.accent.opacity(0.15), in: Capsule())
                    }
                    Text(result.publisher.label).appText(.fine).foregroundStyle(.secondary)
                    Spacer()
                    Text(result.version).appText(.fine).foregroundStyle(.secondary)
                }
                Text(result.description).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    ConnectorLevels(levels: result.levels)
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

    private func detailPane(_ preview: DaemonAPI.MCPPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("‹ Results") { self.preview = nil; secretValues = [:] }.buttonStyle(.paper)
                Text(preview.result.title).appText(.title)
                Spacer()
            }
            ConnectorLevels(levels: preview.result.levels)
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
            if let addError {
                HStack(alignment: .firstTextBaseline) {
                    Text(addError).appText(.fine).tinted(.failure)
                    Spacer()
                    if GovernanceWords.refusedByPolicy(addError) {
                        AskAdminButton(kind: .mcp, name: preview.result.title, source: preview.result.id)
                    }
                }
            }
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
        case .folder: return "Add to folder"
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
        // A file (#2155) is short and lists all of itself with nothing typed; a registry needs two letters.
        guard trimmed.count >= 2 || marketplace?.format == .file else {
            results = []; searched = false; searchError = nil; return
        }
        guard let marketplace else {
            results = []; searched = false; searchError = nil
            return
        }
        let answer = await model.mcpSearch(trimmed, marketplace: marketplace.id, destination: destination)
        guard trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        results = answer.results
        searchError = answer.error
        previewError = nil
        searched = true
    }

    private var marketplace: DaemonAPI.Marketplace? {
        MarketplaceMenu(marketplaces: marketplaces, chosen: .constant(chosen), manage: {}).current
    }

    private func loadMarketplaces() async {
        if let answer = await model.marketplaces(.mcp, for: destination) { marketplaces = answer.marketplaces }
    }

    private func open(_ result: DaemonAPI.MCPCatalogResult) async {
        opening = result
        defer { opening = nil }
        let answer = await model.mcpPreview(result, for: destination, run: result.runs.first)
        if let preview = answer.preview {
            self.preview = preview
            previewError = nil
            refused = nil
        } else {
            previewError = answer.error
            refused = result
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

/// A search runs again when either the words or the marketplace change.
struct SearchKey: Hashable {
    var query: String
    var marketplace: String?
}
