import Foundation

/// A request or response id, which JSON-RPC allows to be a number or a string.
public enum JSONRPCID: Codable, Hashable, Sendable {
    case number(Int)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .number(v); return }
        self = .string(try c.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}

/// One line on the wire.
///
/// Which of the four it is has to be worked out from which keys are present, because
/// that is how JSON-RPC is specified: a response has `result` or `error`, a request has
/// `method` and `id`, a notification has `method` and no `id`.
public enum JSONRPCMessage: Sendable {
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case success(id: JSONRPCID, result: JSONValue)
    case failure(id: JSONRPCID?, error: JSONRPCError)

    public var id: JSONRPCID? {
        switch self {
        case .request(let id, _, _): return id
        case .success(let id, _): return id
        case .failure(let id, _): return id
        case .notification: return nil
        }
    }
}

public enum JSONRPCCodec {
    private struct Envelope: Codable {
        var jsonrpc: String?
        var id: JSONRPCID?
        var method: String?
        var params: JSONValue?
        var result: JSONValue?
        var error: JSONRPCError?
    }

    /// Decode one line. Throws rather than returning nil so a caller can log the line
    /// that was wrong; a malformed line must never end the connection.
    public static func decode(line: String) throws -> JSONRPCMessage {
        // Read as one open-ended value and taken apart by key, rather than decoded
        // into the envelope: the envelope's `params` and `result` are `JSONValue`,
        // and a `JSONValue` read by `JSONDecoder` is read by guesswork. See
        // `JSONValue.parse`.
        let whole: JSONValue
        do {
            whole = try JSONValue.parse(Data(line.utf8))
        } catch {
            throw JSONRPCError(code: JSONRPCError.parseError, message: "line is not JSON")
        }
        guard let object = whole.objectValue else {
            throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "not a JSON object")
        }
        let id: JSONRPCID? = switch object["id"] {
        case .int(let n): .number(n)
        case .double(let d): Int(exactly: d).map(JSONRPCID.number)
        case .string(let s): .string(s)
        default: nil
        }
        if let error = object["error"] {
            return .failure(id: id, error: JSONRPCError(code: error["code"]?.intValue ?? JSONRPCError.internalError,
                                                        message: error["message"]?.stringValue ?? "",
                                                        data: error["data"]))
        }
        if let method = object["method"]?.stringValue {
            let params = object["params"].flatMap { $0.isNull ? nil : $0 }
            if let id { return .request(id: id, method: method, params: params) }
            return .notification(method: method, params: params)
        }
        if let id { return .success(id: id, result: object["result"] ?? .null) }
        throw JSONRPCError(code: JSONRPCError.invalidRequest, message: "neither request, response nor notification")
    }

    public static func encode(_ message: JSONRPCMessage) throws -> String {
        var e = Envelope(jsonrpc: "2.0")
        switch message {
        case .request(let id, let method, let params):
            e.id = id; e.method = method; e.params = params
        case .notification(let method, let params):
            e.method = method; e.params = params
        case .success(let id, let result):
            e.id = id; e.result = result
        case .failure(let id, let error):
            e.id = id; e.error = error
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(e)
        return String(decoding: data, as: UTF8.self)
    }
}
