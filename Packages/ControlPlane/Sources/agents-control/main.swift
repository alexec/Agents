import AgentsKit
import AgentsKitCore
import ControlPlaneKit
import Foundation
import NIOSSL
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// agents-control: the control plane as a service (058, contracts/store.md "Configuration").
//
//   agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
//   agents-control serve --home DIR [--no-bonjour] [--key-fd N] [--store-credentials-fd N]
//   agents-control code (--client operator|device | --host) [--minutes N] [--home DIR]
//   agents-control hosts | clients
//   agents-control move --from ROOT     an old set-up's devices into this store, once (T084)
//   agents-control install-script      the script a server runs to become a host
//   agents-control store check [--store URL]
//   agents-control store copy --from URL --to URL
//
// `--home` is Agents Host's single copy (T057): its certificate and store in DIR, port
// 8791, this Mac's .local name, and Bonjour. Anything below still overrides it.
//
// Where things are comes from the environment:
//   AGENTS_STORE                file:///path or s3://bucket/prefix
//   AGENTS_STORE_ENDPOINT, AGENTS_STORE_PATH_STYLE=1, AWS_*: the bucket (contracts/store.md)
//   --store-credentials-fd N    or the bucket's keys as JSON on an inherited descriptor
//   AGENTS_CONTROL_URL          the one address clients and hosts are given
//   AGENTS_CONTROL_PEER_URL     where other copies reach this one (several copies, US3)
//   AGENTS_CONTROL_KEY_FILE     the control plane's private key, raw, 0600 (made if missing)
//   AGENTS_CONTROL_KEY          or the key itself, base64url
//   AGENTS_CONTROL_TLS_CERT/_KEY  when this copy terminates TLS itself
//   AGENTS_CONTROL_PIN          the load balancer's certificate pin, for codes, when it terminates TLS

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agents-control: \(message)\n".utf8))
    exit(1)
}

func value(_ flag: String) -> String? {
    guard let at = arguments.firstIndex(of: flag), arguments.indices.contains(at + 1) else { return nil }
    return arguments[at + 1]
}

/// Agents Host's folder for its single copy, when given.
let home = value("--home").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

/// The bucket's keys, read once from the descriptor Agents Host handed over (T058a): they
/// are never in a plist, a file or the environment.
let storeCredentials: S3Store.Credentials? = {
    guard let fd = value("--store-credentials-fd").flatMap(Int32.init) else { return nil }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    guard let data = try? handle.readToEnd(), let credentials = try? JSONDecoder().decode(S3Store.Credentials.self, from: data) else {
        fail("no bucket keys on descriptor \(fd)")
    }
    return credentials
}()

func store(_ given: String? = nil) -> any ControlStore {
    let text = given ?? value("--store") ?? environment["AGENTS_STORE"]
        ?? home.map { $0.appendingPathComponent("store", isDirectory: true).absoluteString }
    guard let text else { fail("say where the store is: AGENTS_STORE=file:///path or s3://bucket/prefix") }
    do { return try StoreAddress.open(text, environment: environment, credentials: storeCredentials) } catch { fail("\(error)") }
}

func privateKey() -> Data {
    if let fd = value("--key-fd").flatMap(Int32.init) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 64), data.count == 32 else { fail("no key on descriptor \(fd)") }
        return data
    }
    if let text = environment["AGENTS_CONTROL_KEY"] {
        guard let key = ControlCode.data(base64url: text), key.count == 32 else { fail("AGENTS_CONTROL_KEY is not a key") }
        return key
    }
    guard let file = environment["AGENTS_CONTROL_KEY_FILE"] ?? home?.appendingPathComponent("control-key").path else {
        fail("say where the control plane's key is: AGENTS_CONTROL_KEY_FILE, AGENTS_CONTROL_KEY or --key-fd")
    }
    do { return try ControlAgreement.loadOrMake(file: URL(fileURLWithPath: file)) } catch { fail("the key file: \(error)") }
}

/// This Mac's Bonjour name, as the window's browser shows it.
func localName() -> String {
    #if os(macOS)
    Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
    ProcessInfo.processInfo.hostName
    #endif
}

