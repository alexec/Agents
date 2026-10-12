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
// Agents Host's *Relay for my devices* (#809) leaves the code in `relay-join-code` in the
// relay's folder instead, and starts it as a launch agent with no arguments.
//
// `AGENTS_ROOT=<dir>` keeps its membership and key in `<dir>/relay`, as Agents Host's
// scratch set-ups do; `AGENTS_RELAY_FOLDER=<dir>` stands a folder in for iCloud, for a
// walk, so nothing reaches the person's iCloud.

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

// Also kept in `relay.log` in its folder (#809): a launch agent's stderr goes nowhere, and
// this is the log Agents Host's diagnostics read. Rolled once at 1 MB, at start.
let logFile: FileHandle? = {
    let file = folder.appendingPathComponent("relay.log")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 1_000_000 {
        let old = folder.appendingPathComponent("relay.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let handle = try? FileHandle(forWritingTo: file)
    _ = try? handle?.seekToEnd()
    return handle
}()

func log(_ message: String) {
    let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    let line = Data("agents-relay \(stamp): \(message)\n".utf8)
    FileHandle.standardError.write(line)
    try? logFile?.write(contentsOf: line)
}

let name = argument("--name") ?? ((Host.current().localizedName ?? "This Mac") + " relay")

Task {
    do {
        let joined = ControlMembership.load(files.membership) != nil
        let left = joined ? nil : (try? String(contentsOf: files.joinCode, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let text = argument("--join") ?? left {
            guard let code = ControlCode(text: text) else {
                log("that is not a host code")
                exit(64)
            }
            let membership = try await ControlRelay.enroll(code, files: files, name: name)
            log("joined \(membership.name) as \(membership.host?.rawValue ?? "?")")
        }
        // Spent, or never needed: a code is not kept once there is a membership.
        if ControlMembership.load(files.membership) != nil { try? FileManager.default.removeItem(at: files.joinCode) }
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
        // A network change dials now, not when the wait is up (#172, as #82 did for agentsd).
        let triggers = ReconnectTriggers(queue: DispatchQueue(label: "relay.triggers")) { reason in
            let nudged = relay.goBackNow()
            if nudged != .idle { log("relay: \(reason.rawValue): dialling now (\(nudged))") }
        }
        triggers.start()
        Stopping.triggers = triggers
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

enum Stopping {
    nonisolated(unsafe) static var sources: [any DispatchSourceSignal] = []
    nonisolated(unsafe) static var triggers: ReconnectTriggers?
}

dispatchMain()
