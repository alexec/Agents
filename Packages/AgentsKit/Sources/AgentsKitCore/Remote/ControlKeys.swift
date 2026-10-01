// The Mac listener's keys. A Linux host derives the same bytes in `ControlAgreement`
// and dials with BoringSSL (058, T044); this file stays on CryptoKit.
import Foundation
#if canImport(Network) && canImport(CryptoKit)
import CryptoKit

/// The keys a control plane's network listener is locked with (058, T019).
///
/// Four kinds, told apart by the identity's first letter, as the bridge's are:
/// - `c:<uuid>` a paired client: the key is what its key and the control plane's share.
/// - `h:<host>` an enrolled host: the same, with a salt of its own.
/// - `p:<hash>` somebody holding a client code, `e:<hash>` a host code: the key comes from
///   the code's secret, and the identity names the code without giving it away.
///
/// Salts of their own, not the bridge's, so no key made for one door opens the other.
public enum ControlKeys {
    public static let clientSalt = "agents-control-client-v1"
    public static let hostSalt = "agents-control-host-v1"

    public static func clientIdentity(_ id: UUID) -> String { "c:" + id.uuidString }
    public static func hostIdentity(_ id: HostID) -> String { "h:" + id.rawValue }

    public static func codeIdentity(_ code: ControlCode) -> String {
        let prefix = if case .host = code.purpose { "e:" } else { "p:" }
        return prefix + SHA256.hash(data: code.secret).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func codeKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("agents-control-code-v1".utf8),
                               info: Data(), outputByteCount: 32)
    }

    public static func clientKey(_ key: DeviceKey, peer: Data, client: UUID) throws -> SymmetricKey {
        try key.sharedKey(with: peer, salt: clientSalt, id: client.uuidString)
    }

    public static func hostKey(_ key: DeviceKey, peer: Data, host: HostID) throws -> SymmetricKey {
        try key.sharedKey(with: peer, salt: hostSalt, id: host.rawValue)
    }

    public enum Identity: Equatable, Sendable {
        case client(UUID)
        case host(HostID)
        case pairing(String)
        case enrolling(String)
    }

    public static func read(_ identity: String) -> Identity? {
        let rest = String(identity.dropFirst(2))
        switch identity.prefix(2) {
        case "c:": return UUID(uuidString: rest).map(Identity.client)
        case "h:": return ControlWire.isHostID(rest) ? .host(HostID(rawValue: rest)) : nil
        case "p:": return .pairing(identity)
        case "e:": return .enrolling(identity)
        default: return nil
        }
    }
}
#endif

/// What a client or a host keeps once it has paired or enrolled: who it is, the control
/// plane's key, and where to find it. A JSON file beside its own key file.
///
/// The same file on a Mac and on Linux (058, T044). Nothing in it needs CryptoKit.
public struct ControlMembership: Codable, Sendable, Hashable {
    public var client: UUID?
    public var host: HostID?
    public var controlKey: Data
    public var addresses: [String]
    public var name: String
    /// The control plane's one address, and its certificate's pin: a membership made from
    /// a version 2 code, which is dialled over a WebSocket (058 re-plan).
    public var url: String?
    public var pin: String?
    /// Every place the control plane answers, in order, as it last said in `ok`, and the
    /// `epoch` of that list (R16). Absent until a control plane announces one; `url` and
    /// `pin` are then its first entry.
    public var endpoints: [ControlEndpoint]?
    public var epoch: Int?

    public init(client: UUID? = nil, host: HostID? = nil, controlKey: Data, addresses: [String], name: String,
                url: String? = nil, pin: String? = nil, endpoints: [ControlEndpoint]? = nil, epoch: Int? = nil) {
        self.client = client
        self.host = host
        self.controlKey = controlKey
        self.addresses = addresses
        self.name = name
        self.url = url
        self.pin = pin
        self.endpoints = endpoints
        self.epoch = epoch
    }

    public static func load(_ file: URL) -> ControlMembership? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(ControlMembership.self, from: data)
    }

    public func save(_ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
}
