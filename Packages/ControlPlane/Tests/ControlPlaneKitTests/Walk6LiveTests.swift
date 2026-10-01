import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// Quickstart Walk 2 steps 8–9 for US6 (058, T082), beside the App Store window on screen:
/// two copies of the control plane, each terminating TLS with the one self-signed
/// certificate, and clients at the second copy while the window is at the first.
///
///   AGENTS_WALK6_B=https://127.0.0.1:18852 AGENTS_WALK6_PIN=<pin> \
///   AGENTS_WALK6_IPAD=<device code> AGENTS_WALK6_OTHER=<operator code> AGENTS_WALK6_THIRD=<operator code> \
///   AGENTS_WALK6_HOLD=<seconds> swift test --filter Walk6
///
/// It pairs an iPad and two more operator windows, connects the iPad at the second copy
/// and lets it go (so the window says when it was seen), races two grant changes on the
/// iPad from the two copies, and holds the second window connected at the second copy.
@Suite("Walk 6: grants over two copies", .serialized, .timeLimit(.minutes(30)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK6_B"] != nil))
struct Walk6LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var b: URL { URL(string: environment["AGENTS_WALK6_B"]!)! }
    var pin: String? { environment["AGENTS_WALK6_PIN"] }

    func note(_ line: String) { print("WALK6 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

    struct Paired {
        let id: UUID
        let credentials: ControlAuth.Credentials
    }

    /// Pairs with a code (at whichever copy the code names), then dials as itself.
    func pair(_ variable: String, name: String, kind: ClientRecord.Kind) async throws -> Paired {
        let text = try #require(environment[variable])
        let code = try #require(ControlCode(text: text))
        let key = ControlAgreement.generate()
        let membership = try await ControlCodeUse.pairClient(code, privateKey: key.privateKey, id: UUID(), name: name,
                                                             kind: kind, dial: ControlJoin.nio)
        let id = try #require(membership.client)
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: membership.controlKey, client: id)
        return Paired(id: id, credentials: .init(identity: .client(id), key: shared, kind: kind == .mac ? "mac" : "ipad",
                                                 controlKey: membership.controlKey))
    }

    /// A connection at the second copy, dialled at its own address.
    func atB(_ paired: Paired) -> ControlLink {
        let url = b, pin = pin, credentials = paired.credentials
        return ControlLink { try await ControlJoin.dial(url, pin: pin, as: credentials) }
    }

    @Test func walk6() async throws {
        let iPad = try await pair("AGENTS_WALK6_IPAD", name: "walk6 iPad", kind: .iPad)
        let other = try await pair("AGENTS_WALK6_OTHER", name: "walk6 other window", kind: .mac)
        let third = try await pair("AGENTS_WALK6_THIRD", name: "walk6 third window", kind: .mac)
        note("paired iPad \(iPad.id), windows \(other.id) and \(third.id)")

        // The iPad at the second copy for a moment, then gone: "seen".
        let iPadLink = atB(iPad)
        let iPadControl = DaemonClient(link: iPadLink.controlLink)
        try await iPadControl.connect(startIfNeeded: false)
        _ = try await iPadControl.call(DaemonAPI.Method.controlStatus)
        note("iPad connected at the second copy")
        try await Task.sleep(for: .seconds(3))
        iPadLink.disconnect()
        note("iPad gone")

        // The other window stays at the second copy; the third races it from the first.
        let otherLink = atB(other)
        let atSecond = DaemonClient(link: otherLink.controlLink)
        try await atSecond.connect(startIfNeeded: false)
        let firstAddress = try #require(ControlCode(text: environment["AGENTS_WALK6_THIRD"]!)?.url)
        let firstURL = try #require(URL(string: firstAddress))
        let thirdCredentials = third.credentials, pin = pin
        let thirdLink = ControlLink { try await ControlJoin.dial(firstURL, pin: pin, as: thirdCredentials) }
        let atFirst = DaemonClient(link: thirdLink.controlLink)
        try await atFirst.connect(startIfNeeded: false)

        for round in 1...3 {
            async let one: String = setGrant(atFirst, of: iPad.id, to: round % 2 == 1 ? .operator : .device)
            async let two: String = setGrant(atSecond, of: iPad.id, to: round % 2 == 1 ? .device : .operator)
            let (first, second) = await (one, two)
            let clients = try await atFirst.call(DaemonAPI.Method.clientsList, returning: [ClientRecord].self)
            note("race \(round): first copy \(first), second copy \(second); the iPad is now \(clients.first { $0.id == iPad.id }?.grant.rawValue ?? "?")")
        }
        thirdLink.disconnect()

        let seconds = environment["AGENTS_WALK6_HOLD"].flatMap(Double.init) ?? 0
        note("holding the other window at the second copy for \(Int(seconds)) s")
        try await Task.sleep(for: .seconds(seconds))
        otherLink.disconnect()
    }

    func setGrant(_ client: DaemonClient, of id: UUID, to grant: Grant) async -> String {
        do {
            _ = try await client.call(DaemonAPI.Method.clientsSetGrant, DaemonAPI.ClientGrantRequest(client: id, grant: grant))
            return "set \(grant.rawValue)"
        } catch let error as JSONRPCError {
            return "refused \(error.code) (\(error.message))"
        } catch {
            return "failed \(error)"
        }
    }
}