/// `<name>.local`, the address a Mac on the same network reaches this one at.
func localHost() -> String {
    let name = ProcessInfo.processInfo.hostName
    return name.hasSuffix(".local") ? name : name.split(separator: ".").first.map { "\($0).local" } ?? name
}

func serve() async {
    let homePort = value("--port").flatMap(Int.init) ?? 8791
    let text = environment["AGENTS_CONTROL_URL"] ?? home.map { _ in "https://\(localHost()):\(homePort)" }
    guard let text, let url = URL(string: text) else {
        fail("say the control plane's address: AGENTS_CONTROL_URL=https://…")
    }
    let port = value("--port").flatMap(Int.init) ?? url.port ?? 8791
    var tls: (context: NIOSSLContext, pin: String)?
    do {
        if let dir = value("--self-signed") ?? home?.appendingPathComponent("tls", isDirectory: true).path {
            let made = try SelfSigned.make(in: URL(fileURLWithPath: dir, isDirectory: true), name: url.host ?? "agents")
            tls = (made.0, made.pin)
        } else if let cert = environment["AGENTS_CONTROL_TLS_CERT"], let key = environment["AGENTS_CONTROL_TLS_KEY"] {
            let made = try SelfSigned.load(cert: URL(fileURLWithPath: cert), key: URL(fileURLWithPath: key))
            // A certificate given by path is taken to be publicly trusted: no pin.
            tls = (made.0, environment["AGENTS_CONTROL_PIN"] ?? "")
        }
    } catch {
        fail("TLS: \(error)")
    }
    // Behind a load balancer that terminates TLS, the pin is its certificate's, given.
    let pin = tls.flatMap { $0.pin.isEmpty ? nil : $0.pin } ?? environment["AGENTS_CONTROL_PIN"].flatMap { $0.isEmpty ? nil : $0 }
    let name = value("--name") ?? environment["AGENTS_CONTROL_NAME"] ?? (home != nil ? localName() : url.host ?? "control plane")
    do {
        let service = try ControlService(.init(store: store(), privateKey: privateKey(), url: url, pin: pin,
                                               tls: tls?.context, bind: value("--bind") ?? "0.0.0.0",
                                               port: port, name: name,
                                               machineID: environment["AGENTS_CONTROL_MACHINE_ID"] ?? MachineID.current,
                                               peerURL: environment["AGENTS_CONTROL_PEER_URL"].flatMap(URL.init(string:)),
                                               receive: arguments.contains("--receive") || environment["AGENTS_CONTROL_RECEIVE"] == "1"))
        let listening = try await service.start()
        if let pin { print("pin \(pin)") }
        #if canImport(dnssd)
        // Found by the window on this network (frame K2). Not for a walk that must stay
        // out of sight: --no-bonjour.
        let advertiser = home != nil && !arguments.contains("--no-bonjour")
            ? Advertiser(name: name, port: listening, pin: pin) : nil
        if advertiser != nil { print("advertised as \(name)") }
        defer { _ = advertiser }
        #else
        _ = listening
        #endif
        let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        signal(SIGTERM, SIG_IGN)
        stop.setEventHandler {
            Task {
                await service.stop()
                exit(0)
            }
        }
        stop.resume()
        while true { try await Task.sleep(for: .seconds(3600)) }
    } catch {
        fail("\(error)")
    }
}

/// A code, made against the store: any copy serving it will take it.
func code() async {
    let purpose: ControlCode.Purpose
    if arguments.contains("--host") {
        purpose = .host
    } else if let grant = value("--client").flatMap(Grant.init(rawValue:)) {
        purpose = .client(grant)
    } else {
        fail("say what the code is for: --client operator, --client device, or --host")
    }
    let store = store()
    let records = ControlRecords(store: store)
    do {
        try await records.load()
        guard let settings = await records.settings, let url = settings.url else {
            fail("this store has no control plane yet: start one with `agents-control serve` first")
        }
        let key = privateKey()
        guard try ControlAgreement.publicKey(privateKey: key) == settings.controlKey else {
            fail("that key is not this control plane's")
        }
        let codes = ControlCodes.forCommandLine(store: store, privateKey: key, url: url, pin: settings.pin, name: settings.name)
        let minutes = value("--minutes").flatMap(Double.init) ?? ControlCode.lifetime / 60
        let shown = try await codes.issue(purpose, lifetime: minutes * 60)
        print(shown.text)
        // The line a server runs to join with it (T070), for Agents Host to run over ssh.
        if arguments.contains("--command"), case .host = purpose {
            print("command\t" + HostInstallScript.command(url: url, pin: settings.pin, code: shown.text))
        }
    } catch {
        fail("\(error)")
    }
}

