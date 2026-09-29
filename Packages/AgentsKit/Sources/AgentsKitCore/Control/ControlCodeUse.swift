import Foundation

/// Using a version 2 code, over whatever dials (058): the apps' `URLSession` WebSocket or a
/// host's NIO one. Say who this is once with the code's key, keep what the control plane
/// answers, and dial as oneself from then on.
public enum ControlCodeUse {
    public typealias Dial = @Sendable (URL, String?) async throws -> any LineTransport

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// A socket to `url`, dialled with `dial`, with `credentials` proved on it.
    public static func join(_ url: URL, pin: String?, as credentials: ControlAuth.Credentials,
                            dial: Dial) async throws -> PrefixReader {
        guard let origin = ControlAuth.origin(url) else { throw Failure("\(url) is not an address to dial") }
        return try await ControlAuth.join(try await dial(url, pin), origin: origin, as: credentials).transport
    }

    /// Says who this is with `method`, once, holding `code`; returns the answer.
    public static func announce(_ code: ControlCode, method: String, params: JSONValue, kind: String,
                                dial: Dial) async throws -> DaemonAPI.Admitted {
        guard let text = code.url, let url = URL(string: text), let id = ControlAuth.codeID(secret: code.secret) else {
            throw Failure("that code has no address; it is from the first build")
        }
        let identity: ControlAuth.Identity = if case .host = code.purpose { .enrolling(id) } else { .pairing(id) }
        let reader = try await join(url, pin: code.pin, as: .init(identity: identity, key: ControlAuth.codeKey(secret: code.secret),
                                                                 kind: kind, controlKey: code.controlKey), dial: dial)
        defer { reader.close() }
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: method, params: params)))
        guard let line = try await reader.next(within: 15) else { throw Failure("the control plane did not answer") }
        switch try JSONRPCCodec.decode(line: line) {
        case .success(_, let result): return try result.decode(DaemonAPI.Admitted.self)
        case .failure(_, let error): throw error
        default: throw Failure("the control plane answered something else: \(line)")
        }
    }

    /// A window or a device pairs with a client code: what it keeps to dial again.
    public static func pairClient(_ code: ControlCode, privateKey: Data, id: UUID, name: String,
                                  kind: ClientRecord.Kind, dial: Dial) async throws -> ControlMembership {
        guard case .client = code.purpose else { throw Failure("that is not a code for a window or a device") }
        let announce = DaemonAPI.ClientAnnounce(id: id, publicKey: try ControlAgreement.publicKey(privateKey: privateKey),
                                                name: name, kind: kind)
        let admitted = try await self.announce(code, method: DaemonAPI.Method.clientsAnnounce,
                                               params: try JSONValue.encoding(announce), kind: kind.rawValue, dial: dial)
        return ControlMembership(client: admitted.client ?? id, controlKey: code.controlKey, addresses: [],
                                 name: code.name, url: code.url, pin: code.pin)
    }

    /// How a paired client dials, every time, as itself.
    public static func clientDial(_ membership: ControlMembership, privateKey: Data, kind: String,
                                  dial: @escaping Dial) throws -> @Sendable () async throws -> any LineTransport {
        guard let text = membership.url, let url = URL(string: text), let client = membership.client else {
            throw Failure("that membership has no address; it is from the first build")
        }
        let key = try ControlAuth.clientKey(privateKey: privateKey, peer: membership.controlKey, client: client)
        let credentials = ControlAuth.Credentials(identity: .client(client), key: key, kind: kind, controlKey: membership.controlKey)
        let pin = membership.pin
        return { try await join(url, pin: pin, as: credentials, dial: dial) }
    }
}
