import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// A running control plane handed over to a copy on another "machine" (058, research R16,
/// T123–T124): its members follow without pairing again.
extension ControlServiceTests {
    /// A copy that starts empty, for a handover to fill.
    func receiving() async throws -> Running {
        let port = try await freePort()
        let url = URL(string: "http://localhost:\(port)")!
        let service = try ControlService(.init(store: MemoryStore(), privateKey: control.privateKey, url: url,
                                               bind: "127.0.0.1", port: port, name: "test", machineID: "cloud",
                                               receive: true))
        try await service.start()
        return Running(service: service, url: url, port: port)
    }

    @Test func aHandoverMovesEveryMemberWithoutPairingAgain() async throws {
        let old = try await start()
        defer { Task { await old.service.stop() } }
        let new = try await receiving()
        defer { Task { await new.service.stop() } }

        // A host that dials the way agentsd does: by its membership's list.
        let key = ControlAgreement.generate()
        let announced = try await use(try await old.service.codes.issue(.host).text, at: old.url,
                                      method: DaemonAPI.Method.hostsAnnounce, params: try JSONValue.encoding(
            DaemonAPI.HostAnnounce(publicKey: key.publicKey, name: "devbox", platform: "Linux arm64", version: "1",
                                   machineID: "linux-1")))
        let host = try #require(try announced.decode(DaemonAPI.Admitted.self).host)
        let membership = ControlMembership(host: host, controlKey: control.publicKey, addresses: [], name: "test",
                                           url: old.url.absoluteString)
        let saved = Kept()
        let book = EndpointBook(membership) { saved.set($0) }
        let server = DaemonServer(url: URL(fileURLWithPath: "/tmp/unused-\(UUID()).sock")) { _, method, _ in
            .success(["host": .string(host.rawValue), "method": .string(method)])
        }
        let uplink = ControlUplink(server: server, hello: DaemonAPI.HostHello(host: host, version: "1", platform: "Linux arm64",
                                                                             machineID: "linux-1"),
                                   dial: try ControlJoin.hostDial(book, privateKey: key.privateKey))
        uplink.start()
        defer { uplink.stop() }
        await eventually { await old.service.router.state(of: host)?.isOnline == true }

        // A device, paired at the old place.
        let (client, _, credentials) = try await pairedClient(at: old.url,
                                                              code: try await old.service.codes.issue(.client(.device)).text)
        let clientBook = EndpointBook(ControlMembership(client: client, controlKey: control.publicKey, addresses: [],
                                                        name: "test", url: old.url.absoluteString))

        // The receiving copy answers nobody but the handover.
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await ControlCodeUse.dialEach(EndpointBook(ControlMembership(
                client: client, controlKey: control.publicKey, addresses: [], name: "test", url: new.url.absoluteString)),
                as: credentials, dial: ControlJoin.nio)
        }

        let fromOld = try await Handover.Link(old.url, pin: nil, privateKey: control.privateKey)
        let intoNew = try await Handover.Link(new.url, pin: nil, privateKey: control.privateKey)
        #expect(try await intoNew.status().phase == .receiving)
        #expect(try await intoNew.status().hasRecords == false)

        // 1. Announce: members reconnect and hear of the new place.
        let place = ControlEndpoint(url: new.url.absoluteString)
        _ = try await fromOld.call(Handover.Method.announce, ["endpoint": try JSONValue.encoding(place)])
        await eventually { saved.get?.endpointsToDial == [ControlEndpoint(url: old.url.absoluteString), place] }
        try await ControlCodeUse.dialEach(clientBook, as: credentials, dial: ControlJoin.nio).close()
        #expect(clientBook.current.endpointsToDial.count == 2)

        // 2. Freeze, and nothing that writes is answered.
        _ = try await fromOld.call(Handover.Method.freeze)
        #expect(await old.service.methods.frozen)

        // 3. Copy, between two machines.
        let report = try await StoreCopy.copy(from: PeerStore(fromOld), to: PeerStore(intoNew))
        #expect(report.copied > 0)

        // 4. Take over, and forward.
        let taken = try await intoNew.call(Handover.Method.take).decode(Handover.Status.self)
        #expect(taken.phase == .serving)
        #expect(taken.endpoints == [place])
        _ = try await fromOld.call(Handover.Method.forward, ["endpoints": try JSONValue.encoding([place])])

        // The host is at the new copy, as itself, and has only the new place now.
        await eventually(within: 15) { await new.service.router.state(of: host)?.isOnline == true }
        #expect(saved.get?.endpointsToDial == [place])
        #expect(await new.service.methods.host(host) != nil)

