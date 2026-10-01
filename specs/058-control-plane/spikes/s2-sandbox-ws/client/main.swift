// Spike S2 client: a sandboxed macOS app (run Contents/MacOS/S2Client directly).
// Usage: S2Client <pin-base64url> <wrong-pin-base64url> <port> <local-host-name>
// Checks, in order: sandbox applied, loopback pinned dial + a line each way, wrong pin rejected,
// .local pinned dial + a line each way, Bonjour browse of _agents-control._tcp with NWBrowser.
// Each network step has a 20 s timeout. Logs to stdout and to <container>/s2-client.log.
// Exits on its own (hard cap 60 s).
import Foundation
import Network
import Security
import CryptoKit

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("s2-client.log")
FileManager.default.createFile(atPath: logURL.path, contents: nil)
let logHandle = try? FileHandle(forWritingTo: logURL)
func log(_ s: String) {
    let line = "[\(String(format: "%.2f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)))] \(s)"
    print(line); fflush(stdout)
    logHandle?.write((line + "\n").data(using: .utf8)!)
}

// Hard cap: never outlive 60 s.
DispatchQueue.global().asyncAfter(deadline: .now() + 58) { log("RESULT hard-cap 58s reached, exiting"); exit(3) }

let args = CommandLine.arguments
guard args.count == 5, let port = Int(args[3]) else { log("usage: S2Client pin wrongPin port localName"); exit(2) }
let goodPin = args[1], wrongPin = args[2], localName = args[4]

// --- SPKI pin from a SecTrust leaf ---------------------------------------------------------
// SecKeyCopyExternalRepresentation gives the raw key (EC: 04||X||Y); SPKI = fixed DER header + raw.
let p256SPKIHeader: [UInt8] = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                               0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
func spkiPin(_ trust: SecTrust) -> String? {
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
          let key = SecCertificateCopyKey(leaf),
          let raw = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
    let attrs = SecKeyCopyAttributes(key) as? [CFString: Any]
    guard (attrs?[kSecAttrKeyType] as? String) == (kSecAttrKeyTypeECSECPrimeRandom as String),
          (attrs?[kSecAttrKeySizeInBits] as? Int) == 256 else { return nil } // spike: P-256 only
    let spki = Data(p256SPKIHeader) + raw
    return Data(SHA256.hash(data: spki)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

final class PinDelegate: NSObject, URLSessionWebSocketDelegate {
    let expected: String
    var sawPin: String?
    init(expected: String) { self.expected = expected }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let pin = spkiPin(trust)
        sawPin = pin
        if pin == expected {
            log("  delegate: server pin \(pin ?? "nil") matches -> useCredential")
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            log("  delegate: server pin \(pin ?? "nil") != expected \(expected) -> cancel")
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
        log("  delegate: websocket open")
    }
}

/// Dial, send one line, wait for one line back. Returns (ok, detail).
func dial(_ label: String, host: String, pin: String) async -> (Bool, String) {
    let url = URL(string: "wss://\(host):\(port)/v1/connect")!
    log("\(label): dialing \(url) expecting pin \(pin)")
    let delegate = PinDelegate(expected: pin)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    let task = session.webSocketTask(with: url)
    task.resume()
    defer { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    let outcome: (Bool, String) = await withTaskGroup(of: (Bool, String).self) { group in
        group.addTask {
            do {
                let line = "{\"client\":\"hello from sandbox via \(host)\"}"
                try await task.send(.string(line))
                log("\(label): sent line \(line)")
                let msg = try await task.receive()
                switch msg {
                case .string(let s): return (true, "received line \(s)")
                case .data(let d): return (true, "received data \(d.count) bytes")
                @unknown default: return (false, "unknown message")
                }
            } catch {
                let ns = error as NSError
                return (false, "error \(ns.domain) \(ns.code): \(ns.localizedDescription) userInfo=\(ns.userInfo.filter { $0.key != "NSErrorPeerCertificateChainKey" && $0.key != "NSURLErrorFailingURLPeerTrustErrorKey" })")
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            return (false, "TIMEOUT after 20 s")
        }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
    log("\(label): \(outcome.0 ? "OK" : "FAILED") \(outcome.1) (server pin seen: \(delegate.sawPin ?? "none"))")
    return outcome
}

func browse() async -> (Bool, String) {
    log("bonjour: NWBrowser for _agents-control._tcp in local.")
    return await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String), Never>) in
        let q = DispatchQueue(label: "browse")
        let browser = NWBrowser(for: .bonjour(type: "_agents-control._tcp", domain: "local."), using: .tcp)
        var done = false
        func finish(_ r: (Bool, String)) {
            q.async { if done { return }; done = true; browser.cancel(); cont.resume(returning: r) }
        }
        browser.stateUpdateHandler = { st in
            log("bonjour: state \(st)")
            if case .failed(let e) = st { finish((false, "failed: \(e)")) }
            if case .waiting(let e) = st { log("bonjour: waiting (policy?) \(e)") }
        }
        browser.browseResultsChangedHandler = { results, _ in
            let names = results.map { "\($0.endpoint)" }
            log("bonjour: results \(names)")
            if !results.isEmpty { finish((true, "found \(names.joined(separator: ", "))")) }
        }
        browser.start(queue: q)
        q.asyncAfter(deadline: .now() + 20) { if !done { finish((false, "TIMEOUT after 20 s, no results")) } }
    }
}

Task {
    var summary: [String] = []
    // 0. Sandbox
    let home = NSHomeDirectory()
    log("sandbox: NSHomeDirectory = \(home)")
    log("sandbox: APP_SANDBOX_CONTAINER_ID = \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")
    let realDesktop = "/Users/\(NSUserName())/Desktop"
    do {
        let items = try FileManager.default.contentsOfDirectory(atPath: realDesktop)
        log("sandbox: reading \(realDesktop) SUCCEEDED (\(items.count) items) -> not sandboxed?")
        summary.append("sandbox: FAIL (Desktop readable)")
    } catch {
        log("sandbox: reading \(realDesktop) failed as expected: \(error.localizedDescription)")
        summary.append("sandbox: PASS (home=\(home), Desktop read denied)")
    }
    // 1. Loopback, right pin
    let a = await dial("loopback", host: "127.0.0.1", pin: goodPin)
    summary.append("loopback pinned dial + line each way: \(a.0 ? "PASS" : "FAIL") \(a.1)")
    // 2. Loopback, wrong pin
    let b = await dial("wrong-pin", host: "127.0.0.1", pin: wrongPin)
    summary.append("wrong pin rejected: \(b.0 ? "FAIL (connected!)" : "PASS") \(b.1)")
    // 3. .local, right pin
    let c = await dial("dotlocal", host: localName, pin: goodPin)
    summary.append(".local pinned dial + line each way: \(c.0 ? "PASS" : "FAIL") \(c.1)")
    // 4. Bonjour
    let d = await browse()
    summary.append("bonjour browse: \(d.0 ? "PASS" : "FAIL") \(d.1)")
    log("==== SUMMARY ====")
    for s in summary { log("RESULT " + s) }
    exit(0)
}
dispatchMain()
