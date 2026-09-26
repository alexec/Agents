import AgentsKit
import AgentsKitCore
import CryptoKit
import Foundation
import Network

/// The listener on the home network, locked with a key per paired device (security
/// review, Phase 3).
///
/// Each device's key is what its key and the Mac's relay key share, so nothing is kept
/// here that the daemon's device list and the keychain do not already hold. While the
/// Mac shows a pairing code, the code's key is taken too, for as long as it is good.
///
/// Network framework chooses among keys given to a listener when it is made, so a
/// device paired or forgotten, or a code shown or spent, means a new listener on the
/// same port. The connections the old one accepted carry on: a forgotten device's are
/// ended by the daemon closing its side (`devices/forget`), not by this.
@MainActor
final class DirectLink {
    private let port: NWEndpoint.Port
    private let client = DaemonClient(link: SocketLink())
    private let chosen = ChosenIdentities()
    private var listener: NWListener?
    private var macKey: DeviceKey?
    private var devices: [UUID: Data] = [:]
    private var pairingSecret: Data?
    /// The identities the running listener takes, to know when a new one is needed.
    private var listening: Set<String>?

    init(port: NWEndpoint.Port) {
        self.port = port
    }

    func start() {
        do {
            macKey = try DeviceKey.load(account: "relay-mac-key", enclave: false)
        } catch {
            log("direct link: no Mac key, so no device can connect: \(error)")
            return
        }
        Task { await follow() }
    }

    /// Stay with the daemon for as long as the bridge runs: who is paired, and whether a
    /// code is showing. Registering the key here too means the direct link works on a
    /// Mac whose relay is switched off.
    private func follow() async {
        guard let macKey else { return }
        while !Task.isCancelled {
            do {
                try await client.connect(startIfNeeded: false)
                _ = try await client.call(DaemonAPI.Method.relayRegister,
                                          DaemonAPI.RelayRegistration(publicKey: macKey.publicKey))
                try await refreshDevices()
                try await refreshPairing()
                for await notification in client.notifications() {
                    switch notification.method {
                    case DaemonAPI.Notification.deviceChanged: try await refreshDevices()
                    case DaemonAPI.Notification.pairingChanged: try await refreshPairing()
                    default: continue
                    }
                }
                log("direct link: the daemon went away")
            } catch {
                // No daemon yet. Back in a while.
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func refreshDevices() async throws {
        let listed = try await client.call(DaemonAPI.Method.devicesList, Optional<String>.none, returning: [Device].self)
        devices = Dictionary(listed.map { ($0.id, $0.publicKey) }, uniquingKeysWith: { first, _ in first })
        relisten()
    }

    private func refreshPairing() async throws {
        let current = try await client.call(DaemonAPI.Method.pairingCurrent, Optional<String>.none,
                                            returning: DaemonAPI.PairingSecret.self)
        pairingSecret = current.secret
        relisten()
        // Past its time the daemon refuses the code anyway; the listener lets it go too.
        if let expires = current.expires {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow) + 1))
                try? await self?.refreshPairing()
            }
        }
    }

    private func keys() -> [String: SymmetricKey] {
        guard let macKey else { return [:] }
        var keys: [String: SymmetricKey] = [:]
        for (id, publicKey) in devices {
            // A record from before devices had keys cannot be let in: there is nothing
            // to lock its link with. It pairs again.
            guard let key = try? macKey.linkKey(with: publicKey, device: id) else { continue }
            keys[LinkKey.deviceIdentity(id)] = key
        }
        if let pairingSecret {
            keys[LinkKey.pairingIdentity(pairingSecret)] = LinkKey.pairing(pairingSecret)
        }
        return keys
    }

    private func relisten() {
        let keys = keys()
        guard Set(keys.keys) != listening else { return }
        listening = Set(keys.keys)
        // One listener on the port at a time: the next is made once the last has let go,
        // or it finds the address in use.
        if let old = listener {
            listener = nil
            old.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else { return }
                Task { @MainActor in self?.listen(with: self?.keys() ?? keys) }
            }
            old.cancel()
        } else {
            listen(with: keys)
        }
    }

    private func listen(with keys: [String: SymmetricKey]) {
        // A later change may have been heard while the last listener let go.
        listening = Set(keys.keys)
        guard listener == nil else { relisten(); return }
        do {
            let parameters = LinkTLS.server(keys: keys, chosen: chosen)
            // So the iPad can find this without anybody typing an address.
            parameters.includePeerToPeer = true
            // The listener before this one may not have let go of the port yet.
            parameters.allowLocalEndpointReuse = true
            let made = try NWListener(using: parameters, on: port)
            // A walk's bridge on a scratch root stays off Bonjour, where the person's own
            // phone would otherwise find it and try it before the real one.
            if ProcessInfo.processInfo.environment["AGENTS_BRIDGE_NO_BONJOUR"] == nil {
                made.service = NWListener.Service(name: DirectLink.name, type: NetworkLink.serviceType)
            }
            made.newConnectionHandler = { [chosen] connection in
                Task { @MainActor in
                    let relay = Relay(device: connection, chosen: chosen)
                    Relays.open.append(relay)
                    relay.start()
                }
            }
            let devices = self.devices.count, pairing = pairingSecret != nil
            made.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    log("listening on port \(self.port) with TLS for \(devices) device(s)"
                        + (pairing ? " and a pairing code" : ""))
                case .failed(let error):
                    // Most likely the port, not yet let go by the listener before. Try
                    // again rather than leave the phone with no way in.
                    log("could not listen: \(error); trying again")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        self?.listening = nil
                        self?.relisten()
                    }
                default:
                    break
                }
            }
            made.start(queue: .main)
            listener = made
        } catch {
            log("could not listen: \(error); trying again")
            listening = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.relisten()
            }
        }
    }

    /// What the phone looks for, and what the pairing code names.
    static var name: String { Host.current().localizedName ?? "This Mac" }
}
