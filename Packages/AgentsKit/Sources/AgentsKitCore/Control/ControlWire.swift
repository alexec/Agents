import Foundation

/// The two framings the control plane speaks (058, contracts/wire.md).
///
/// Between a client and the control plane each line is `{"h":<host>,"m":<message>}`, or
/// `{"m":<message>}` for the control plane itself. Between the control plane and a host
/// each line is `{"c":<channel>,…}`: a message, an `open` or a `close`. The message in
/// `m` is a JSON-RPC line exactly as a `daemon.sock` client sends it today, and it is
/// carried as the bytes it arrived as. The control plane reads a request's method to
/// tell its own from a host's and nothing else, so a method added to the daemon later
/// passes through without the control plane knowing of it.
///
/// Lines this side writes always put `m` last, so reading one back is a matter of
/// finding where `m` starts. A line from anywhere else that is laid out differently is
/// parsed whole instead, which costs a re-encoding of `m` and nothing worse.
public enum ControlWire {
    /// A line from a client, taken apart.
    public enum ClientFrame: Equatable, Sendable {
        /// For the host named.
        case toHost(HostID, message: String)
        /// For the control plane itself.
        case toControl(message: String)
        /// A bare JSON-RPC line, from a client that has never heard of the control plane:
        /// today's Remote. It is the home host's, unless it is a method the control plane
        /// answers (R7).
        case legacy(message: String)
    }

    /// A line on a host's uplink, taken apart.
    public enum HostFrame: Equatable, Sendable {
        case message(channel: Int, message: String)
        case open(channel: Int, ChannelOpen)
        case close(channel: Int)
    }

    /// What a channel is opened as: a connection that may do everything a window's may,
    /// bound to `device` when it carries a phone, an iPad or a browser, so presence and a
    /// device's own name are its. Nothing else on the uplink can set who a connection is.
    public struct ChannelOpen: Codable, Equatable, Sendable {
        /// Always `operator`, which an older host needs to open the channel at all and
        /// which gives a client everything there, as it now has (#111). Not read.
        public var grant: String = LegacyGrant.everything
        public var client: String
        public var device: UUID?
        /// The device reached the control plane through `agents-relay` (T096).
        public var relayed: Bool?
        /// A tunnel between two hosts for a relayed sign-in (T091), not a client: the
        /// runtime whose sign-in it carries. Its messages are bytes, base64 in a JSON string.
        public var tunnel: String?
        /// On the borrowing host's end: the reference it asked with, so it knows which of
        /// its waiting connections this is.
        public var tunnelRef: String?

        public init(client: String, device: UUID? = nil, relayed: Bool? = nil,
                    tunnel: String? = nil, tunnelRef: String? = nil) {
            self.relayed = relayed
            self.tunnel = tunnel
            self.tunnelRef = tunnelRef
            self.client = client
            self.device = device
        }
    }

    public enum WireError: Error, Equatable {
        case notAnObject
        case noMessage
        case badHost
        case badChannel
    }

    // MARK: Client ⇄ control

    public static func wrap(host: HostID?, message: String) -> String {
        guard let host else { return #"{"m":"# + message + "}" }
        return #"{"h":"# + quoted(host.rawValue) + #","m":"# + message + "}"
    }

    public static func readClient(_ line: String) throws -> ClientFrame {
        if line.hasPrefix(#"{"m":"#), line.hasSuffix("}") {
            return .toControl(message: String(line.dropFirst(5).dropLast()))
        }
        if line.hasPrefix(#"{"h":""#), let (host, rest) = plainString(after: line.dropFirst(6)),
           rest.hasPrefix(#","m":"#), line.hasSuffix("}"), isHostID(host) {
            return .toHost(HostID(rawValue: host), message: String(rest.dropFirst(5).dropLast()))
        }
        guard let object = try? JSONValue.parse(Data(line.utf8)).objectValue else { throw WireError.notAnObject }
        if object["jsonrpc"] != nil { return .legacy(message: line) }
        guard let m = object["m"] else { throw WireError.noMessage }
        let message = try encode(m)
        switch object["h"] {
        case nil, .null?: return .toControl(message: message)
        case .string(let host)? where isHostID(host): return .toHost(HostID(rawValue: host), message: message)
        default: throw WireError.badHost
        }
    }

    // MARK: Control ⇄ host

    public static func channel(_ channel: Int, message: String) -> String {
        #"{"c":"# + String(channel) + #","m":"# + message + "}"
    }

    public static func open(_ channel: Int, _ open: ChannelOpen) -> String {
        let body = (try? encode(JSONValue.encoding(open))) ?? "{}"
        return #"{"c":"# + String(channel) + #","open":"# + body + "}"
    }

    public static func close(_ channel: Int) -> String {
        #"{"c":"# + String(channel) + #","close":true}"#
    }

    public static func readHost(_ line: String) throws -> HostFrame {
        if line.hasPrefix(#"{"c":"#), line.hasSuffix("}") {
            let afterC = line.dropFirst(5)
            let digits = afterC.prefix { $0.isASCII && $0.isNumber }
            if let channel = Int(digits), !digits.isEmpty {
                let rest = afterC.dropFirst(digits.count)
                if rest.hasPrefix(#","m":"#) {
                    return .message(channel: channel, message: String(rest.dropFirst(5).dropLast()))
                }
            }
        }
        guard let object = try? JSONValue.parse(Data(line.utf8)).objectValue else { throw WireError.notAnObject }
        guard let channel = object["c"]?.intValue, channel >= 0 else { throw WireError.badChannel }
        if let m = object["m"] { return .message(channel: channel, message: try encode(m)) }
        if let open = object["open"] { return .open(channel: channel, try open.decode(ChannelOpen.self)) }
        if object["close"]?.boolValue == true { return .close(channel: channel) }
        throw WireError.noMessage
    }

    // MARK: Reading a message

    /// The method and id of a request, or nil for anything that is not one. The only
    /// thing the control plane reads inside `m`.
    public static func request(in message: String) -> (id: JSONRPCID, method: String)? {
        guard case .request(let id, let method, _)? = try? JSONRPCCodec.decode(line: message) else { return nil }
        return (id, method)
    }

    /// Whether a message is a request at all, including one too broken to read: those
    /// are refused rather than passed on, since nobody could say what they ask.
    public static func isNotification(_ message: String) -> Bool {
        if case .notification? = try? JSONRPCCodec.decode(line: message) { return true }
        return false
    }

    /// A host id as `HostID.make` makes them, or `mac`: nothing that needs escaping.
    public static func isHostID(_ string: String) -> Bool {
        !string.isEmpty && string.count <= 64
            && string.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // MARK: Helpers

    private static func quoted(_ s: String) -> String {
        // Host ids are checked to need no escaping; anything else goes through the encoder.
        if isHostID(s) { return "\"" + s + "\"" }
        return (try? encode(.string(s))) ?? "\"\""
    }

    /// A string with no escapes in it, up to its closing quote, and what follows.
    private static func plainString(after s: Substring) -> (String, Substring)? {
        guard let end = s.firstIndex(of: "\"") else { return nil }
        let value = s[s.startIndex..<end]
        guard !value.contains("\\") else { return nil }
        return (String(value), s[s.index(after: end)...])
    }

    private static func encode(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
