import Foundation
import MCPServerKit

/// The command provider's presets (FR-071): the commands for one CLI, so most providers need
/// nothing but a name and a parameter or two. Each needs its CLI installed, and signed in,
/// where the control plane runs. None asks for sudo.
public enum Presets {
    public static let names = ["docker", "doctl", "codespaces", "coder", "gcloud-workstations"]

    /// `json`'s preset, with its parameters filled in.
    static func expand(_ name: String, _ json: JSON) throws(ConfigError) -> CommandConfig {
        switch name {
        case "docker": return try docker(json)
        case "doctl": return try doctl(json)
        case "codespaces": return codespaces(json)
        case "coder": return coder()
        case "gcloud-workstations": return try workstations(json)
        default: throw ConfigError("no preset \(name); there are \(names.joined(separator: ", "))")
        }
    }

    /// Containers on the machine that runs the control plane, such as the Linux devbox: the
    /// ones named in `containers`, or else every container labelled `agents.workspace`, each
    /// reached by its `agents.ssh` label or the shared `ssh` line. With an `image`, it makes
    /// labelled containers from it, which install Agents and join by themselves (#1025), and
    /// deletes them with their anonymous volumes.
    private static func docker(_ json: JSON) throws(ConfigError) -> CommandConfig {
        let containers = json["containers"]?.array?.compactMap(\.string).filter { !$0.isEmpty } ?? []
        let ssh = json["ssh"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let tunnel = json["tunnel"]?.bool ?? false
        let states: [String: WorkspaceState] = [
            "running": .running, "restarting": .starting, "created": .stopped, "exited": .stopped,
            "paused": .stopped, "dead": .stopped, "removing": .stopping]
        guard containers.isEmpty else {
            let commands = CommandConfig.Commands(
                start: "docker start ${id}", stop: "docker stop ${id}",
                status: "docker inspect -f '{{.State.Status}}' ${id}",
                ssh: ssh, tunnel: tunnel, cost: nil)
            return CommandConfig(workspaces: containers.map { .init(id: $0, name: $0, commands: commands) }, states: states)
        }
        return CommandConfig(
            listing: .init(
                command: "docker ps -a --filter label=agents.workspace --format '{{.Names}}\\t{{.State}}\\t{{.Label \"agents.ssh\"}}'",
                shape: .columns(["id", "state", "ssh"]),
                commands: .init(start: "docker start ${id}", stop: "docker stop ${id}",
                                status: nil, ssh: "${ssh}", tunnel: tunnel, cost: nil),
                defaults: ssh.map { ["ssh": $0] } ?? [:]),
            states: states,
            making: dockerMaking(image: json["image"]?.string.flatMap { $0.isEmpty ? nil : $0 }))
    }

    private static func dockerMaking(image: String?) -> CommandConfig.Making {
        guard let image else { return CommandConfig.Making() }
        return CommandConfig.Making(
            create: "docker run -d --name ${name} --label agents.workspace ${image} && docker exec ${name} sh -c ${firstBoot}",
            delete: "docker rm -f -v ${id}",
            options: ["type": "object",
                      "properties": ["image": ["type": "string", "title": "Image", "description": .string(image),
                                               "default": .string(image)]]])
    }

    /// DigitalOcean droplets with a tag.
    private static func doctl(_ json: JSON) throws(ConfigError) -> CommandConfig {
        guard let tag = json["tag"]?.string, !tag.isEmpty else { throw ConfigError("the doctl preset needs a tag") }
        let user = json["user"]?.string ?? "root"
        return CommandConfig(
            listing: .init(
                command: "doctl compute droplet list --tag-name \(Template.shellQuoted(tag)) --format ID,Name,Status,PublicIPv4 --no-header",
                shape: .columns(["id", "name", "state", "ip"]),
                commands: .init(start: "doctl compute droplet-action power-on ${id} --wait",
                                stop: "doctl compute droplet-action power-off ${id} --wait",
                                status: nil, ssh: "\(user)@${ip}", tunnel: json["tunnel"]?.bool ?? false, cost: nil)),
            states: ["active": .running, "new": .starting, "off": .stopped, "archive": .stopped])
    }

    /// GitHub Codespaces. A codespace starts when something connects to it, so start is an
    /// ssh that does nothing. It can't reach the control plane, so it needs a tunnel.
    private static func codespaces(_ json: JSON) -> CommandConfig {
        let repo = json["repo"]?.string.map { " --repo \(Template.shellQuoted($0))" } ?? ""
        return CommandConfig(
            listing: .init(
                command: "gh codespace list\(repo) --json name,displayName,state",
                shape: .json(items: "", fields: ["id": "name", "name": "displayName", "state": "state"]),
                commands: .init(start: "gh codespace ssh -c ${id} -- true", stop: "gh codespace stop -c ${id}",
                                status: nil, ssh: json["ssh"]?.string, tunnel: true, cost: nil)),
            states: ["available": .running, "starting": .starting, "provisioning": .starting,
                     "shuttingdown": .stopping, "shutdown": .stopped])
    }

    /// Coder workspaces, reached through the `coder.<name>` hosts `coder config-ssh` writes.
    private static func coder() -> CommandConfig {
        CommandConfig(
            listing: .init(
                command: "coder list -o json",
                shape: .json(items: "", fields: ["id": "name", "name": "name", "state": "latest_build.status"]),
                commands: .init(start: "coder start -y ${id}", stop: "coder stop -y ${id}",
                                status: nil, ssh: "coder.${name}", tunnel: false, cost: nil)),
            states: ["pending": .starting, "canceling": .stopping, "canceled": .stopped, "failed": .unknown,
                     "deleting": .stopping, "deleted": .stopped])
    }

    /// Google Cloud Workstations in one cluster and configuration.
    private static func workstations(_ json: JSON) throws(ConfigError) -> CommandConfig {
        var flags = ""
        for key in ["cluster", "config", "region"] {
            guard let value = json[key]?.string, !value.isEmpty else {
                throw ConfigError("the gcloud-workstations preset needs \(key)")
            }
            flags += " --\(key)=\(Template.shellQuoted(value))"
        }
        return CommandConfig(
            listing: .init(
                command: "gcloud workstations list\(flags) --format='value(name.basename(),state)'",
                shape: .columns(["id", "state"]),
                commands: .init(start: "gcloud workstations start ${id}\(flags)",
                                stop: "gcloud workstations stop ${id}\(flags)",
                                status: nil, ssh: json["ssh"]?.string, tunnel: true, cost: nil)),
            states: ["state_running": .running, "state_starting": .starting, "state_stopping": .stopping,
                     "state_stopped": .stopped, "state_reconciling": .starting])
    }
}
