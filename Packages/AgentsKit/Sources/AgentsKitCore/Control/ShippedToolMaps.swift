import Foundation

/// Tool maps Agents ships for providers' own MCP servers (#691, FR-072).
public enum ShippedToolMaps {
    /// DigitalOcean's MCP server (`npx -y @digitalocean/mcp`, checked against 1.5.1's
    /// `tools/list`): every droplet, powered on and off, and deleted. Its `droplet-create`
    /// takes no user data, so a new droplet couldn't install Agents on its first boot: make
    /// droplets in DigitalOcean, or with the `doctl` preset's commands. Reached over ssh as root
    /// at its first IPv4 address, which DigitalOcean lists public first.
    public static let digitalOcean: JSONValue = [
        "list": [
            "tool": "droplet-list", "arguments": ["PerPage": 200],
            "items": "droplets", "id": "id", "name": "name", "state": "status",
            "ssh": "root@{networks.v4[0].ip_address}", "cost": "${size.price_hourly}/hour while running",
            "states": ["active": "running", "new": "starting", "off": "stopped", "archive": "stopped"],
        ],
        "start": ["tool": "power-on-droplet", "arguments": ["ID": "{id:number}"]],
        "stop": ["tool": "power-off-droplet", "arguments": ["ID": "{id:number}"]],
        "delete": ["tool": "droplet-delete", "arguments": ["ID": "{id:number}"]],
    ]

    /// The secret DigitalOcean's server reads its token from.
    public static let digitalOceanSecret = "DIGITALOCEAN_API_TOKEN"
}
