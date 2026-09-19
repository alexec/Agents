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

    public var isMethodNotFound: Bool { code == Self.methodNotFound }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: methodNotFound, message: "Method not found", data: ["method": .string(method)])
    }

    public static func internalError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: internalError, message: message)
    }
}

/// Things that go wrong with the connection itself rather than with a call.
public enum JSONRPCTransportError: Error, Sendable {
    case closed
    case writeFailed(errno: Int32)
    case notStarted
}
