import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// Members follow the control plane to a new place without pairing again (058, research
/// R16): the list arrives in `ok`, is saved, and the next dial goes there.
extension ControlServiceTests {
    @Test func aHostToldANewPlaceDialsThereNextAndSaysSo() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let key = ControlAgreement.generate()
        let announced = try await use(try await running.service.codes.issue(.host).text, at: running.url,
                                      method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)

        // The same copy at a second name stands in for the new machine.
        let here = ControlEndpoint(url: running.url.absoluteString)
        let there = ControlEndpoint(url: "http://localhost:\(running.port)")
        let membership = ControlMembership(host: host, controlKey: control.publicKey, addresses: [], name: "test",
                                           url: here.url)
        let dialled = Dialled()
        let kept = Saved()
        let book = EndpointBook(membership) { kept.set($0) }
        let hostKey = try ControlAuth.hostKey(privateKey: key.privateKey, peer: control.publicKey, host: host)
        let credentials = ControlAuth.Credentials(identity: .host(host), key: hostKey, kind: "host", controlKey: control.publicKey)
        let dial: ControlCodeUse.Dial = { url, pin in
            dialled.add(url)
            return try await ControlDial.connect(url, pin: pin)
        }

        // Before any announcement: nothing given, nothing kept.
        try await ControlCodeUse.dialEach(book, as: credentials, dial: dial).close()
        #expect(kept.get == nil)

        // Announced: the control plane answers only at the new place from now on.
        try await running.service.methods.setEndpoints([there])
        try await ControlCodeUse.dialEach(book, as: credentials, dial: dial).close()
        #expect(kept.get?.endpointsToDial == [there])
        #expect(kept.get?.epoch == 1)

        // The next dial goes there, proves that origin, and reports the epoch it holds.
        try await ControlCodeUse.dialEach(book, as: credentials, dial: dial).close()
        #expect(dialled.all.map(\.absoluteString) == [here.url, here.url, there.url])
        await eventually { await running.service.methods.host(host)?.knownEpoch == 1 }
    }

    @Test func aMemberIsCountedAsToldOnTheConnectionThatTellsIt() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        try await running.service.methods.setEndpoints([ControlEndpoint(url: running.url.absoluteString)])
        // A build that keeps a list: told, and counted at once.
        let (keeping, _, credentials) = try await pairedClient(at: running.url,
                                                               code: try await running.service.codes.issue(.client(.device)).text)
        let book = EndpointBook(ControlMembership(client: keeping, controlKey: control.publicKey, addresses: [],
                                                  name: "test", url: running.url.absoluteString))
        try await ControlCodeUse.dialEach(book, as: credentials, dial: ControlJoin.nio).close()
        await eventually { await running.service.methods.client(keeping)?.knownEpoch == 1 }
        // A build from before (no epoch in its auth): never counted, so listed as can't follow.
        let (older, _, oldCredentials) = try await pairedClient(at: running.url,
                                                                code: try await running.service.codes.issue(.client(.device)).text)
        try await join(running.url, oldCredentials).close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await running.service.methods.client(older)?.knownEpoch == nil)
    }

    @Test func anOldPlaceThatNoLongerAnswersIsPassedOver() async throws {
        let running = try await start()
        defer { Task { await running.service.stop() } }
        let (id, _, credentials) = try await pairedClient(at: running.url,
                                                          code: try await running.service.codes.issue(.client(.device)).text)
        let gone = ControlEndpoint(url: "http://127.0.0.1:\(try await freePort())")
        let membership = ControlMembership(client: id, controlKey: control.publicKey, addresses: [], name: "test",
                                           endpoints: [gone, ControlEndpoint(url: running.url.absoluteString)], epoch: 1)
        let reader = try await ControlCodeUse.dialEach(EndpointBook(membership), as: credentials, dial: ControlJoin.nio)
        reader.close()
    }
}

private final class Dialled: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}

private final class Saved: @unchecked Sendable {
    private let lock = NSLock()
    private var membership: ControlMembership?
    func set(_ value: ControlMembership) { lock.withLock { membership = value } }
    var get: ControlMembership? { lock.withLock { membership } }
}
