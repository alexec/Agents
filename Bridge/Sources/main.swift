import AgentsKit
import AgentsKitCore
import Foundation
import Network

// The Mac end of the direct connection: a door onto the daemon for a device on the
// same network.
//
// It is an ordinary client of `agentsd` — it connects over the Unix socket like any
// window, and the daemon gains no listener and no network code. What this process does
// is carry lines: one connection from a device, one connection to the daemon, bytes
// straight through in both directions. It parses none of them, which is what keeps it
// small enough to read in one sitting.
//
// **Locked since the security review's Phase 3.** The listener takes TLS with a key per
// paired device and nothing else (`DirectLink`), so a connection without one fails in
// the handshake, before a line of it reaches here. Which device it is comes from the
// key, and the daemon connection it is carried on is that device's, with a device's
// rights. A phone pairing with the code on the Mac's screen gets a connection that may
// announce itself and do nothing more.
//
// The relay (046) is the same seen from away: everything it carries is sealed to one
// paired device and the Mac's own key, and nothing from any other device is opened.
// See `RelayHost`.

// `--spike` is 021's T056, the gate the whole of Slice C hangs on: can *this bundle*,
// nested and signed the way it is, read and write a record in the CloudKit private
// database? It answers by doing it and prints the answer, and it exists so that the
// question is settled by running something rather than by reading Apple's forum.
if CommandLine.arguments.contains("--spike-relay") {
    Task {
        do {
            try await RelaySpike.run()
            exit(0)
        } catch {
            log("relay spike failed: \(error)")
            exit(2)
        }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--spike") || CommandLine.arguments.contains("--peek") {
    Task {
        do {
            if let at = CommandLine.arguments.firstIndex(of: "--peek"), CommandLine.arguments.count > at + 1 {
                try await Peek.run(device: CommandLine.arguments[at + 1])
            } else {
                try await Spike.run()
            }
            exit(0)
        } catch {
            log("spike failed: \(error)")
            exit(2)
        }
    }
    dispatchMain()
}

let port: NWEndpoint.Port = {
    guard let raw = ProcessInfo.processInfo.environment["AGENTS_BRIDGE_PORT"],
          let value = UInt16(raw), let port = NWEndpoint.Port(rawValue: value)
    else { return NWEndpoint.Port(rawValue: 8790)! }
    return port
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("agents-bridge: \(message)\n".utf8))
}

/// One device, holding a connection to the daemon of its own for as long as it stays.
///
/// A connection each rather than one shared: the daemon broadcasts notifications to
/// every connection, and two devices sharing one would each see half of them.
@MainActor
final class Relay {
    private let device: NWConnection
    private var daemon: (any LineTransport)?
    /// Nothing a device sends is this long: a phone's attachments stop at 900 KB and a
    /// file written from elsewhere at 25 MB, both base64 in the line. Past it, the
    /// other end is not one of ours, and nothing on this network is kept for it.
    private var splitter = LineSplitter(maximumLine: 64 * 1024 * 1024)
    /// Bytes handed to the device and not yet taken by the network. The daemon gives
    /// up on a client that stops reading; this is the same for the device, which would
    /// otherwise have every broadcast held here for it until it came back.
    private var unsent = 0
    private static let unsentLimit = 16 * 1024 * 1024
    private var stopped = false
    private let chosen: ChosenIdentities

    init(device: NWConnection, chosen: ChosenIdentities) {
        self.device = device
        self.chosen = chosen
    }

