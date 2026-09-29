// Not on Linux: the relay is iCloud's (037, 046).
#if canImport(CryptoKit)
import Foundation

public extension ControlCodeUse {
    /// How a paired device dials through `agents-relay` when the control plane's address
    /// cannot be reached (058, T077): a relayed session in iCloud, sealed between this
    /// device's key and the relay's, and inside it the same key exchange with the control
    /// plane as over the network, end to end. It says it came through the relay, for
    /// itself, and the control plane holds it to that.
    static func relayedDial(_ membership: ControlMembership, privateKey: Data, relayKey: Data,
                            channel: any RelayChannel,
                            onTrouble: @escaping @Sendable (RelayTrouble) -> Void = { _ in })
        throws -> @Sendable () async throws -> any LineTransport {
        guard let text = membership.url, let url = URL(string: text), let origin = ControlAuth.origin(url),
              let client = membership.client else {
            throw Failure("that membership has no address; it is from the first build")
        }
        let key = try ControlAuth.clientKey(privateKey: privateKey, peer: membership.controlKey, client: client)
        let credentials = ControlAuth.Credentials(identity: .client(client), key: key, kind: "relay",
                                                  controlKey: membership.controlKey, relayingFor: client)
        let sealing = try DeviceKey.software(privateKey: privateKey)
        return {
            let relayed = RelayTransport(channel: channel, device: client, key: sealing, macKey: relayKey,
                                         onTrouble: onTrouble)
            try await relayed.open()
            return try await ControlAuth.join(relayed, origin: origin, as: credentials, within: 30).transport
        }
    }
}
#endif
