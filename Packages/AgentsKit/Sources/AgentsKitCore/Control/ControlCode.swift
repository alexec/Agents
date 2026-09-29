import Foundation

/// A pairing or enrolment code, as the control plane shows it and another machine takes
/// it (058, data-model.md `PairingCode`, T019/T029).
///
/// What it holds is what the new party needs and nothing more: the control plane's
/// public key, a one-time secret, what the code lets its holder become, and where to
/// reach the control plane. Its text is one line, to paste or to put in a QR code:
///
///     agents-control:2:<c|h>:<grant or ->:<key>:<secret>:<url>:<pin or ->:<name>
///
/// with the key and the secret in base64url, and the URL and name percent-encoded. The
/// URL is the control plane's one address (R8); the pin is the SHA-256 of its
/// certificate's public key, base64url, when that certificate is not publicly trusted
/// (R6). Version 1, from the first build, carried a list of `host:port` instead and is
/// still read.
public struct ControlCode: Sendable, Hashable {
    public enum Purpose: Sendable, Hashable {
        /// A window or a device, and what it may do.
        case client(Grant)
        /// A machine that runs agents.
        case host
    }

    public var purpose: Purpose
    /// The control plane's key, X9.63, 65 bytes.
    public var controlKey: Data
    /// Thirty-two random bytes, good once, for five minutes.
    public var secret: Data
    /// Where the control plane listens, tried in order.
    public var addresses: [String]
    /// What the control plane calls itself.
    public var name: String
    /// The control plane's address, for a version 2 code (`wss://` is dialled at it).
    public var url: String?
    /// The pin of its certificate, when it is not publicly trusted.
    public var pin: String?

    public init(purpose: Purpose, controlKey: Data, secret: Data, addresses: [String], name: String) {
        self.purpose = purpose
        self.controlKey = controlKey
        self.secret = secret
        self.addresses = addresses
        self.name = name
    }

    /// A version 2 code: one address and, when needed, a pin.
    public init(purpose: Purpose, controlKey: Data, secret: Data, url: String, pin: String?, name: String) {
        self.init(purpose: purpose, controlKey: controlKey, secret: secret, addresses: [], name: name)
        self.url = url
        self.pin = pin
    }

    public static let lifetime: TimeInterval = 5 * 60

    public var text: String {
        let kind: String
        let grant: String
        switch purpose {
        case .client(let given): kind = "c"; grant = given.rawValue
        case .host: kind = "h"; grant = "-"
        }
        if let url {
            return ["agents-control", "2", kind, grant, Self.base64url(controlKey), Self.base64url(secret),
                    Self.escape(url), pin ?? "-", Self.escape(name)].joined(separator: ":")
        }
        return ["agents-control", "1", kind, grant, Self.base64url(controlKey), Self.base64url(secret),
                Self.escape(addresses.joined(separator: ",")), Self.escape(name)].joined(separator: ":")
    }

    /// A code read back from its text; whitespace around it, as a paste brings, is let go.
    public init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let version2 = parts.count == 9 && parts.first == "agents-control" && parts[1] == "2"
        guard version2 || (parts.count == 8 && parts[0] == "agents-control" && parts[1] == "1"),
              let key = Self.data(base64url: parts[4]), key.count == 65, key.first == 0x04,
              let secret = Self.data(base64url: parts[5]), secret.count == 32,
              let where_ = parts[6].removingPercentEncoding,
              let name = parts[version2 ? 8 : 7].removingPercentEncoding
        else { return nil }
        if version2 {
            // https only, except on this machine: a walk or a test on loopback.
            guard let url = URL(string: where_), let host = url.host,
                  ["https", "wss"].contains(url.scheme) || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
            else { return nil }
            let pin = parts[7]
            guard pin == "-" || Self.data(base64url: pin)?.count == 32 else { return nil }
            self.url = where_
            self.pin = pin == "-" ? nil : pin
        }
        switch (parts[2], parts[3]) {
        case ("c", let grant): guard let grant = Grant(rawValue: grant) else { return nil }; purpose = .client(grant)
        case ("h", "-"): purpose = .host
        default: return nil
        }
        controlKey = key
        self.secret = secret
        self.addresses = version2 ? [] : where_.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        self.name = name
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? ""
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

public extension DaemonAPI {
    /// `clients/startPairing`, `hosts/startEnroll`: the code, and until when it works.
    struct ControlCodeShown: Codable, Sendable, Hashable {
        public var text: String
        public var expires: Date
        /// For a host code: the one line to run on the server, which installs the host and
        /// joins with the code (058, T071).
        public var command: String?
        public init(text: String, expires: Date, command: String? = nil) {
            self.text = text
            self.expires = expires
            self.command = command
        }
    }

    /// `clients/announce`, on a pairing connection.
    struct ClientAnnounce: Codable, Sendable, Hashable {
        public var id: UUID
        public var publicKey: Data
        public var name: String
        public var kind: ClientRecord.Kind
        public init(id: UUID, publicKey: Data, name: String, kind: ClientRecord.Kind) {
            self.id = id
            self.publicKey = publicKey
            self.name = name
            self.kind = kind
        }
    }

    /// `hosts/announce`, on an enrolment connection.
    struct HostAnnounce: Codable, Sendable, Hashable {
        public var publicKey: Data
        public var name: String
        public var platform: String
        public var version: String
        public var machineID: String
        /// `agents-relay` enrolling (T096): never the home host, and relaying from the start.
        public var relay: Bool?
        public init(publicKey: Data, name: String, platform: String, version: String, machineID: String,
                    relay: Bool? = nil) {
            self.relay = relay
            self.publicKey = publicKey
            self.name = name
            self.platform = platform
            self.version = version
            self.machineID = machineID
        }
    }

    /// What either announce is answered with: who the new party now is, and what it may do.
    struct Admitted: Codable, Sendable, Hashable {
        public var client: UUID?
        public var host: HostID?
        public var grant: Grant?
        public init(client: UUID? = nil, host: HostID? = nil, grant: Grant? = nil) {
            self.client = client
            self.host = host
            self.grant = grant
        }
    }
}
