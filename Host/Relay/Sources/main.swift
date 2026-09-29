import AgentsKit
import AgentsKitCore
import Foundation

// agents-relay (058, T096–T097): carries this person's devices through iCloud to their
// control plane when they are away, and posts their notices to the iCloud mailbox.
//
// It is what the bridge's relay and mailbox became once a control plane chooses who is
// told what: it enrols with a host code as a host that only relays, runs no agents, and
// opens nothing on the daemon. A device's relayed session is a WebSocket of its own to
// the control plane, with every line carried untouched, the key exchange first.
//
// Signed as the bridge, with the bridge's iCloud container, so nothing changes in the
// developer account; so it must not run beside the old bridge's mailbox on one Mac.
//
//     agents-relay --join '<host code>' [--name <name>]   once, then:
//     agents-relay [--name <name>]
//
// `AGENTS_ROOT=<dir>` keeps its membership and key in `<dir>/relay`, as Agents Host's
// scratch set-ups do; `AGENTS_RELAY_FOLDER=<dir>` stands a folder in for iCloud, for a
// walk, so nothing reaches the person's iCloud.

func log(_ message: String) {
    let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    FileHandle.standardError.write(Data("agents-relay \(stamp): \(message)\n".utf8))
}

func argument(_ name: String) -> String? {
    guard let at = CommandLine.arguments.firstIndex(of: name), CommandLine.arguments.count > at + 1 else { return nil }
    return CommandLine.arguments[at + 1]
}

let environment = ProcessInfo.processInfo.environment
let folder: URL = {
    if let root = environment[StoreLocations.rootVariable], !root.isEmpty {
        return URL(fileURLWithPath: (root as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("relay", isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Agents Relay", isDirectory: true)
}()
let files = ControlRelay.Files(folder: folder)
let name = argument("--name") ?? ((Host.current().localizedName ?? "This Mac") + " relay")

Task {
    do {
        if let text = argument("--join") {
            guard let code = ControlCode(text: text) else {
                log("that is not a host code")
                exit(64)
            }
            let membership = try await ControlRelay.enroll(code, files: files, name: name)
            log("joined \(membership.name) as \(membership.host?.rawValue ?? "?")")
        }
        let channel: any RelayChannel
        let mailbox: any Mailbox
        if let stand = environment["AGENTS_RELAY_FOLDER"], !stand.isEmpty {
            let place = URL(fileURLWithPath: (stand as NSString).expandingTildeInPath, isDirectory: true)
            channel = FolderRelayChannel(folder: place)
            mailbox = FolderMailbox(folder: place)
            log("iCloud stood in for by \(place.path)")
        } else {
            channel = CloudKitRelayChannel()
            mailbox = CloudKitMailbox()
        }
        let relay = try ControlRelay(files: files, name: name, channel: channel, mailbox: mailbox, log: log)
        await relay.start()
        log("relaying; key \(relay.publicKey.base64EncodedString().prefix(16))…")
        for signal in [SIGTERM, SIGINT] {
            Foundation.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
            source.setEventHandler {
                relay.stop()
                exit(0)
            }
            source.resume()
            Stopping.sources.append(source)
        }
    } catch {
        log("\(error)")
        exit(1)
    }
}

enum Stopping { nonisolated(unsafe) static var sources: [any DispatchSourceSignal] = [] }

dispatchMain()
