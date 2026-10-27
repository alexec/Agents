import Foundation

/// The machine providers a phone or a browser can add (#1808, #1819): those that work
/// through their API with a token (#1119). A CLI preset needs its CLI signed in where the
/// control plane runs, and somebody who starts on a phone has no shell there. The web page
/// says the same in `Web/src/model/machineProviders.ts`; the window's `AddProviderSheet`
/// offers these and more.
public enum APIProviderKind: String, CaseIterable, Identifiable, Sendable {
    case digitalOcean, codespaces, coder, aws, compute

    public var id: Self { self }

    /// One field of a kind's form. A secret goes only to the control plane, never in the
    /// configuration.
    public struct Field: Identifiable, Sendable, Equatable {
        public let id: String
        public let label: String
        public var prompt: String?
        public var isSecret = false
        public var isOptional = false
        /// Its starting value.
        public var value: String?
        /// Many lines, as a service account's JSON key.
        public var isLong = false
    }

    public var title: String {
        switch self {
        case .digitalOcean: "DigitalOcean Droplets"
        case .codespaces: "GitHub Codespaces"
        case .coder: "Coder Workspaces"
        case .aws: "AWS EC2 Instances"
        case .compute: "Google Compute Engine VMs"
        }
    }

    public var preset: String {
        switch self {
        case .digitalOcean: "digitalocean-api"
        case .codespaces: "codespaces-api"
        case .coder: "coder-api"
        case .aws: "aws-ec2-api"
        case .compute: "gcp-compute-api"
        }
    }

    public var needs: String {
        switch self {
        case .digitalOcean:
            "Needs a DigitalOcean API token with custom scopes: droplet read and update, and droplet create and delete to make and delete droplets. Nothing to install."
        case .codespaces:
            "Needs a GitHub token: fine-grained, with Codespaces lifecycle admin (read and write), or classic, with the codespace scope. ssh still goes through gh where the control plane runs."
        case .coder:
            "Needs your deployment’s address and a session token (`coder tokens create`). ssh still goes through coder where the control plane runs."
        case .aws:
            "Needs an IAM user’s access key, with the smallest policy: ec2:DescribeInstances on all resources, and ec2:StartInstances and ec2:StopInstances only on instances that have the tag (the condition aws:ResourceTag/‹tag› not Null). Nothing to install."
        case .compute:
            "Needs a service account’s JSON key, with the smallest role: compute.instances.list, start and stop, and for New Machine… compute.instances.create, delete, setMetadata and setLabels, compute.disks.create, and compute.subnetworks.use and useExternalIp. ssh goes to each VM’s external address, so the network must let in port 22. Nothing to install."
        }
    }

    public var fields: [Field] {
        switch self {
        case .digitalOcean:
            [Field(id: "token", label: "API token", isSecret: true),
             Field(id: "tag", label: "Tag", value: "agents"),
             Field(id: "user", label: "ssh user", value: "root")]
        case .codespaces:
            [Field(id: "token", label: "GitHub token", isSecret: true),
             Field(id: "repo", label: "Repository", prompt: "owner/name, or empty for all", isOptional: true)]
        case .coder:
            [Field(id: "url", label: "Deployment", prompt: "Your deployment’s address"),
             Field(id: "token", label: "Session token", isSecret: true)]
        case .aws:
            [Field(id: "accessKey", label: "Access key ID", isSecret: true),
             Field(id: "secretKey", label: "Secret access key", isSecret: true),
             Field(id: "region", label: "Region", prompt: "us-east-1"),
             Field(id: "tag", label: "Tag", value: "agents"),
             Field(id: "user", label: "ssh user", value: "ec2-user")]
        case .compute:
            [Field(id: "serviceKey", label: "Service account key (JSON)", isSecret: true, isLong: true),
             Field(id: "folder", label: "Folder"),
             Field(id: "zone", label: "Zone", prompt: "europe-west2-a"),
             Field(id: "label", label: "Label", value: "agents"),
             Field(id: "user", label: "ssh user", value: "agents"),
             Field(id: "sshKey", label: "ssh public key", isOptional: true)]
        }
    }

