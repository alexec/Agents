import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// The MCP token a session was handed, from `session/new`'s servers list (S7: in env).
enum MintedMCPToken {
    static func from(sessionParams params: JSONValue?) -> String {
        let servers = params?["mcpServers"]?.arrayValue ?? []
        let agents = servers.first { $0["name"]?.stringValue == AppTool.serverName }
            ?? servers.first
        let env = agents?["env"]?.arrayValue ?? []
        return env.first { $0["name"]?.stringValue == DaemonCore.mcpTokenVariable }?["value"]?.stringValue ?? ""
    }
}
