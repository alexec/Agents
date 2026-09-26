import Foundation
import Testing
@testable import AgentsKitCore

/// A relayed frame opens only for its recipient, only as from its sender, and only as
/// the session, direction and number it was sealed under (046, contracts/relay.md § Sealing).
@Suite("Sealing relayed frames")
struct FrameSealingTests {
    let mac = DeviceKey.ephemeral()
    let phone = DeviceKey.ephemeral()
    let session = UUID()

    private func frame(_ lines: [String], seq: Int64 = 0, direction: FrameDirection = .toMac, end: Bool = false) -> Frame {
        Frame(session: session, direction: direction, seq: seq, lines: lines, end: end)
    }

    @Test func aFrameOpensForItsRecipientAsFromItsSender() throws {
        let sent = frame([#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, "second"], seq: 7, end: true)
        let sealed = try sent.seal(to: mac.publicKey, from: phone)
        let opened = try Frame.open(sealed, with: mac, from: phone.publicKey,
                                    session: session, direction: .toMac, seq: 7)
        #expect(opened == sent)
    }

    @Test func nobodyElseCanOpenIt() throws {
        let sealed = try frame(["secret"]).seal(to: mac.publicKey, from: phone)
        let stranger = DeviceKey.ephemeral()
        #expect(throws: (any Error).self) {
            try Frame.open(sealed, with: stranger, from: phone.publicKey, session: session, direction: .toMac, seq: 0)
        }
    }

    @Test func itDoesNotOpenAsFromAnyoneElse() throws {
        let sealed = try frame(["secret"]).seal(to: mac.publicKey, from: phone)
        let otherPhone = DeviceKey.ephemeral()
        #expect(throws: (any Error).self) {
            try Frame.open(sealed, with: mac, from: otherPhone.publicKey, session: session, direction: .toMac, seq: 0)
        }
    }

    @Test func renumberedMovedOrTurnedRoundItDoesNotOpen() throws {
        let sealed = try frame(["secret"], seq: 3).seal(to: mac.publicKey, from: phone)
        #expect(throws: (any Error).self) {
            try Frame.open(sealed, with: mac, from: phone.publicKey, session: session, direction: .toMac, seq: 4)
        }
        #expect(throws: (any Error).self) {
            try Frame.open(sealed, with: mac, from: phone.publicKey, session: UUID(), direction: .toMac, seq: 3)
        }
        #expect(throws: (any Error).self) {
            try Frame.open(sealed, with: mac, from: phone.publicKey, session: session, direction: .toDevice, seq: 3)
        }
    }

    @Test func nothingInTheSealedBytesIsLegible() throws {
        let words = ["Low temperature in Celsius", "git commit -m", "/Users/alex/Projects/weather"]
        let sealed = try frame(words.map { #"{"text":"\#($0)"}"# }).seal(to: mac.publicKey, from: phone)
        for word in words {
            #expect(sealed.range(of: Data(word.utf8)) == nil)
        }
    }

    @Test func aBigListShrinksBeforeItIsSealed() throws {
        let entry = #"{"id":"6A1F2C3D-0000-0000-0000-000000000000","title":"An agent","state":"working","runtimeID":"claude"}"#
        let lines = [String](repeating: entry, count: 10_000)
        let plain = lines.joined(separator: "\n").utf8.count
        let sealed = try frame(lines).seal(to: mac.publicKey, from: phone)
        #expect(sealed.count < plain / 10)
    }

    @Test func aFrameWithNoLinesIsStillAFrame() throws {
        let sealed = try frame([]).seal(to: mac.publicKey, from: phone)
        let opened = try Frame.open(sealed, with: mac, from: phone.publicKey, session: session, direction: .toMac, seq: 0)
        #expect(opened.lines.isEmpty)
        #expect(!opened.end)
    }
}
