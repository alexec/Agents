#if canImport(Network) && canImport(Security)
import Foundation

/// Where a relay gets this Mac's own sign-in for a runtime (047 Codex's file, 056 Claude's
/// Keychain item). The sign-in never leaves the Mac: the relay puts `current()` on each
/// request, and the server's runtime starts with `standIn()`, which holds no secret.
public protocol MacSignInSource: Sendable {
    /// Signed in the way this relay lends (a ChatGPT sign-in for Codex; a Claude account's,
    /// with inference, for Claude).
    var isSignedIn: Bool { get }
    func current() throws -> MacSignInToken
    /// A token other than `stale`, which was refused; or `renewalRefused`. Never `stale`.
    func renew(after stale: MacSignInToken) async throws -> MacSignInToken
    func standIn() throws -> String
}

/// What the relay puts on a request: the access token, as `Authorization: Bearer`, and any
/// other headers the service wants from the sign-in (Codex's account id).
public struct MacSignInToken: Sendable, Equatable, CustomStringConvertible {
    public var access: String
    public var headers: [String: String]

    public init(access: String, headers: [String: String] = [:]) {
        self.access = access
        self.headers = headers
    }

    /// Never the token itself, so a log line or an error cannot carry it.
    public var description: String { "MacSignInToken(\(headers.keys.sorted().joined(separator: ",")))" }
}

public enum MacSignInFailure: Error, Equatable {
    case notSignedIn
    /// The sign-in is there but could not be read (056: the Keychain said no).
    case unreadable
    case renewalRefused(Int)
}
#endif
