import Foundation
import Testing
@testable import AgentsKitCore

/// What leaves the Mac for a device is ciphertext (021 FR-022, US5 scenario 4).
@Suite("Envelope")
struct EnvelopeTests {
    private let headline = Headline(h1: "brushwise", h2: "Rehang the gallery", h3: "Wants to write hello.txt")

    /// Asserted against a constructed envelope, not a running system: the words are not
    /// in the bytes, in any encoding.
    @Test func theWordsAreNotInTheBytes() throws {
        let device = DeviceKey.ephemeral()
        let envelope = try Envelope.seal(headline, to: device.publicKey)
        let bytes = envelope.encapsulated + envelope.ciphertext
        for word in ["brushwise", "Rehang", "hello.txt", "Wants to"] {
            #expect(!bytes.contains(Data(word.utf8)), "\(word) is legible")
            #expect(!bytes.contains(Data(word.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })))
        }
        // And as the whole thing would be carried.
        let carried = try JSONEncoder().encode(envelope)
        #expect(!String(decoding: carried, as: UTF8.self).contains("brushwise"))
    }

    @Test func onlyTheDeviceItWasSealedToCanOpenIt() throws {
        let device = DeviceKey.ephemeral(), other = DeviceKey.ephemeral()
        let envelope = try Envelope.seal(headline, to: device.publicKey)
        #expect(try Envelope.open(envelope, with: device) == headline)
        #expect(throws: (any Error).self) { try Envelope.open(envelope, with: other) }
    }

    /// Truncated before it is sealed: what comes out fits the budget.
    @Test func aLongHeadlineIsTruncatedBeforeSealing() throws {
        let device = DeviceKey.ephemeral()
        let long = Headline(h1: String(repeating: "p", count: 80), h2: String(repeating: "a", count: 80),
                            h3: String(repeating: "w", count: 80))
        let opened = try Envelope.open(try Envelope.seal(long, to: device.publicKey), with: device)
        #expect(opened == long.truncating())
        #expect(opened.h1.count <= Headline.budget && opened.h3.count <= Headline.budget)
    }

    @Test func aRecordKeepsWhatItDoesNotUnderstand() throws {
        let json = """
        {"id":"\(UUID().uuidString)","publicKey":"","name":"Phone","kind":"iPhone",
         "announcedAt":"2026-09-20T10:00:00Z","wants":["permissions"]}
        """
        let device = try JSONDecoder.iso.decode(Device.self, from: Data(json.utf8))
        #expect(device.unknownFields["wants"] != nil)
        let back = try JSONEncoder.iso.encode(device)
        #expect(String(decoding: back, as: UTF8.self).contains("wants"))
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
