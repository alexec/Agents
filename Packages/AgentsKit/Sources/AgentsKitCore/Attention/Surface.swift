import Foundation

/// Somewhere a person can be reached: a connected Agents window, or a paired device.
///
/// Two cases and no third. `Codable` as a tagged object — `{"mac": {}}` or
/// `{"device": "<uuid>"}` — rather than a bare string, so that a third case later, a
/// watch if it ever happens, is additive rather than a re-parse of everything on the wire.
public enum Surface: Hashable, Sendable, Codable {
    case mac
    case device(UUID)

    private enum CodingKeys: String, CodingKey { case mac, device }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.device) {
            self = .device(try c.decode(UUID.self, forKey: .device))
        } else if c.contains(.mac) {
            self = .mac
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a surface is mac or device"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mac: try c.encode([String: String](), forKey: .mac)
        case .device(let id): try c.encode(id, forKey: .device)
        }
    }

    public var isMac: Bool { if case .mac = self { return true }; return false }
    public var deviceID: UUID? { if case .device(let id) = self { return id }; return nil }
}
