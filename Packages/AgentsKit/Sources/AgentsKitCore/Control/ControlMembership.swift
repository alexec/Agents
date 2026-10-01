import Foundation

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
