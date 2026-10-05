import Foundation

/// Using a version 2 code, over whatever dials (058): the apps' `URLSession` WebSocket or a
/// host's NIO one. Say who this is once with the code's key, keep what the control plane
/// answers, and dial as oneself from then on.
public enum ControlCodeUse {
    public typealias Dial = @Sendable (URL, String?) async throws -> any LineTransport

    public struct Failure: Error, Sendable, CustomStringConvertible, Equatable {
        public var description: String
        public init(_ description: String) { self.description = description }

        /// Joined, announced, and then nothing.
        public static let noAnswer = Failure("the control plane did not answer")
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
        guard let line = try await reader.next(within: 15) else { throw Failure.noAnswer }
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

    /// How a moved device dials (T085): with the key it already shares with the control
    /// plane, derived where its private key lives (a Secure Enclave key cannot leave).
    /// `keep` is handed the membership whenever the control plane gives a newer list of
    /// endpoints (R16), to save it.
    public static func clientDial(_ membership: ControlMembership, sharedKey: Data, kind: String,
                                  dial: @escaping Dial, keep: EndpointBook.Keep? = nil)
        throws -> @Sendable () async throws -> any LineTransport {
        guard !membership.endpointsToDial.isEmpty, let client = membership.client else {
            throw Failure("that membership has no address; it is from the first build")
        }
        let credentials = ControlAuth.Credentials(identity: .client(client), key: sharedKey, kind: kind,
                                                  controlKey: membership.controlKey)
        let book = EndpointBook(membership, keep: keep)
        return { try await dialEach(book, as: credentials, dial: dial) }
    }

    /// How a paired client dials, every time, as itself.
    public static func clientDial(_ membership: ControlMembership, privateKey: Data, kind: String,
                                  dial: @escaping Dial, keep: EndpointBook.Keep? = nil)
        throws -> @Sendable () async throws -> any LineTransport {
        guard let client = membership.client else {
            throw Failure("that membership has no address; it is from the first build")
        }
        let key = try ControlAuth.clientKey(privateKey: privateKey, peer: membership.controlKey, client: client)
        return try clientDial(membership, sharedKey: key, kind: kind, dial: dial, keep: keep)
    }

    /// Dials the book's endpoints in turn, each with its own pin, and proves `credentials`
    /// on the first that answers; a newer list in its `ok` goes into the book (R16).
    ///
    /// A refusal is the control plane's answer and ends it, except "not this control
    /// plane", which only means something else now answers at that place.
    public static func dialEach(_ book: EndpointBook, as credentials: ControlAuth.Credentials,
                                dial: Dial) async throws -> PrefixReader {
        var last: any Error = Failure("there is no address to dial")
        for endpoint in book.order {
            guard let url = URL(string: endpoint.url), let origin = ControlAuth.origin(url) else { continue }
            var proving = credentials
            // Always said, 0 for none: a build that keeps a list says so, and takes the
            // list it is given (R16), so the control plane may count it as told.
            proving.epoch = book.epoch ?? 0
            do {
                let (reader, _, ok) = try await ControlAuth.join(try await dial(url, endpoint.pin), origin: origin, as: proving)
                book.answered(at: endpoint, ok: ok)
                return reader
            } catch let refusal as ControlAuth.Refusal where refusal.reason != .wrongControlPlane {
                throw refusal
            } catch {
                last = error
            }
        }
        throw last
    }
}

/// The endpoints a member dials, and the one that last answered, which it tries first
/// (058, research R16). The control plane may give a newer list in any `ok`: the book
/// takes it in place of its own, and hands the membership to `keep` to save. A save that
/// throws (a full disk, #212) is tried again at the next `ok`, so a move is not forgotten
/// by the next launch because the disk refused it once.
public final class EndpointBook: @unchecked Sendable {
    public typealias Keep = @Sendable (ControlMembership) throws -> Void

    private let lock = NSLock()
    private var membership: ControlMembership
    private var lastAnswered: ControlEndpoint?
    private let keep: Keep?
    private var unsaved = false

    public init(_ membership: ControlMembership, keep: Keep? = nil) {
        self.membership = membership
        self.keep = keep
    }

    public var current: ControlMembership { lock.withLock { membership } }
    public var epoch: Int? { lock.withLock { membership.epoch } }

    /// The endpoints in the order to try: the one that answered last, then the rest as
    /// the control plane listed them.
    public var order: [ControlEndpoint] {
        lock.withLock {
            let all = membership.endpointsToDial
            guard let first = lastAnswered, all.contains(first) else { return all }
            return [first] + all.filter { $0 != first }
        }
    }

    /// Whether a newer list is held that `keep` could not save yet.
    public var holdsUnsaved: Bool { lock.withLock { unsaved } }

    /// An endpoint answered with `ok`: remember it, and take a newer list if it gave one.
    /// A list `keep` could not save is taken all the same, and handed to it again next time;
    /// `keep` says why it could not.
    public func answered(at endpoint: ControlEndpoint, ok: ControlAuth.OK) {
        let changed = lock.withLock { () -> ControlMembership? in
            lastAnswered = endpoint
            if let newer = membership.adopting(ok.endpoints, epoch: ok.epoch) {
                membership = newer
                unsaved = true
            }
            return unsaved ? membership : nil
        }
        guard let changed, let keep, (try? keep(changed)) != nil else { return }
        lock.withLock { if membership == changed { unsaved = false } }
    }
}