/// The start-up probe on its own (contracts/store.md rule 4): Agents Host's *Check*.
func checkStore() async {
    do {
        try await store().probe(copy: "check")
        print("works, with safe concurrent writes")
    } catch let error as StoreError {
        // In words, for Agents Host's Check to show as it is.
        switch error {
        case .unavailable(let why): fail("It can't be used: \(why).")
        case .conflict: fail("It can't be used: another writer changed the probe while it ran. Check again.")
        }
    } catch {
        fail("\(error)")
    }
}

/// Switch Store… (T058b): with no copy serving, every record into an empty store.
func copyStore() async {
    guard let from = value("--from"), let to = value("--to") else { fail("say --from URL --to URL") }
    do {
        let report = try await StoreCopy.copy(from: store(from), to: store(to))
        print("copied \(report.copied) records (left out \(report.skipped) leases and copies, which are rebuilt)")
    } catch {
        fail("\(error)")
    }
}

/// The move (058, T084): an old root's paired devices become device clients here, with
/// their own keys, and this Mac's host is the home host. The old root is only read. Then
/// the servers the old window reached by ssh, one per line, for Agents Host to enrol.
func move() async {
    guard let from = value("--from") else { fail("say --from ROOT, the old set-up's folder") }
    let locations = StoreLocations(root: URL(fileURLWithPath: (from as NSString).expandingTildeInPath, isDirectory: true))
    let records = ControlRecords(store: store())
    do {
        try await records.load()
        guard await records.settings != nil else {
            fail("this store has no control plane yet: start one with `agents-control serve` first")
        }
        try await ControlMove.prepare(records, from: locations)
        let devices = ControlRecords.legacyDevices(at: locations.devices)
        print("moved \(devices.count) devices: \(devices.map(\.name).joined(separator: ", "))")
        for server in ControlMove.servers(of: locations) { print("server\t\(server.sshName)\t\(server.label)") }
    } catch {
        fail("\(error)")
    }
}

func list(hosts: Bool) async {
    let records = ControlRecords(store: store())
    do {
        try await records.load()
        if hosts {
            for host in await records.hosts { print("\(host.id)\t\(host.name)\t\(host.platform)\t\(host.version)") }
        } else {
            for client in await records.clients { print("\(client.id)\t\(client.name)\t\(client.kind.rawValue)\t\(client.grant.rawValue)") }
        }
    } catch {
        fail("\(error)")
    }
}

