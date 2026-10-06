import AgentsKitCore
import SwiftUI

/// Add an MCP server that is not in the registry (#305): a name, a local command or a
/// remote URL, its env, arguments and headers. **Verify** connects before anything is
/// written; **Add** is only offered for what answered, as it answered.
extension DaemonAPI.MCPSignInTarget: @retroactive Identifiable {
    public var id: Self { self }
}

struct AddMCPByHandPane: View {
    @Environment(AppModel.self) private var model

    let destination: DaemonAPI.SkillDestination
    var onBack: () -> Void
    var onCancel: () -> Void
    var onAdded: () -> Void

    /// One env variable or header row.
    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
        var secret = false
    }

    @State private var name = ""
    @State private var kind: DaemonAPI.MCPHandServer.Kind = .command
    @State private var command = ""
    @State private var arguments = ""
    @State private var env: [Row] = []
    @State private var url = ""
    @State private var headers: [Row] = []

    @State private var verifying = false
    @State private var answer: DaemonAPI.MCPVerifyAnswer?
    /// What was verified: a change after it takes Add away until it is verified again.
    @State private var verified: DaemonAPI.MCPHandServer?
    @State private var adding = false
    @State private var addError: String?
    /// The server asked for a sign-in: Verify waits on it, then asks again (#306).
    @State private var signingIn: DaemonAPI.MCPSignInTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("‹ Registry") { onBack() }.buttonStyle(.paper)
                Text("Add a server by hand").appText(.title)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    form
                    outcome
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(footnote).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") { onCancel() }.buttonStyle(.paper).keyboardShortcut(.cancelAction)
                Button(verifying ? "Verifying…" : "Verify") { Task { await verify() } }
                    .buttonStyle(.paper)
                    .disabled(verifying || !canVerify)
                Button(addLabel) { Task { await add() } }
                    .buttonStyle(.paperProminent)
                    .disabled(adding || addableID == nil)
            }
        }
        .padding(18)
        .sheet(item: $signingIn) { target in
            MCPSignInSheet(target: target, onSignedIn: { Task { await verify() } })
        }
    }

    // MARK: The form

    @ViewBuilder private var form: some View {
        labelled("Name") {
            TextField("my-server", text: $name).textFieldStyle(.roundedBorder)
        }
        Picker("Runs as", selection: $kind) {
            Text("Local command").tag(DaemonAPI.MCPHandServer.Kind.command)
            Text("Remote URL").tag(DaemonAPI.MCPHandServer.Kind.url)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        switch kind {
        case .command:
            labelled("Command") {
                TextField("npx", text: $command).textFieldStyle(.roundedBorder).appText(.code)
            }
            labelled("Arguments") {
                TextField("-y @scope/server@1.0.0", text: $arguments).textFieldStyle(.roundedBorder)
                    .appText(.code)
            }
            rows("Environment", add: "Add variable", rows: $env, header: false)
        case .url:
            labelled("URL") {
                TextField("https://example.com/mcp", text: $url).textFieldStyle(.roundedBorder)
                    .appText(.code)
            }
            rows("Headers", add: "Add header", rows: $headers, header: true)
        }
    }

    private func labelled(_ label: String, @ViewBuilder _ field: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).appText(.fine).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
            field()
        }
    }

    private func rows(_ title: String, add: String, rows: Binding<[Row]>, header: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).appText(.fine).foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                Button(add) { rows.wrappedValue.append(Row()) }.buttonStyle(.paper).appText(.fine)
                Spacer()
            }
            ForEach(rows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 84)
                        TextField(header ? "Header" : "NAME", text: $row.name)
                            .textFieldStyle(.roundedBorder).frame(width: 160)
                        if row.secret {
                            SecureField("value (empty keeps the one already set)", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField("value", text: $row.value).textFieldStyle(.roundedBorder)
                        }
                        Toggle("Secret", isOn: $row.secret).toggleStyle(.checkbox).appText(.fine)
                        Button {
                            rows.wrappedValue.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(row.name.isEmpty ? (header ? "header" : "variable") : row.name)")
                    }
                    if row.secret, !row.name.isEmpty {
                        Text("Kept in ~/.agents/secrets.env as ${\(secretName(row, header: header))}; mcp.json names it.")
                            .appText(.fine).foregroundStyle(.secondary)
                            .padding(.leading, 90)
                    }
                }
            }
        }
    }

    // MARK: What Verify found

    @ViewBuilder private var outcome: some View {
        if let answer {
            VStack(alignment: .leading, spacing: 6) {
                if let error = answer.error {
                    Text(MCPCatalogWords.sentence(error)).appText(.fine).tinted(.failure)
                }
                switch answer.outcome {
                case .answered(let serverName, let version, let tools):
                    Label(answeredLine(serverName, version, tools.count), systemImage: "checkmark.circle")
                        .appText(.fine)
                    if !tools.isEmpty {
                        Text(tools.joined(separator: " · ")).appText(.code).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if verified != current {
                        Text("Changed since it was verified. Verify again to add it.")
                            .appText(.fine).tinted(.attention)
                    }
                case .authRequired:
                    Text("This server asks you to sign in before it answers. Once you have, it is verified again. Nothing was written.")
                        .appText(.fine).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sign in…") { signingIn = .url(name: current.name, url: current.url) }
                        .buttonStyle(.paper).appText(.fine)
                case .failed(let why):
                    Text("It did not answer: \(why) Nothing was written.").appText(.fine).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    EmptyView()
                }
                if let entry = answer.entry, let text = Self.pretty(entry, name: current.name) {
                    Text("What would be written").appText(.fine).foregroundStyle(.secondary)
                    Text(text).appText(.code).textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        if let addError {
            Text(addError).appText(.fine).tinted(.failure)
        }
    }

    private func answeredLine(_ serverName: String?, _ version: String?, _ count: Int) -> String {
        let who = [serverName, version].compactMap { $0 }.joined(separator: " ")
        let tools = count == 1 ? "1 tool" : "\(count) tools"
        return who.isEmpty ? "It answered, with \(tools)." : "\(who) answered, with \(tools)."
    }

    private static func pretty(_ entry: [String: JSONValue], name: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode([name: JSONValue.object(entry)]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Actions

    private var footnote: String {
        "Verify connects before anything is written. Secrets go to your own ~/.agents/secrets.env."
    }

    private var addLabel: String {
        switch destination {
        case .personal: "Add to ~/.agents"
        case .project: "Add to project"
        }
    }

    private var current: DaemonAPI.MCPHandServer {
        func values(_ rows: [Row], header: Bool) -> [DaemonAPI.MCPHandValue] {
            rows.filter { !$0.name.isEmpty || !$0.value.isEmpty }.map {
                .init(name: $0.name.trimmingCharacters(in: .whitespaces), value: $0.value, secret: $0.secret)
            }
        }
        switch kind {
        case .command:
            return .init(name: name.trimmingCharacters(in: .whitespaces), kind: .command,
                         command: command.trimmingCharacters(in: .whitespaces),
                         args: DaemonAPI.MCPHandServer.splitArguments(arguments), env: values(env, header: false))
        case .url:
            return .init(name: name.trimmingCharacters(in: .whitespaces), kind: .url,
                         url: url.trimmingCharacters(in: .whitespaces), headers: values(headers, header: true))
        }
    }

    private var canVerify: Bool {
        let server = current
        guard !server.name.isEmpty else { return false }
        return server.kind == .command ? !server.command.isEmpty : !server.url.isEmpty
    }

    /// The verified server to add, while the form still says what was verified.
    private var addableID: UUID? {
        guard let id = answer?.verifyID, verified == current else { return nil }
        return id
    }

    private func secretName(_ row: Row, header: Bool) -> String {
        DaemonAPI.MCPHandServer.defaultSecretName(server: name.trimmingCharacters(in: .whitespaces),
                                                  value: row.name.trimmingCharacters(in: .whitespaces), header: header)
    }

    private func verify() async {
        verifying = true
        addError = nil
        defer { verifying = false }
        let server = current
        answer = await model.mcpVerify(server, for: destination)
        verified = server
        if case .authRequired = answer?.outcome, signingIn == nil {
            signingIn = .url(name: server.name, url: server.url)
        }
    }

    private func add() async {
        guard let id = addableID else { return }
        adding = true
        defer { adding = false }
        switch await model.mcpAddByHand(id, to: destination) {
        case .success:
            onAdded()
        case .failure(let error):
            addError = MCPCatalogWords.sentence(error)
            // The verify is spent: ask for another.
            answer?.verifyID = nil
        }
    }
}
