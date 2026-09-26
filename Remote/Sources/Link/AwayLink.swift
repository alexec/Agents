import AgentsKitCore
import Foundation

/// The phone's way to its Mac, near or far (046).
///
/// A `LinkChooser` over the two links: Bonjour to the bridge on the same network, and the
/// relay through the person's iCloud otherwise. The relay is only tried with the Mac's
/// key, which the Mac hands over in the reply to `devices/announce` on the direct link;
/// a phone that has never been on the Mac's network has none, and says so rather than
/// writing anything to iCloud (FR-009).
///
/// It also keeps the relayed session in hand, so a push can make it look for the Mac's
/// frames at once.
final class AwayLink: @unchecked Sendable {
    static let macKeyAccount = "relay-mac-key-public"

    let chooser: LinkChooser
    private let lock = NSLock()
    private weak var relayed: RelayTransport?
    private var hearTrouble: @Sendable (RelayTrouble) -> Void = { _ in }

    init(device: UUID, key: DeviceKey?) {
        let box = Box()
        chooser = LinkChooser(
            direct: { try await NetworkLink(howLongToLook: .seconds(10)).transport() },
            relay: {
                guard let key, let macKey = AwayLink.macKey else { throw RelayTrouble.notPaired }
                let transport = RelayTransport(channel: CloudKitRelayChannel(), device: device, key: key, macKey: macKey,
                                               onTrouble: { box.link?.heard($0) })
                box.link?.hold(transport)
                try await transport.open()
                return transport
            },
            probe: { try await NetworkLink(howLongToLook: .seconds(3)).transport() })
        box.link = self
    }

    /// Set once, by the model, before anything connects.
    func onTrouble(_ hear: @escaping @Sendable (RelayTrouble) -> Void) {
        lock.withLock { hearTrouble = hear }
    }

    /// A relay push arrived: look now.
    func poke() {
        lock.withLock { relayed }?.poke()
    }

    /// The Mac's relay key, as the last announce on the direct link handed it over.
    static var macKey: Data? {
        DeviceKey.publicKey(account: macKeyAccount, accessGroup: DeviceKey.sharedAccessGroup)
    }

    static func keepMacKey(_ key: Data?) {
        try? DeviceKey.keepPublicKey(key, account: macKeyAccount, accessGroup: DeviceKey.sharedAccessGroup)
    }

    private func hold(_ transport: RelayTransport) {
        lock.withLock { relayed = transport }
    }

    private func heard(_ trouble: RelayTrouble) {
        lock.withLock { hearTrouble }(trouble)
    }

    /// So the relay closure can reach the link it belongs to without the link existing
    /// yet when the closure is made.
    private final class Box: @unchecked Sendable {
        weak var link: AwayLink?
    }
}

extension AwayLink: DaemonLink {
    func transport() async throws -> any LineTransport { try await chooser.transport() }
}