        // The device too: through the forwarding copy, then to the new one, same id and grant.
        do { try await ControlCodeUse.dialEach(clientBook, as: credentials, dial: ControlJoin.nio).close() } catch {}
        let reader = try await ControlCodeUse.dialEach(clientBook, as: credentials, dial: ControlJoin.nio)
        reader.close()
        #expect(clientBook.current.endpointsToDial == [place])
        #expect(await new.service.methods.client(client)?.grant == .device)

        await fromOld.close()
        await intoNew.close()
    }

    @Test func aFrozenCopyRefusesWhatWouldChangeRecordsAndUnfreezes() async throws {
        let old = try await start()
        defer { Task { await old.service.stop() } }
        let (_, link) = try await client(at: old.url, code: try await old.service.codes.issue(.client(.operator)).text)
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)

        let handover = try await Handover.Link(old.url, pin: nil, privateKey: self.control.privateKey)
        _ = try await handover.call(Handover.Method.freeze)
        await #expect(throws: JSONRPCError.self) {
            _ = try await control.call(DaemonAPI.Method.clientsStartPairing, ["grant": "device"])
        }
        _ = try await control.call(DaemonAPI.Method.hostsList)
        _ = try await handover.call(Handover.Method.unfreeze)
        _ = try await control.call(DaemonAPI.Method.clientsStartPairing, ["grant": "device"])
        await handover.close()
    }

    @Test func aReceivingCopyStartedAgainServesWhatItTookAndRefusesHalfAHandover() async throws {
        let store = MemoryStore()
        let port = try await freePort()
        let url = URL(string: "http://localhost:\(port)")!
        func copy() throws -> ControlService {
            try ControlService(.init(store: store, privateKey: control.privateKey, url: url, bind: "127.0.0.1", port: port,
                                     name: "test", receive: true))
        }
        // Records from elsewhere that were never taken: half a handover.
        let elsewhere = ControlSettings(name: "test", machineID: "m", url: "http://127.0.0.1:1", controlKey: control.publicKey)
        _ = try await store.put(ControlRecords.settingsKey, try ControlRecords.encoder.encode(elsewhere), when: .absent)
        await #expect(throws: ControlService.Failure.self) { try await copy().start() }

        // Taken: its own place first. Started again with --receive, it simply serves.
        var taken = elsewhere
        taken.endpoints = [ControlEndpoint(url: url.absoluteString)]
        taken.epoch = 2
        let held = try #require(try await store.get(ControlRecords.settingsKey))
        _ = try await store.put(ControlRecords.settingsKey, try ControlRecords.encoder.encode(taken), when: .matching(held.etag))
        let again = try copy()
        try await again.start()
        defer { Task { await again.stop() } }
        #expect(again.phase.now == .serving)
    }

    @Test func forwardingEndsOnItsDateAndNeverRunsPastThirtyDays() async throws {
        let old = try await start()
        defer { Task { await old.service.stop() } }
        let (client, _, credentials) = try await pairedClient(at: old.url,
                                                              code: try await old.service.codes.issue(.client(.device)).text)
        let book = EndpointBook(ControlMembership(client: client, controlKey: control.publicKey, addresses: [],
                                                  name: "test", url: old.url.absoluteString))
        let handover = try await Handover.Link(old.url, pin: nil, privateKey: control.privateKey)
        _ = try await handover.call(Handover.Method.freeze)
        let elsewhere = try JSONValue.encoding([ControlEndpoint(url: "https://agents.example.com")])

        // Asked for longer than 30 days: 30 days.
        let long = try await handover.call(Handover.Method.forward, [
            "endpoints": elsewhere, "until": try JSONValue.encoding(Date().addingTimeInterval(90 * 24 * 3600))])
            .decode(Handover.Status.self)
        let until = try #require(long.forwardingUntil)
        #expect(until.timeIntervalSinceNow <= Handover.longestForwarding + 5)
        #expect(until.timeIntervalSinceNow > Handover.longestForwarding - 60)

        // Past its date, a member is turned away rather than told.
        old.service.forwardingUntil.set(Date().addingTimeInterval(-1))
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await ControlCodeUse.dialEach(book, as: credentials, dial: ControlJoin.nio)
        }
        #expect(book.current.endpoints == nil)
        await handover.close()
    }

    @Test func onlyTheControlPlanesKeyDrivesAHandover() async throws {
        let old = try await start()
        defer { Task { await old.service.stop() } }
        await #expect(throws: (any Error).self) {
            _ = try await Handover.Link(old.url, pin: nil, privateKey: ControlAgreement.generate().privateKey)
        }
    }
}

private final class Kept: @unchecked Sendable {
    private let lock = NSLock()
    private var membership: ControlMembership?
    func set(_ value: ControlMembership) { lock.withLock { membership = value } }
    var get: ControlMembership? { lock.withLock { membership } }
}
