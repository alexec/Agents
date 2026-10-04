import Foundation

/// A JSON-RPC error, kept whole.
///
/// The code matters in at least one place that decides behaviour: a runtime that does
/// not implement `session/resume` answers `-32601`, and that is the advertised way of
/// saying so rather than a fault.
public struct JSONRPCError: Error, Codable, Hashable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603

    /// The protocol's own reserved codes. `-32000` is the one that matters: it is a
    /// runtime saying it is installed and will not work until somebody signs in, which
    /// is a state the app can show and offer to fix rather than a failure to report.
    public static let authRequired = -32000
    public static let resourceNotFound = -32002
    public static let requestCancelled = -32800

    public var isMethodNotFound: Bool { code == Self.methodNotFound }

    /// Not a fault. The agent is there and needs signing in.
    public var isAuthRequired: Bool { code == Self.authRequired }

    /// Expected after a cancel, so not worth showing anybody.
    public var isCancelled: Bool { code == Self.requestCancelled }

    /// What a spent-allowance check reads (052). Grok puts the real refusal under
    /// `data.message` with `data.http_status`, while the top-level message is only
    /// "Internal error"; prefer those when present.
    public var refusalForLimit: (code: Int, message: String) {
        (code: data?["http_status"]?.intValue ?? code,
         message: data?["message"]?.stringValue ?? message)
    }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: methodNotFound, message: "Method not found", data: ["method": .string(method)])
    }

    public static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: internalError, message: message)
    }

    public static func authRequired(_ message: String = "Authentication required") -> JSONRPCError {
        JSONRPCError(code: authRequired, message: message)
    }
}

/// Things that go wrong with the connection itself rather than with a call.
public enum JSONRPCTransportError: Error, Sendable {
    case closed
    case writeFailed(errno: Int32)
    case notStarted
}

/// A call that had no answer by its deadline (#166). Not a `JSONRPCError`: the other side
/// said nothing, so there is no code or message of theirs to carry.
public struct JSONRPCTimeout: Error, Sendable, Hashable {
    public var method: String
    public var after: Duration

    public init(method: String, after: Duration) {
        self.method = method
        self.after = after
    }
}
