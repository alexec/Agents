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
// **Started by hand, deliberately.** There is no pairing and no encryption here yet,
// so anything on this network that can find the service can drive the daemon. Until
// `Envelope` and the paired-device list exist, the safety is that this only runs while
// somebody has decided it should, and stops when they close the terminal. Nothing
// spawns it and nothing keeps it alive.

// `--spike` is 021's T056, the gate the whole of Slice C hangs on: can *this bundle*,
// nested and signed the way it is, read and write a record in the CloudKit private
// database? It answers by doing it and prints the answer, and it exists so that the
// question is settled by running something rather than by reading Apple's forum.
if CommandLine.arguments.contains("--spike") {
    Task {
        do {
            try await Spike.run()
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
    private var pending = Data()

    init(device: NWConnection) {
        self.device = device
    }

    func start() {
        device.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Task { @MainActor in await self?.openTheDaemon() }
            case .failed, .cancelled:
                Task { @MainActor in self?.stop() }
            default:
                break
            }
        }
        device.start(queue: .main)
    }

    private func openTheDaemon() async {
        do {
            let transport = try await SocketLink().transport()
            daemon = transport
            log("a device connected")
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
                if isComplete || error != nil { self.stop(); return }
                self.readFromDevice()
            }
        }
    }

    /// Whole lines only. A line can arrive in three pieces and two lines can arrive as
    /// one read, and the daemon's protocol is one JSON object per line.
    private func forward(_ data: Data) {
        pending.append(data)
        while let i = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            pending = pending[pending.index(after: i)...]
            if !line.isEmpty { try? daemon?.write(line: line) }
        }
    }

    private func send(_ line: String) {
        device.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func stop() {
        daemon?.close()
        daemon = nil
        device.cancel()
    }
}

/// Held so a relay is not collected the moment it is made. They leave when the device
/// does; a handful over an afternoon is not worth a sweep.
@MainActor
enum Relays {
    static var open: [Relay] = []
}

let parameters = NWParameters.tcp
// So the iPad can find this without anybody typing an address.
parameters.includePeerToPeer = true

let listener = try NWListener(using: parameters, on: port)
listener.service = NWListener.Service(name: Host.current().localizedName ?? "This Mac",
                                      type: NetworkLink.serviceType)

listener.newConnectionHandler = { connection in
    Task { @MainActor in
        let relay = Relay(device: connection)
        Relays.open.append(relay)
        relay.start()
    }
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        log("listening on port \(port), advertised as \(NetworkLink.serviceType)")
        log("this has no pairing and no encryption. Stop it when you are done.")
    case .failed(let error):
        log("could not listen: \(error)")
        exit(1)
    default:
        break
    }
}

listener.start(queue: .main)
dispatchMain()
