import Foundation
import Testing
@testable import AgentsKitCore

/// A member's list of places its control plane answers, and how a newer one replaces it
/// (058, research R16).
@Suite("Control plane endpoints")
struct ControlEndpointTests {
    let pin = ControlCode.base64url(Data(repeating: 7, count: 32))
    let otherPin = ControlCode.base64url(Data(repeating: 9, count: 32))

    func membership() -> ControlMembership {
        ControlMembership(host: HostID(rawValue: "abcd1234"), controlKey: Data([4] + Array(repeating: 1, count: 64)),
                          addresses: [], name: "home", url: "https://mac.local:8791", pin: pin)
    }

    @Test func aMembershipFromBeforeTheListDialsItsOneAddress() throws {
        // Written by a build with no endpoints: the version 2 fields only.
        let old = #"{"host":"abcd1234","controlKey":"BAEB","addresses":[],"name":"home","url":"https://mac.local:8791","pin":"\#(pin)"}"#
        let read = try JSONDecoder().decode(ControlMembership.self, from: Data(old.utf8))
        #expect(read.endpoints == nil)
        #expect(read.endpointsToDial == [ControlEndpoint(url: "https://mac.local:8791", pin: pin)])
    }

    @Test func aNewerListReplacesTheOldAndLeadsWithItsFirst() throws {
        let cloud = ControlEndpoint(url: "https://agents.example.com")
        let changed = try #require(membership().adopting([cloud], epoch: 1))
        #expect(changed.endpointsToDial == [cloud])
        #expect(changed.url == "https://agents.example.com")
        #expect(changed.pin == nil)
        #expect(changed.epoch == 1)
        // The same epoch again, or an older one, changes nothing.
        #expect(changed.adopting([ControlEndpoint(url: "https://elsewhere.example.com")], epoch: 1) == nil)
        #expect(changed.adopting([ControlEndpoint(url: "https://elsewhere.example.com")], epoch: 0) == nil)
    }

    @Test func aListAMemberCouldNotDialIsLeftAlone() {
        #expect(membership().adopting([ControlEndpoint(url: "http://agents.example.com")], epoch: 1) == nil)
        #expect(membership().adopting([ControlEndpoint(url: "https://agents.example.com", pin: "short")], epoch: 1) == nil)
        #expect(membership().adopting([], epoch: 1) == nil)
        #expect(membership().adopting(nil, epoch: 1) == nil)
        // Loopback http is a walk's or a test's, as for a code.
        #expect(membership().adopting([ControlEndpoint(url: "http://127.0.0.1:9000")], epoch: 1) != nil)
    }

    @Test func theBookTriesWhatAnsweredLastAndKeepsANewerList() throws {
        let a = ControlEndpoint(url: "https://mac.local:8791", pin: pin)
        let b = ControlEndpoint(url: "https://agents.example.com")
        let kept = Kept()
        let book = EndpointBook(membership()) { kept.set($0) }
        #expect(book.order == [a])

        book.answered(at: a, ok: ControlAuth.OK(mac: "", endpoints: [a, b], epoch: 2))
        #expect(book.order == [a, b])
        #expect(book.epoch == 2)
        #expect(kept.get?.endpoints == [a, b])

        book.answered(at: b, ok: ControlAuth.OK(mac: ""))
        #expect(book.order == [b, a])

        // The move done: the old place is gone from the list, and from the order.
        book.answered(at: b, ok: ControlAuth.OK(mac: "", endpoints: [b], epoch: 3))
        #expect(book.order == [b])
        #expect(kept.get?.epoch == 3)
    }

    @Test func settingsWithNoListAnswerAtTheirOneAddress() {
        var settings = ControlSettings(name: "home", machineID: "m", url: "https://mac.local:8791", pin: pin)
        #expect(settings.currentEndpoints == [ControlEndpoint(url: "https://mac.local:8791", pin: pin)])
        settings.endpoints = [ControlEndpoint(url: "https://mac.local:8791", pin: otherPin)]
        #expect(settings.currentEndpoints.first?.pin == otherPin)
    }

    @Test func okAndAuthFromEitherSideOfTheChangeAreRead() throws {
        // An ok from a control plane with no list, as before.
        let bare = try #require(ControlAuth.Message(line: #"{"ok":{"mac":"AAAA"}}"#))
        guard case .ok(let ok) = bare else { Issue.record("not an ok"); return }
        #expect(ok.endpoints == nil && ok.epoch == nil)
        // An ok and an auth with them, there and back.
        let full = ControlAuth.Message.ok(ControlAuth.OK(mac: "AAAA", endpoints: [ControlEndpoint(url: "https://a.example.com")], epoch: 4))
        #expect(ControlAuth.Message(line: full.line) == full)
        let auth = ControlAuth.Message.auth(ControlAuth.Auth(id: "h:abcd1234", nonce: "n", mac: "m", kind: "host", epoch: 4))
        #expect(ControlAuth.Message(line: auth.line) == auth)
    }

    @Test func aPeerMayProveAnyOfThePlacesItDialled() async throws {
        let key = Data(repeating: 3, count: 32)
        let serverNonce = ControlAuth.nonce()
        let hello = ControlAuth.Hello(name: "x", control: "", nonce: ControlCode.base64url(serverNonce), copy: "c")
        let (auth, expect) = try ControlAuth.answer(hello, identity: .host(HostID(rawValue: "abcd1234")), key: key,
                                                    origin: "https://agents.example.com:443", kind: "host",
                                                    expecting: nil, epoch: 2)
        #expect(auth.epoch == 2)
        let (_, mac) = try await ControlAuth.verify(auth, serverNonce: serverNonce,
                                                    origins: ["https://mac.local:8791", "https://agents.example.com:443"]) { _ in key }
        #expect(mac == expect)
        await #expect(throws: ControlAuth.Refusal.self) {
            _ = try await ControlAuth.verify(auth, serverNonce: serverNonce, origins: ["https://mac.local:8791"]) { _ in key }
        }
    }
}

private final class Kept: @unchecked Sendable {
    private let lock = NSLock()
    private var membership: ControlMembership?
    func set(_ value: ControlMembership) { lock.withLock { membership = value } }
    var get: ControlMembership? { lock.withLock { membership } }
}
