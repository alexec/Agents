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
//   agents-control code (--client operator|device | --host) [--minutes N]
//   agents-control hosts | clients
//
// Where things are comes from the environment:
//   AGENTS_STORE                file:///path (s3:// comes with the copies work)
//   AGENTS_CONTROL_URL          the one address clients and hosts are given
//   AGENTS_CONTROL_KEY_FILE     the control plane's private key, raw, 0600 (made if missing)
//   AGENTS_CONTROL_KEY          or the key itself, base64url
//   AGENTS_CONTROL_TLS_CERT/_KEY  when this copy terminates TLS itself

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

func store() -> any ControlStore {
    guard let text = value("--store") ?? environment["AGENTS_STORE"] else {
        fail("say where the store is: AGENTS_STORE=file:///path")
    }
    guard let url = URL(string: text), let scheme = url.scheme else { fail("\(text) is not a store") }
    switch scheme {
    case "file": return FolderStore(root: URL(fileURLWithPath: url.path, isDirectory: true))
    default: fail("\(scheme): stores are not supported yet; use file:///path")
    }
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
    guard let file = environment["AGENTS_CONTROL_KEY_FILE"] else {
        fail("say where the control plane's key is: AGENTS_CONTROL_KEY_FILE, AGENTS_CONTROL_KEY or --key-fd")
    }
    do { return try ControlAgreement.loadOrMake(file: URL(fileURLWithPath: file)) } catch { fail("the key file: \(error)") }
}

func serve() async {
    guard let text = environment["AGENTS_CONTROL_URL"], let url = URL(string: text) else {
        fail("say the control plane's address: AGENTS_CONTROL_URL=https://…")
    }
    let port = value("--port").flatMap(Int.init) ?? url.port ?? 8791
    var tls: (context: NIOSSLContext, pin: String)?
    do {
        if let dir = value("--self-signed") {
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
    let pin = tls.flatMap { $0.pin.isEmpty ? nil : $0.pin }
    let name = value("--name") ?? environment["AGENTS_CONTROL_NAME"] ?? (url.host ?? "control plane")
    do {
        let service = try ControlService(.init(store: store(), privateKey: privateKey(), url: url, pin: pin,
                                               tls: tls?.context, bind: value("--bind") ?? "0.0.0.0",
                                               port: port, name: name,
                                               machineID: environment["AGENTS_CONTROL_MACHINE_ID"] ?? MachineID.current))
        try await service.start()
        if let pin { print("pin \(pin)") }
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

switch arguments.first {
case "serve": await serve()
case "code": await code()
case "hosts": await list(hosts: true)
case "clients": await list(hosts: false)
case "--version", "version": print("agents-control \(ControlPlaneKit.version)")
default:
    fail("""
    usage: agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
           agents-control code (--client operator|device | --host) [--minutes N]
           agents-control hosts | clients
    """)
}
