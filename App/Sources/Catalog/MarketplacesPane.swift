import AgentsKitCore
import SwiftUI

/// Which marketplace a catalogue sheet searches (#687), and the way to the list of them.
struct MarketplaceMenu: View {
    let marketplaces: [DaemonAPI.Marketplace]
    @Binding var chosen: String
    var manage: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Marketplace").foregroundStyle(.secondary).fixedSize()
            Menu {
                ForEach(marketplaces.filter(\.enabled)) { marketplace in
                    Button {
                        chosen = marketplace.id
                    } label: {
                        if marketplace.id == current?.id {
                            Label(marketplace.name, systemImage: "checkmark")
                        } else {
                            Text(marketplace.name)
                        }
                    }
                }
                Divider()
                Button("Manage Marketplaces…", action: manage)
            } label: {
                Text(current?.name ?? "None on")
            }
            .fixedSize()
            .accessibilityLabel("Marketplace")
        }
    }

    /// The one chosen, or the first on when that one is gone or off.
    var current: DaemonAPI.Marketplace? {
        let on = marketplaces.filter(\.enabled)
        return on.first { $0.id == chosen } ?? on.first
    }
}

/// The marketplaces for one kind (#687): the app's own, the person's, and the folder's,
/// each with a switch; the person's own can be removed, and more added.
struct MarketplacesPane: View {
    @Environment(AppModel.self) private var model

    let kind: DaemonAPI.CatalogKind
    let destination: DaemonAPI.SkillDestination
    var back: () -> Void

    @State private var answer: DaemonAPI.MarketplacesListAnswer?
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("‹ Back", action: back).buttonStyle(.paper)
                Text(kind == .mcp ? "Connector marketplaces" : "Skill marketplaces").appText(.title)
                Spacer()
                if !adding {
                    Button("Add Marketplace…") { adding = true }.buttonStyle(.paper)
                }
            }
            Text(kind == .mcp
                 ? "Add Connector… searches the one chosen in its menu. Any MCP Registry can be added, such as your company's own."
                 : "Add skill… searches the one chosen in its menu. A GitHub repository of skills can be added too.")
                .appText(.fine).foregroundStyle(.secondary)
            if adding {
                AddMarketplaceForm(kind: kind, cancel: { adding = false }, added: {
                    adding = false
                    Task { await load() }
                })
            }
            if let problem { Text(problem).appText(.fine).tinted(.failure) }
            if let note = answer?.problem { Text(note).appText(.fine).tinted(.attention) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(answer?.marketplaces ?? []) { marketplace in row(marketplace) }
                }
            }
        }
        .padding(18)
        .task { await load() }
    }

    private func row(_ marketplace: DaemonAPI.Marketplace) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(marketplace.name, isOn: Binding(
                get: { marketplace.enabled },
                set: { on in Task { await setEnabled(marketplace, on) } }))
                .toggleStyle(.switch).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(marketplace.name).fontWeight(.semibold)
                    SharedChip(text: originWord(marketplace.origin), tone: marketplace.origin == .provided ? .plain : .source)
                    if marketplace.tokenMissing, let token = marketplace.token {
                        SharedChip(text: "\(token) not set", tone: .attention)
                    }
                }
                Text(marketplace.url).appText(.code).foregroundStyle(.secondary).lineLimit(1)
                if let about = marketplace.about {
                    Text(about).appText(.fine).foregroundStyle(.secondary)
                } else if marketplace.origin == .folder && !marketplace.enabled {
                    Text("Committed with the folder. Turn it on to search it\(marketplace.token.map { " with your \($0)" } ?? "").")
                        .appText(.fine).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if marketplace.origin == .personal {
                Button("Remove") { Task { await remove(marketplace) } }.buttonStyle(.paper)
            }
        }
        .padding(8)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(marketplace.name), \(originWord(marketplace.origin)), \(marketplace.enabled ? "on" : "off")")
    }

    private func originWord(_ origin: DaemonAPI.MarketplaceOrigin) -> String {
        switch origin {
        case .provided: "provided"
        case .personal: "yours"
        case .folder: "folder"
        }
    }

    private func load() async {
        answer = await model.marketplaces(kind, for: destination)
    }

    private func setEnabled(_ marketplace: DaemonAPI.Marketplace, _ on: Bool) async {
        problem = await model.setMarketplace(marketplace.id, enabled: on)
        await load()
    }

    private func remove(_ marketplace: DaemonAPI.Marketplace) async {
        problem = await model.removeMarketplace(marketplace.id)
        await load()
    }
}

/// One of the person's own, into `~/.agents/marketplaces.json`.
private struct AddMarketplaceForm: View {
    @Environment(AppModel.self) private var model

    let kind: DaemonAPI.CatalogKind
    var cancel: () -> Void
    var added: () -> Void

    @State private var name = ""
    @State private var format: DaemonAPI.MarketplaceFormat = .mcpRegistry
    @State private var url = ""
    @State private var token = ""
    @State private var tokenValue = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if kind == .skills {
                Picker("Kind", selection: $format) {
                    Text("GitHub repository").tag(DaemonAPI.MarketplaceFormat.gitHubSkills)
                    Text("skills.sh-compatible").tag(DaemonAPI.MarketplaceFormat.skillsSh)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            } else {
                // A registry, or a file in its shape (#2155), such as a team's in its repository.
                Picker("Kind", selection: $format) {
                    Text("A registry").tag(DaemonAPI.MarketplaceFormat.mcpRegistry)
                    Text("A file on this machine").tag(DaemonAPI.MarketplaceFormat.file)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            TextField("Name, such as Acme", text: $name).textFieldStyle(.roundedBorder)
            TextField(placeholder, text: $url)
                .textFieldStyle(.roundedBorder)
            if format == .file {
                Text("A JSON file, or a folder of them, in the MCP Registry's shape. A path from ~/ or a full path.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if format != .gitHubSkills && format != .file {
                HStack {
                    TextField("Token name, if it needs one (ACME_MCP_TOKEN)", text: $token).textFieldStyle(.roundedBorder)
                    SecureField("Token", text: $tokenValue).textFieldStyle(.roundedBorder)
                        .disabled(token.isEmpty)
                }
                Text("The token goes in ~/.agents-secrets/secrets.env and is sent as a bearer token to this address only. Leave both empty if it is open.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            if let problem { Text(problem).appText(.fine).tinted(.failure) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.paper)
                Button("Add") { Task { await add() } }
                    .buttonStyle(.paperProminent)
                    .disabled(name.isEmpty || url.isEmpty || saving)
            }
        }
        .padding(10)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { format = kind == .mcp ? .mcpRegistry : .gitHubSkills }
    }

    private var placeholder: String {
        switch format {
        case .gitHubSkills: "owner/repo"
        case .file: "~/team/connectors.json"
        default: "https://mcp.example.com"
        }
    }

    private func add() async {
        saving = true
        defer { saving = false }
        let request = DaemonAPI.MarketplaceAddRequest(
            name: name, format: format, url: url,
            token: format == .gitHubSkills || format == .file || token.isEmpty ? nil : token,
            tokenValue: format == .gitHubSkills || format == .file || tokenValue.isEmpty ? nil : tokenValue)
        if let reason = await model.addMarketplace(request) {
            problem = reason
        } else {
            added()
        }
    }
}