    func start() {
        device.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in self?.admit() }
            case .failed, .cancelled:
                Task { @MainActor in self?.stop() }
            default:
                break
            }
        }
        device.start(queue: .main)
    }

    /// Who the handshake says this is, before anything of theirs is carried: the key
    /// it was locked with names a paired device or the pairing code, and the suite has
    /// to be the one asked for rather than a weaker one agreed beside it.
    private func admit() {
        guard LinkTLS.agreedTheSuite(device) else {
            log("a device agreed a weaker TLS suite; closing it")
            stop()
            return
        }
        guard let identity = chosen.take(for: device) else {
            log("a device's key could not be told; closing it")
            stop()
            return
        }
        if let id = LinkKey.device(fromIdentity: identity) {
            Task { await openTheDaemon(device: id, pairing: false) }
        } else if LinkKey.isPairing(identity) {
            Task { await openTheDaemon(device: nil, pairing: true) }
        } else {
            stop()
        }
    }

    private func openTheDaemon(device id: UUID?, pairing: Bool) async {
        do {
            // A device's connection, not a window's: the daemon hears nothing from the
            // device until it has agreed, and then only as that device.
            let transport = try await DeviceBinder.bind(try await SocketLink().transport(), device: id,
                                                        pairing: pairing)
            // The device can go while the daemon is being reached.
            guard !stopped else { transport.close(); return }
            daemon = transport
            log(pairing ? "a device connected to pair" : "a device connected")
            Task { @MainActor in
                do {
                    for try await line in transport.lines() { send(line) }
                } catch {
                    // The daemon went. Taking the device's connection with it is the
                    // honest answer: the remote says it is out of touch and comes back.
                }
                stop()
            }
            readFromDevice()
        } catch {
            log("could not reach the daemon: \(error)")
            stop()
        }
    }

    private func readFromDevice() {
        device.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.forward(data) }
                if isComplete || error != nil || self.stopped { self.stop(); return }
                self.readFromDevice()
            }
        }
    }

    /// Whole lines only. A line can arrive in three pieces and two lines can arrive as
    /// one read, and the daemon's protocol is one JSON object per line.
    private func forward(_ data: Data) {
        splitter.append(data)
        while let line = splitter.next() { try? daemon?.write(line: line) }
        if splitter.overflowed {
            log("a device sent a line longer than any request; closing it")
            stop()
        }
    }

    private func send(_ line: String) {
        // Lines the daemon had already sent still arrive after a stop.
        guard !stopped else { return }
        let data = Data((line + "\n").utf8)
        unsent += data.count
        if unsent > Self.unsentLimit {
            // Closing is what tells it to start again, and a device that comes back
            // asks for everything afresh, so what it missed here is not lost.
            log("a device stopped reading; closing it")
            stop()
            return
        }
        device.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.unsent -= data.count }
        })
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        daemon?.close()
        daemon = nil
        device.cancel()
        Relays.open.removeAll { $0 === self }
    }
}

/// Held so a relay is not collected the moment it is made. Each takes itself out when
/// it stops; until 2026-09-25 none did, and every reconnect of a phone stayed here.
@MainActor
enum Relays {
    static var open: [Relay] = []
}

// The control plane (058), when given a root: this Mac's window and this Mac's host
// meet here, and the window reaches its host through it. Devices keep the way below,
// straight to the host's socket, until they move onto the router (US4).
let controlPlane: ControlPlane? = ControlPlane.chosenRoot().map { root in
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    DaemonLog.shared.setDestination(root.appendingPathComponent("control.log"))
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    // Its own port, beside the bridge's: phones paired the old way keep 8790.
    let controlPort = ProcessInfo.processInfo.environment[ControlNet.portVariable].flatMap(Int.init)
        ?? Int(ControlNet.defaultPort)
    return ControlPlane(root: root, version: version, port: controlPort,
                        awayFromHome: ProcessInfo.processInfo.environment["AGENTS_BRIDGE_NO_MAILBOX"] == nil)
}
if let controlPlane {
    Task {
        do {
            try await controlPlane.start()
            log("control plane at \(controlPlane.root.path)")
        } catch {
            log("the control plane could not start: \(error)")
            exit(1)
        }
    }
}

let directLink = DirectLink(port: port)
directLink.start()

// The mailbox, unless told not to: a Mac with no iCloud account, or a walk that wants
// the LAN alone, sets AGENTS_BRIDGE_NO_MAILBOX and the bridge is what it was.
let mailboxTransport = MailboxTransport()
// And the relay (046), switched off by the same flag: both need iCloud.
let relayHost = RelayHost()
if ProcessInfo.processInfo.environment["AGENTS_BRIDGE_NO_MAILBOX"] == nil {
    mailboxTransport.start()
    relayHost.start()
}

dispatchMain()
