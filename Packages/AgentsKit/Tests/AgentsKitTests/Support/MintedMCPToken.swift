import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// The MCP token a session was handed, from `session/new`'s servers list: the bearer on
/// the app's own http server (#185).
enum MintedMCPToken {
    static func from(sessionParams params: JSONValue?) -> String {
        let servers = params?["mcpServers"]?.arrayValue ?? []
        let agents = servers.first { $0["name"]?.stringValue == AppTool.serverName }
            ?? servers.first
        let headers = agents?["headers"]?.arrayValue ?? []
        let bearer = headers.first { $0["name"]?.stringValue == "Authorization" }?["value"]?.stringValue
        return AppToolsEndpoint.bearer(bearer) ?? ""
    }

    /// What the daemon will offer that session's runtime, read from the endpoint itself.
    static func grant(_ core: DaemonCore, sessionParams params: JSONValue?) async -> AppToolsEndpoint.Grant? {
        await core.appTools.granted(from(sessionParams: params))
    }
}