    /// The kind a preset stands for, when it is one of these.
    public static func ofPreset(_ preset: String?) -> APIProviderKind? {
        allCases.first { $0.preset == preset }
    }

    /// Each secret field and the name it goes to the control plane under.
    private var secretNames: [(field: String, secret: String)] {
        switch self {
        case .digitalOcean: [("token", "DIGITALOCEAN_API_TOKEN")]
        case .codespaces: [("token", "GITHUB_TOKEN")]
        case .coder: [("token", "CODER_SESSION_TOKEN")]
        case .aws: [("accessKey", "AWS_ACCESS_KEY_ID"), ("secretKey", "AWS_SECRET_ACCESS_KEY")]
        case .compute: [("serviceKey", "GOOGLE_SERVICE_ACCOUNT_KEY")]
        }
    }

    /// What Add or Save sends: `providers/add`, or with `editing` `providers/update`. On an
    /// edit the configuration is left out, so the control plane keeps it, and an empty secret
    /// keeps the one it has. A sentence that says what is missing, or the request.
    public func request(name: String, values: [String: String],
                        editing: DaemonAPI.ProviderSummary? = nil) -> Result<DaemonAPI.ProviderAdd, Missing> {
        func v(_ id: String) -> String { (values[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.title
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var secrets: [String: String] = [:]
        for (field, secret) in secretNames {
            // A secret key is not trimmed: a key is what it is.
            let value = field == "secretKey" || field == "serviceKey" ? values[field] ?? "" : v(field)
            if !value.isEmpty {
                secrets[secret] = value
            } else if editing == nil {
                return .failure(Missing(sentence: "Give the \(fields.first { $0.id == field }?.label ?? field)."))
            }
        }
        if let editing { return .success(DaemonAPI.ProviderAdd(id: editing.id, name: title, kind: .commands, secrets: secrets)) }
        var commands: [String: JSONValue] = ["preset": .string(preset)]
        switch self {
        case .digitalOcean:
            commands["tag"] = .string(v("tag").isEmpty ? "agents" : v("tag"))
            commands["user"] = .string(v("user").isEmpty ? "root" : v("user"))
        case .codespaces:
            if !v("repo").isEmpty { commands["repo"] = .string(v("repo")) }
        case .coder:
            if v("url").isEmpty { return .failure(Missing(sentence: "Give the deployment’s address.")) }
            commands["url"] = .string(v("url"))
        case .aws:
            if v("region").isEmpty { return .failure(Missing(sentence: "Give the region.")) }
            commands["region"] = .string(v("region"))
            commands["tag"] = .string(v("tag").isEmpty ? "agents" : v("tag"))
            commands["user"] = .string(v("user").isEmpty ? "ec2-user" : v("user"))
        case .compute:
            if v("project").isEmpty || v("zone").isEmpty { return .failure(Missing(sentence: "Give the project and the zone.")) }
            commands["project"] = .string(v("project"))
            commands["zone"] = .string(v("zone"))
            commands["label"] = .string(v("label").isEmpty ? "agents" : v("label"))
            commands["user"] = .string(v("user").isEmpty ? "agents" : v("user"))
            if !v("sshKey").isEmpty { commands["sshKeys"] = .array([.string(v("sshKey"))]) }
        }
        return .success(DaemonAPI.ProviderAdd(name: title, kind: .commands, commands: .object(commands), secrets: secrets))
    }

    public struct Missing: Error, Equatable {
        public let sentence: String
    }
}

/// Settings ▸ Machine providers' words on a phone and on the web (#1808, #1819).
public enum MachineProviderWords {
    public static let heading = "Machine providers"
    public static let footer = "A provider starts and stops your machines: DigitalOcean Droplets, GitHub Codespaces, Coder workspaces, "
        + "Google Compute Engine VMs or AWS EC2 instances, through their API. It runs on the control plane, so it can start a machine that is down. "
        + "Docker, Cloud Workstations, your own commands and MCP servers are added in the Mac app."
    public static let oneCopy = "Machine providers need a control plane with one copy, such as the one on your Mac. This one has several."
    public static let add = "Add Provider…"
    public static let secretsFoot = "Tokens and keys go to the control plane and are never shown again. This device does not keep them."
    public static let editSecret = "Leave empty to keep the one it has."
    public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
    public static let removeNote = "Its machines stay as they are, unlinked: nothing here can start or stop them any more."
    public static let noHosts = "No machine to link: add one in the Mac app, or start one from a repository."
    public static let notAHostYet = "Not joined yet: add it as a machine in the Mac app, in Settings ▸ Machine Providers."

    /// What a workspace with no host says when no host is free to link to it (#1931): this
    /// device can't install Agents on it, so the person is told where to (the Mac's Add as Host…).
    public static func noHostLine(_ workspace: DaemonAPI.MachineInfo, hosts: [DaemonAPI.ControlMachine]) -> String? {
        workspace.host == nil && linkableHosts(workspace, hosts: hosts).isEmpty ? notAHostYet : nil
    }

    /// The chip on a card: "command provider · digitalocean-api · API".
    public static func kindChip(_ provider: DaemonAPI.ProviderSummary) -> String {
        if let preset = provider.preset {
            return "command provider · \(preset) · \(preset.hasSuffix("-api") ? "API" : "CLI")"
        }
        return provider.kind == "commands" ? "command provider" : provider.mapped ? "MCP server · mapped" : "MCP server"
    }

    /// The grey line under a provider's name.
    public static func providerLine(_ provider: DaemonAPI.ProviderSummary, time: (Date) -> String) -> String {
        var parts: [String] = []
        if let problem = provider.problem, !provider.current || provider.listedAt == nil { parts.append("Couldn’t list: \(problem)") }
        if let at = provider.listedAt { parts.append("\(provider.current ? "Listed" : "Showing what it listed at") \(time(at))") }
        if provider.workspaces.isEmpty, provider.listedAt != nil { parts.append("No machines") }
        switch provider.preset {
        case "codespaces-api": parts.append("needs gh for ssh")
        case "coder-api": parts.append("needs coder for ssh")
        default: break
        }
        return parts.joined(separator: " · ")
    }

    /// The grey line under a workspace.
    public static func workspaceLine(_ workspace: DaemonAPI.MachineInfo, hosts: [DaemonAPI.ControlMachine]) -> String {
        var parts = [workspace.state.prefix(1).uppercased() + workspace.state.dropFirst()]
        if let host = workspace.host {
            parts.append("linked to \(hosts.first { $0.id == host }?.name ?? "a machine")")
        } else {
            parts.append("not joined")
        }
        if let cost = workspace.cost { parts.append(cost) }
        return parts.joined(separator: " · ")
    }

    /// Whether a host named `hostName` may be this workspace (MachineInfo.mayBe, #976).
    public static func mayBe(_ workspace: DaemonAPI.MachineInfo, hostName: String) -> Bool {
        let host = hostName.lowercased()
        if let ssh = workspace.ssh, ssh.lowercased() == host { return true }
        let name = workspace.name.lowercased()
        if name.isEmpty { return false }
        return host == name || ".\(host).".contains(".\(name).")
    }

    /// The hosts Link to Host can offer for a workspace no host has: those that run agents
    /// and are linked to none, the ones that may be it by name first.
    public static func linkableHosts(_ workspace: DaemonAPI.MachineInfo, hosts: [DaemonAPI.ControlMachine]) -> [DaemonAPI.ControlMachine] {
        if workspace.host != nil { return [] }
        let free = hosts.filter { $0.relay == nil && $0.workspace == nil }
        return free.filter { mayBe(workspace, hostName: $0.name) } + free.filter { !mayBe(workspace, hostName: $0.name) }
    }

    /// The Stop when idle choices, in minutes; 0 is Off.
    public static let idleChoices: [(minutes: Int, label: String)] = [
        (0, "Off"), (15, "After 15 minutes"), (30, "After 30 minutes"), (60, "After 1 hour"), (120, "After 2 hours"),
    ]
}