/// A handover of the running control plane to a copy elsewhere (058, research R16), one
/// step at a time, with the control plane's key: Agents Host's *Move to another machine…*,
/// or by hand. `--at` is the copy the step is for.
func handover() async {
    let step = arguments.dropFirst().first ?? ""
    let key = privateKey()
    // `self` is the copy serving this store, at the address and pin its settings say:
    // Agents Host's own, whose pin it never has to work out.
    func own() async -> (String, String?) {
        let records = ControlRecords(store: store())
        guard (try? await records.load()) != nil, let settings = await records.settings, let url = settings.url else {
            fail("this store has no control plane yet")
        }
        return (url, settings.pin)
    }
    func link(_ flag: String, pin pinFlag: String) async -> Handover.Link {
        guard var text = value(flag) else { fail("say \(flag) https://… (or self) for the copy") }
        var pin = value(pinFlag)
        if text == "self" { (text, pin) = await own() }
        guard let url = URL(string: text) else { fail("\(text) is not an address") }
        do { return try await Handover.Link(url, pin: pin, privateKey: key) } catch {
            fail("couldn't reach \(text) as this control plane: \(error)")
        }
    }
    func endpoints() -> [ControlEndpoint] {
        guard let url = value("--endpoint") else { fail("say --endpoint https://… [--endpoint-pin PIN]") }
        return [ControlEndpoint(url: url, pin: value("--endpoint-pin"))]
    }
    func show(_ result: JSONValue) {
        guard let status = try? result.decode(Handover.Status.self) else { return print(result) }
        if arguments.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return print(String(decoding: (try? encoder.encode(status)) ?? Data(), as: UTF8.self))
        }
        print("phase\t\(status.phase.rawValue)")
        if let until = status.forwardingUntil { print("until\t\(until.formatted(.iso8601))") }
        print("records\t\(status.hasRecords ? "yes" : "none")")
        print("epoch\t\(status.epoch.map(String.init) ?? "-")")
        for endpoint in status.endpoints { print("endpoint\t\(endpoint.url)\t\(endpoint.pin ?? "-")") }
        for member in status.members {
            print("member\t\(member.id)\t\(member.name)\t\(member.kind)\t\(member.knownEpoch.map(String.init) ?? "-")\t\(member.online == true ? "online" : "-")")
        }
    }
    do {
        switch step {
        case "status":
            show(try await link("--at", pin: "--pin").call(Handover.Method.status))
        case "announce":
            show(try await link("--at", pin: "--pin").call(Handover.Method.announce,
                                                          ["endpoint": try JSONValue.encoding(endpoints()[0])]))
        case "forward":
            // 30 days at most, the copy's own rule; --days for fewer.
            var params: [String: JSONValue] = ["endpoints": try JSONValue.encoding(endpoints())]
            if let days = value("--days").flatMap(Double.init) {
                params["until"] = try JSONValue.encoding(Date().addingTimeInterval(days * 24 * 3600))
            }
            show(try await link("--at", pin: "--pin").call(Handover.Method.forward, .object(params)))
        case "freeze": show(try await link("--at", pin: "--pin").call(Handover.Method.freeze))
        case "unfreeze": show(try await link("--at", pin: "--pin").call(Handover.Method.unfreeze))
        case "withdraw": show(try await link("--at", pin: "--pin").call(Handover.Method.withdraw))
        case "take": show(try await link("--at", pin: "--pin").call(Handover.Method.take))
        case "copy":
            // Either end a copy (https://…, over its handover session) or a store this
            // machine opens (file://…, s3://…).
            func end(_ flag: String, pin: String) async -> any ControlStore {
                guard let text = value(flag) else { fail("say \(flag)") }
                if text == "self" || text.hasPrefix("https://") || text.hasPrefix("http://") { return PeerStore(await link(flag, pin: pin)) }
                return store(text)
            }
            let report = try await StoreCopy.copy(from: await end("--from", pin: "--from-pin"), to: await end("--to", pin: "--to-pin"))
            print("copied \(report.copied) records (left out \(report.skipped) leases and copies, which are rebuilt)")
        default:
            fail("""
            usage: agents-control handover status|freeze|unfreeze|withdraw|take --at URL [--pin PIN] [--json]
                   agents-control handover announce|forward --at URL [--pin PIN] --endpoint URL [--endpoint-pin PIN] [--days N]
            (URL may be `self`: the copy serving this store, at the address and pin its settings say)
                   agents-control handover copy --from URL|STORE [--from-pin PIN] --to URL|STORE [--to-pin PIN]
            """)
        }
    } catch {
        fail("\(error)")
    }
}

switch arguments.first {
case "serve": await serve()
case "code": await code()
case "hosts": await list(hosts: true)
case "clients": await list(hosts: false)
case "move": await move()
case "handover": await handover()
case "store" where arguments.dropFirst().first == "check": await checkStore()
case "store" where arguments.dropFirst().first == "copy": await copyStore()
case "install-script": print(HostInstallScript.text, terminator: "")
case "--version", "version": print("agents-control \(ControlPlaneKit.version)")
default:
    fail("""
    usage: agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
           agents-control code (--client operator|device | --host) [--minutes N]
           agents-control serve --home DIR [--no-bonjour]
           agents-control hosts | clients
           agents-control store check [--store URL]
           agents-control store copy --from URL --to URL
           agents-control serve --receive            (empty, for a handover to fill; or AGENTS_CONTROL_RECEIVE=1)
           agents-control handover status|announce|freeze|unfreeze|withdraw|copy|take|forward …
    """)
}
