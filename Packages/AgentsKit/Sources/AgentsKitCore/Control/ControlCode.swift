import Foundation

/// A pairing or enrolment code, as the control plane shows it and another machine takes
/// it (058, data-model.md `PairingCode`, T019/T029).
///
/// What it holds is what the new party needs and nothing more: the control plane's
/// public key, a one-time secret, what the code lets its holder become, and where to
/// reach the control plane. Its text is one line, to paste or to put in a QR code:
///
///     agents-control:1:<c|h>:<grant or ->:<key>:<secret>:<addresses>:<name>
///
/// with the key and the secret in base64url, the addresses comma-separated `host:port`,
/// and the addresses and name percent-encoded.
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

    public init(purpose: Purpose, controlKey: Data, secret: Data, addresses: [String], name: String) {
        self.purpose = purpose
        self.controlKey = controlKey
        self.secret = secret
        self.addresses = addresses
        self.name = name
    }

    public static let lifetime: TimeInterval = 5 * 60

    public var text: String {
        let kind: String
        let grant: String
        switch purpose {
        case .client(let given): kind = "c"; grant = given.rawValue
        case .host: kind = "h"; grant = "-"
        }
        return ["agents-control", "1", kind, grant, Self.base64url(controlKey), Self.base64url(secret),
                Self.escape(addresses.joined(separator: ",")), Self.escape(name)].joined(separator: ":")
    }

    /// A code read back from its text; whitespace around it, as a paste brings, is let go.
    public init?(text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 8, parts[0] == "agents-control", parts[1] == "1",
              let key = Self.data(base64url: parts[4]), key.count == 65, key.first == 0x04,
              let secret = Self.data(base64url: parts[5]), secret.count == 32,
              let addresses = parts[6].removingPercentEncoding, let name = parts[7].removingPercentEncoding
        else { return nil }
        switch (parts[2], parts[3]) {
        case ("c", let grant): guard let grant = Grant(rawValue: grant) else { return nil }; purpose = .client(grant)
        case ("h", "-"): purpose = .host
        default: return nil
        }
        controlKey = key
        self.secret = secret
        self.addresses = addresses.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        self.name = name
    }

    private static func escape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_"))) ?? ""
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func data(base64url text: String) -> Data? {
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
        public init(text: String, expires: Date) {
            self.text = text
            self.expires = expires
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
        public init(publicKey: Data, name: String, platform: String, version: String, machineID: String) {
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
