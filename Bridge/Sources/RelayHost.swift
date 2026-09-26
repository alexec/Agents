import AgentsKit
import AgentsKitCore
import CloudKit
import Foundation

/// The fourth carrier, beside the socket, the LAN relay and the mailbox: what lets a
/// paired device use this Mac from anywhere (046).
///
/// Everything that decides anything is `RelayHostCore`, in the kit where the tests run
/// it end to end. This gives it what only a real Mac has: the Mac's own relay key in the
/// keychain, the person's CloudKit, the daemon's socket, and the paired devices as the
/// daemon lists them — kept current from `device/changed`, so a device forgotten in
/// Settings is cut off as soon as the daemon says so (FR-008).
///
/// It registers the key's public half with the daemon on every connection, which is how
/// a device announcing on the direct link comes to be given it (R4).
@MainActor
final class RelayHost {
    private let client = DaemonClient(link: SocketLink())
    private var host: RelayHostCore?
    private var carrying: Task<Void, Never>?
    private var sweeping: Task<Void, Never>?

    func start() {
        let key: DeviceKey
        do {
            key = try DeviceKey.load(account: "relay-mac-key", enclave: false)
        } catch {
            log("relay: no key, so nothing is carried from away: \(error)")
            return
        }
        let host = RelayHostCore(channel: CloudKitRelayChannel(), key: key,
                                 openDaemon: { try await SocketLink().transport() })
        self.host = host
        carrying = Task { await host.run() }
        sweeping = Task {
            while !Task.isCancelled {
                await host.sweep()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
        Task { await follow(key: key, host: host) }
    }

    /// Stay connected to the daemon for as long as the bridge runs: register the key, and
    /// keep the host's list of who may be carried for.
    private func follow(key: DeviceKey, host: RelayHostCore) async {
        while !Task.isCancelled {
            do {
                try await client.connect(startIfNeeded: false)
                _ = try await client.call(DaemonAPI.Method.relayRegister,
                                          DaemonAPI.RelayRegistration(publicKey: key.publicKey))
                let devices = try await client.call(DaemonAPI.Method.devicesList, Optional<String>.none,
                                                    returning: [Device].self)
                await host.setPaired(Dictionary(devices.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { a, _ in a }))
                log("relay: carrying for \(devices.count) device(s)")
                for await notification in client.notifications()
                where notification.method == DaemonAPI.Notification.deviceChanged {
                    guard let change = try? notification.params?.decode(DaemonAPI.DeviceNotification.self) else { continue }
                    if change.removed == true {
                        await host.forget(change.id)
                        log("relay: forgot a device")
                    } else if let device = change.device {
                        await host.pair(device.id, key: device.publicKey)
                    }
                }
                log("relay: the daemon went away")
            } catch {
                // No daemon yet. Back in a while.
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }
}
