import AgentsKitCore
import AppKit
import SwiftUI

/// Add a Server (058, US4, T074; frames M and M2).
///
/// - **Run a command**, the usual way: the server installs itself and connects out, so
///   nothing has to reach it. The command carries a one-time host code, and the sheet
///   closes by itself when the server joins.
/// - **Install over ssh**, for a server the person can already ssh to: the control plane
///   installs the host once with the key given here, and keeps neither the key nor the
///   session.
struct ControlAddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: ControlSettingsModel

    enum Way: Hashable { case command, ssh }
    @State private var way: Way = .command

    // Run a command
    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var before: Set<HostID> = []
    @State private var joined: String?

    // Install over ssh
    @State private var destination = ""
    @State private var name = ""
    @State private var keyPath = ""
    @State private var keyURL: URL?
    @State private var working = false
    @State private var fingerprint: String?
    @State private var outcome: ControlSettingsModel.InstallOutcome?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a Server").appText(.title).fontWeight(.semibold)
            Picker("How", selection: $way) {
                Text("Run a command").tag(Way.command)
                Text("Install over ssh").tag(Way.ssh)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch way {
            case .command: commandPage
            case .ssh: sshPage
            }
        }
        .padding(28)
        .frame(width: 620)
        .task { await watchForJoin() }
    }

    // MARK: M · Run a command

    @ViewBuilder
    private var commandPage: some View {
        Text("On the server, as the user your agents should run as:")
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
                .accessibilityLabel("Command")
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
                Text("Waiting for the server to connect…").appText(.reading)
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

    /// Makes the code once, then watches for a host that was not there before, and closes
    /// when one joins.
    private func watchForJoin() async {
        await control.refresh()
        before = Set(control.hosts.map(\.id))
        shown = await control.startCode(forHost: true)
        while !Task.isCancelled, joined == nil {
            try? await Task.sleep(for: .seconds(2))
            await control.refresh()
            guard way == .command || outcome != nil else { continue }
            if let new = control.hosts.first(where: { !before.contains($0.id) && $0.state == "online" }) {
                joined = new.name
                try? await Task.sleep(for: .seconds(1.5))
                if way == .command { dismiss() }
            }
        }
    }

    static func left(until expires: Date, now: Date) -> String {
        let seconds = max(0, Int(expires.timeIntervalSince(now)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: M2 · Install over ssh

    @ViewBuilder
    private var sshPage: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Server").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                TextField("agents@devbox.lan", text: $destination).textFieldStyle(.roundedBorder).appText(.code)
                    .accessibilityLabel("Server").disabled(working || fingerprint != nil)
            }
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField(HostNameGuess.from(destination), text: $name).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name").disabled(working)
            }
            GridRow {
                Text("Key").foregroundStyle(.secondary)
                HStack {
                    TextField("~/.ssh/id_ed25519", text: $keyPath).textFieldStyle(.roundedBorder).appText(.code)
                        .accessibilityLabel("Key").disabled(working)
                    Button("Choose…") { chooseKey() }.buttonStyle(.paper).disabled(working)
                }
            }
        }
        Text("The key is used for this install only. The control plane doesn’t keep it, and afterwards the server connects to the control plane by itself.")
            .appText(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let fingerprint {
            VStack(alignment: .leading, spacing: 6) {
                Text("This server is new to the control plane. Its key is:").appText(.supporting)
                Text(fingerprint).appText(.code).textSelection(.enabled)
                Text("Install only if this is the key the server shows (ssh-keygen -lf on its host key).")
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
        case .added(let named)?:
            Text(joined.map { "\($0) joined." } ?? "Installed on \(named). Waiting for it to connect…")
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
                Button(fingerprint == nil ? "Install" : "Trust and Install") { install() }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || destination.trimmingCharacters(in: .whitespaces).isEmpty || keyPath.isEmpty)
            }
        }
    }

    private var isDone: Bool { if case .added = outcome { true } else { false } }

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

    /// Reads the key now, sends it in the one call, and keeps no copy.
    private func install() {
        let url = keyURL ?? URL(fileURLWithPath: (keyPath as NSString).expandingTildeInPath)
        let scoped = url.startAccessingSecurityScopedResource()
        let key = try? String(contentsOf: url, encoding: .utf8)  // store-ok: a file the person chose in the open panel
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let key, !key.isEmpty else {
            outcome = .failed("That key could not be read. Choose it with Choose….")
            return
        }
        working = true
        outcome = nil
        let trusting = fingerprint
        Task {
            let result = await control.install(destination: destination.trimmingCharacters(in: .whitespaces),
                                               name: name.trimmingCharacters(in: .whitespaces), key: key, trust: trusting)
            working = false
            if case .needsTrust(let shownKey) = result {
                fingerprint = shownKey
            } else {
                fingerprint = nil
                outcome = result
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

/// What a server is called if nobody says: its host name from `user@host:port`.
enum HostNameGuess {
    static func from(_ destination: String) -> String {
        var host = destination.trimmingCharacters(in: .whitespaces)
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        return host.isEmpty ? "devbox" : host
    }
}
