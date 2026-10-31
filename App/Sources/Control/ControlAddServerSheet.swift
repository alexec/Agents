import AgentsKitCore
import AppKit
import SwiftUI

/// Add a Machine (058, US4, T074; frames M and M2).
///
/// - **Run a command**, the usual way: the server installs itself and connects out, so
///   nothing has to reach it. The command carries a one-time join code, and the sheet
///   closes by itself when the server joins.
/// - **Over ssh**, for a server the person can already ssh to (#610): the control plane
///   installs the host once and keeps neither a key nor the session. The server box offers
///   the hosts in `~/.ssh/config` (#429), each with what ssh resolves it to, and takes
///   anything typed. A key already in known_hosts is used; a new one is shown and trusted;
///   a changed one is refused. The key is optional when the control plane is on this Mac:
///   its ssh is the person's, with their agent, config and default identity (#413). One
///   elsewhere has none of those, so needs a key.
/// - **Use an ssh tunnel**: a server that cannot dial back, as one behind a bastion rarely
///   can (#435), connects through a reverse tunnel the control plane holds over ssh. On by
///   default for a `ProxyJump` or `ProxyCommand` host; anyone can turn it on (#610). Only a
///   control plane on this Mac holds one.
struct ControlAddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel
    /// A provider's workspace being added as a host (#691, Add as Host…): over ssh, with what
    /// the provider gave filled in, and linked to it once it joins.
    var prefill: Prefill?
    /// A host that needs an update, updated over ssh as it was installed (#1766): the
    /// server and key asked again, and no code, name or tunnel.
    var updating: DaemonAPI.ControlMachine?

    struct Prefill: Identifiable {
        var destination: String
        var name: String
        var tunnel: Bool
        var provider: ProviderID?
        var workspace: String?
        var id: String { "\(provider?.rawValue ?? "server")/\(workspace ?? name)" }

        /// `alex@127.0.0.1 -p 2222`, as a provider may give it, as ssh takes it in one word.
        var sshDestination: String {
            let words = destination.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count == 3, words[1] == "-p", let port = Int(words[2]) else { return destination }
            return "ssh://\(words[0]):\(port)"
        }
    }

    enum Way: Hashable { case command, ssh }
    @State private var way: Way = .command

    // Run a command
    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var before: Set<MachineRef> = []
    @State private var joined: String?
    /// The host that joined, once it has: the sheet's last step picks its folders (#656).
    @State private var joinedHost: MachineRef?

    // Over ssh
    @State private var destination = ""
    @State private var name = ""
    @State private var keyPath = ""
    @State private var keyURL: URL?
    @State private var working = false
    @State private var fingerprint: String?
    @State private var outcome: ControlSettingsModel.InstallOutcome?
    /// The ssh config's hosts, for the server box (#610).
    @State private var configHosts: [DaemonAPI.SSHHost] = []
    /// What ssh makes of what is typed, once typing pauses.
    @State private var typed: DaemonAPI.SSHHost?
    @State private var tunnel = false
    /// Once the person sets the tunnel, it is theirs: the server box no longer moves it.
    @State private var tunnelChosen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(updating.map { "Update \($0.name)" } ?? "Add a Machine").appText(.title).fontWeight(.semibold)
            if updating != nil {
                sshPage
            } else if let joinedHost, let joined {
                Label("\(joined) joined.", systemImage: "checkmark.circle.fill").appText(.reading).tinted(.vouched)
                HostFoldersPicker(host: joinedHost, hostName: joined, paths: control.suggestedPaths,
                                   leaveTitle: "Skip") { dismiss() }
            } else {
                Picker("How", selection: $way) {
                    Text("Run a command").tag(Way.command)
                    Text("Over ssh").tag(Way.ssh)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                switch way {
                case .command: commandPage
                case .ssh: sshPage
                }
            }
        }
        .padding(28)
        .frame(width: 620)
        // An update makes no join code: the host keeps its membership.
        .task { if updating == nil { await watchForJoin() } }
        .onAppear {
            if let updating {
                way = .ssh
                name = updating.name
                return
            }
            guard let prefill else { return }
            way = .ssh
            destination = prefill.sshDestination
            name = prefill.name
            tunnel = prefill.tunnel
            tunnelChosen = true
        }
    }

    // MARK: M · Run a command

    @ViewBuilder
    private var commandPage: some View {
        Text("On the machine, as the user your agents should run as:")
            .appText(.reading).foregroundStyle(.secondary)
        if let command = shown?.command ?? shown.map({ "agentsd --control-code '\($0.text)'" }) {
            Text(command)
                .appText(.code)
                .textSelection(.enabled)
                .lineLimit(4)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)) }
                // One element of its own: a label on the selectable Text overflows the stack (#1724).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Command")
                .accessibilityValue(command)
            HStack(spacing: 12) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(.paper)
                if let expires = shown?.expires {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Works once, for \(Self.left(until: expires, now: context.date)) · Linux, arm64 or x86-64")
                            .appText(.supporting).foregroundStyle(.secondary)
                    }
                }
            }
        } else if control.problem == nil {
            ProgressView().controlSize(.small)
        }
        if let joined {
            Label("\(joined) joined.", systemImage: "checkmark.circle.fill").appText(.reading).tinted(.vouched)
        } else if shown != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Waiting for the machine to connect…").appText(.reading)
            }
        }
        if let problem = control.problem {
            Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            Button(joined == nil ? "Cancel" : "Done") { dismiss() }.buttonStyle(.paper)
        }
    }

    /// Makes the code once, then watches for a host that was not there before, and goes on
    /// to its folders when one joins (#656).
    private func watchForJoin() async {
        await control.refresh()
        before = Set(control.hosts.map(\.id))
        shown = await control.startCode(forHost: true)
        while !Task.isCancelled, joined == nil {
            try? await Task.sleep(for: .seconds(2))
            await control.refresh()
            guard way == .command || outcome != nil else { continue }
            if let new = control.hosts.first(where: { !before.contains($0.id) && $0.answers }) {
                joined = new.name
                // A moment to read "joined" on the page it happened on.
                try? await Task.sleep(for: .seconds(1.5))
                joinedHost = new.id
            }
        }
    }

    static func left(until expires: Date, now: Date) -> String {
        let seconds = max(0, Int(expires.timeIntervalSince(now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: M2 · Over ssh

    @ViewBuilder
    private var sshPage: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Machine").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField(configHosts.isEmpty ? "agents@devbox.lan" : "A host from ~/.ssh/config, or user@host:port",
                          text: $destination)
                    .textFieldStyle(.roundedBorder).appText(.code)
                    .textInputSuggestions {
                        ForEach(suggestions) { host in
                            HStack {
                                Text(host.alias)
                                if host.resolved != host.alias {
                                    Text(host.resolved).foregroundStyle(.secondary)
                                }
                                if host.known { Text("· already a machine").foregroundStyle(.secondary) }
                            }
                            .textInputCompletion(host.alias)
                        }
                    }
                    .accessibilityLabel("Machine").disabled(working || fingerprint != nil)
            }
            if let resolvedLine {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(resolvedLine).appText(.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if updating == nil {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField(HostNameGuess.from(destination), text: $name).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name").disabled(working)
                }
            }
            GridRow {
                Text("Key").foregroundStyle(.secondary)
                HStack {
                    TextField(keyOptional ? "Optional" : "~/.ssh/id_ed25519", text: $keyPath)
                        .textFieldStyle(.roundedBorder).appText(.code)
                        .accessibilityLabel("Key").disabled(working)
                    Button("Choose…") { chooseKey() }.buttonStyle(.paper).disabled(working)
                }
            }
            if control.isOnThisMac, updating == nil {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("Use an ssh tunnel", isOn: Binding(get: { tunnel }, set: { tunnel = $0; tunnelChosen = true }))
                        .disabled(working || isDone)
                        .help("For a machine that can’t reach this Mac: it connects through ssh instead.")
                }
            }
        }
        .task { configHosts = control.isOnThisMac ? await control.sshHosts() : [] }
        .task(id: destination) { await resolveTyped() }
        if let updating {
            Text("The machine \(updating.name) runs on, as you reach it over ssh. The control plane checks it is \(updating.name), copies its version of Agents there and starts it again. Its agents and folders stay. The key is used for this update only and not kept.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
        Text(keyOptional
             ? "With no key, ssh logs in as it does from Terminal: your agent, ~/.ssh/config or default key. A key chosen here is used instead, for this install only. Afterwards the machine connects to the control plane by itself, or, with a tunnel, through ssh the control plane keeps open."
             : "The control plane runs on another machine, so it needs the key: it is used for this install only and not kept. Afterwards the machine connects to the control plane by itself.")
            .appText(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let fingerprint {
            VStack(alignment: .leading, spacing: 6) {
                Text("This machine’s key isn’t in your known_hosts. Its key is:").appText(.supporting)
                Text(fingerprint).appText(.code).textSelection(.enabled)
                Text("Install only if this is the key the machine shows (ssh-keygen -lf on its host key).")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if working {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(stepWords(control.installStep)).appText(.supporting).foregroundStyle(.secondary)
            }
        }
        switch outcome {
        case .added(let named, let tunnel)?:
            Text(joined.map { "\($0) joined." } ?? "Installed on \(named). Waiting for it to connect…")
                .appText(.supporting).tinted(.vouched)
            if tunnel { tunnelLine(named) }
        case .updated(let named)?:
            Text("Updated \(named). It starts again with this control plane’s version.")
                .appText(.supporting).tinted(.vouched)
        case .failed(let why)?:
            Text(why).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
        HStack {
            Spacer()
            Button(isDone ? "Done" : "Cancel") { dismiss() }.buttonStyle(.paper)
            if !isDone {
                Button(updating != nil ? (fingerprint == nil ? "Update" : "Trust and Update")
                       : (fingerprint == nil ? "Install" : "Trust and Install")) { install() }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || destination.trimmingCharacters(in: .whitespaces).isEmpty || (keyPath.isEmpty && !keyOptional))
            }
        }
    }

    /// A server that dials back through a tunnel: how that tunnel stands (#435, #610).
    @ViewBuilder
    private func tunnelLine(_ named: String) -> some View {
        let lead = "\(named) connects through a tunnel the control plane holds over ssh."
        switch control.tunnels[named] {
        case let state? where !state.up:
            Text("\(lead) That ssh session is down\(state.problem.map { ": \($0)" } ?? ""). It is tried again by itself.")
                .appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        default:
            Text("\(lead) It is offline whenever that session is down, as when this Mac sleeps.")
                .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only a control plane on this Mac has the person's ssh to fall back on.
    private var keyOptional: Bool { control.isOnThisMac }

    /// The config's servers that match what is typed: bastions are a way in, not servers.
    private var suggestions: [DaemonAPI.SSHHost] {
        let text = destination.trimmingCharacters(in: .whitespaces).lowercased()
        let servers = configHosts.filter { !$0.isBastion }
        guard !text.isEmpty else { return servers }
        if servers.contains(where: { $0.alias.lowercased() == text }) { return [] }
        return servers.filter { $0.alias.lowercased().contains(text) || $0.resolved.lowercased().contains(text) }
    }

    /// What ssh makes of the server box: `user@host:port`, and whether through a bastion.
    /// Said for a typed `user@host:port` too, where it only confirms what was typed: no
    /// line would read as nothing having been checked (#610).
    private var resolvedLine: String? {
        guard let typed, typed.alias == destination.trimmingCharacters(in: .whitespaces) else { return nil }
        return Self.resolvedLine(typed)
    }

    /// Starts with `ssh`, which stays lower case, as the command is written.
    static func resolvedLine(_ host: DaemonAPI.SSHHost) -> String {
        var parts = ["ssh reaches it as \(host.resolved)"]
        if host.throughBastion { parts.append("through a bastion, so it can rarely reach this Mac") }
        if host.known { parts.append("already a machine") }
        return parts.joined(separator: ", ") + "."
    }

    /// Once typing pauses, ask what ssh makes of it; until the person sets the tunnel,
    /// it follows whether ssh goes through a bastion.
    private func resolveTyped() async {
        let text = destination.trimmingCharacters(in: .whitespaces)
        guard control.isOnThisMac, !text.isEmpty else { typed = nil; return }
        if let known = configHosts.first(where: { $0.alias == text }) {
            typed = known
        } else {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            typed = await control.sshHosts(text).first
        }
        if !tunnelChosen { tunnel = typed?.throughBastion ?? false }
    }

    private var isDone: Bool {
        switch outcome {
        case .added?, .updated?: true
        default: false
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.message = "Choose the private key to install with. It is read once, for this install."
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        keyURL = url
        keyPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Reads the key now, if one is named, sends it in the one call, and keeps no copy.
    private func install() {
        var key: String?
        if !keyPath.isEmpty {
            let url = keyURL ?? URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
            let scoped = url.startAccessingSecurityScopedResource()
            key = try? String(contentsOf: url, encoding: .utf8)  // store-ok: a file the person chose in the open panel
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard let key, !key.isEmpty else {
                outcome = .failed("That key could not be read. Choose it with Choose….")
                return
            }
        }
        working = true
        outcome = nil
        let trusting = fingerprint
        Task {
            if let updating {
                let result = await control.update(host: updating.id, destination: destination.trimmingCharacters(in: .whitespaces),
                                                  key: key, trust: trusting)
                working = false
                if case .needsTrust(let shownKey) = result {
                    fingerprint = shownKey
                } else {
                    fingerprint = nil
                    outcome = result
                }
                return
            }
            let result = await control.install(destination: destination.trimmingCharacters(in: .whitespaces),
                                               name: name.trimmingCharacters(in: .whitespaces), key: key, trust: trusting,
                                               tunnel: control.isOnThisMac ? tunnel : nil)
            working = false
            if case .needsTrust(let shownKey) = result {
                fingerprint = shownKey
            } else {
                fingerprint = nil
                outcome = result
                if case .added(let joined, _) = result, let prefill, let provider = prefill.provider,
                   let workspace = prefill.workspace {
                    await control.linkWhenJoined(name: joined, provider: provider, workspace: workspace)
                }
            }
        }
    }

    private func stepWords(_ step: String?) -> String {
        switch step {
        case "connect": "Connecting…"
        case "checkSystem": "Checking the system…"
        case "setUp": "Installing Agents…"
        case "started": "Starting it…"
        default: "Working…"
        }
    }
}

/// What a server is called if nobody says: its host name from `user@host:port`, and
/// "Its host name" while the server box is empty (#660), not a made-up one.
enum HostNameGuess {
    static func from(_ destination: String) -> String {
        var host = destination.trimmingCharacters(in: .whitespaces)
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host.isEmpty ? "Its host name" : host
    }
}
