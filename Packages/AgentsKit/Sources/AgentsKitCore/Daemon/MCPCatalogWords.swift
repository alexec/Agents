import Foundation

/// What an MCP catalogue refusal says, in words (moved to Core so the sandboxed window can say it, 058 S5).
public enum MCPCatalogWords {
    public static func sentence(_ error: DaemonAPI.MCPCatalogError) -> String {
        switch error {
        case .unreachable(let host): "Can't reach \(host)."
        case .noPersonalHome: "This copy of the app has no personal ~/.agents."
        case .unmanaged(let path): "A server you wrote is already at \(path), so it was left alone."
        case .mcpUnreadable(let path): "\(path) could not be read, so it was not written."
        case .missingSecret(let name): "\(name) is required."
        case .staleDigest: "That server has changed. Open it again."
        case .secretStillInUse(let name): "\(name) is still named by another server."
        case .previewExpired: "That has expired. Open the server, or verify it, again."
        case .noRunnableWay: "There is no way to run this server on this Mac."
        case .replaceMismatch: "The server there has changed. Open it again."
        case .notAProject(let path): "\(path) is not a project on this Mac."
        case .nameTaken(let name): "There is already a server called \(name) there."
        case .invalid(let why): why
        case .failed(let why): "It could not be added: \(why)."
        }
    }
}
