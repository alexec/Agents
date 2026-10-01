import Foundation

/// One place a control plane answers: its URL, and its certificate's pin when that is not
/// publicly trusted (058, research R16). A member keeps a list of them, in the order to
/// try, and every `ok` may bring a newer list, so a control plane can move or change its
/// certificate without anyone pairing again.
public struct ControlEndpoint: Codable, Sendable, Hashable {
    public var url: String
    public var pin: String?

    public init(url: String, pin: String? = nil) {
        self.url = url
        self.pin = pin
    }

    /// What a code would accept (`ControlCode`): https, or http on this machine only, and
    /// a pin that is a SHA-256 in base64url.
    public var isAcceptable: Bool {
        guard let parsed = URL(string: url), let host = parsed.host, let scheme = parsed.scheme?.lowercased() else { return false }
        let secure = ["https", "wss"].contains(scheme)
        guard secure || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)) else { return false }
        return pin.map { ControlCode.data(base64url: $0)?.count == 32 } ?? true
    }
}

public extension ControlMembership {
    /// The places to dial, in order: the list the control plane last gave, or the one
    /// address a version 2 code gave.
    var endpointsToDial: [ControlEndpoint] {
        if let endpoints, !endpoints.isEmpty { return endpoints }
        return url.map { [ControlEndpoint(url: $0, pin: pin)] } ?? []
    }

    /// This membership with a list the control plane gave in `ok`, if it is newer than
    /// the one kept and every entry is one a code could carry; nil if nothing changes.
    func adopting(_ endpoints: [ControlEndpoint]?, epoch: Int?) -> ControlMembership? {
        guard let endpoints, let epoch, !endpoints.isEmpty, epoch > (self.epoch ?? 0),
              endpoints.allSatisfy(\.isAcceptable) else { return nil }
        var changed = self
        changed.endpoints = endpoints
        changed.epoch = epoch
        changed.url = endpoints[0].url
        changed.pin = endpoints[0].pin
        return changed
    }
}

public extension ControlSettings {
    /// Where the control plane answers now, in order: the list announced, or its one
    /// address.
    var currentEndpoints: [ControlEndpoint] {
        if let endpoints, !endpoints.isEmpty { return endpoints }
        return url.map { [ControlEndpoint(url: $0, pin: pin)] } ?? []
    }
}
