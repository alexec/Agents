import Foundation
import Testing
@testable import AgentsKitCore

@Suite("A shell's output on the wire")
struct ShellOutputTests {
    /// The fast reader and `Codable` must agree, because only one of them is used.
    ///
    /// `ShellOutputNotification(params:)` reads the two fields itself rather than
    /// letting `JSONValue.decode` re-encode the whole thing on the main actor. That is
    /// worth doing and it is a duplicate of what `Codable` decided, so this holds the
    /// two together: rename a property or change how `Data` is encoded and this fails
    /// rather than the terminal quietly going blank.
    @Test func theFastReaderAgreesWithCodable() throws {
        let sent = DaemonAPI.ShellOutputNotification(agentID: UUID(),
                                                     bytes: Data("hello \u{1B}[31mworld\u{1B}[0m\r\n".utf8))
        let onTheWire = try JSONValue.encoding(sent)

        let read = try #require(DaemonAPI.ShellOutputNotification(params: onTheWire))
        let decoded = try onTheWire.decode(DaemonAPI.ShellOutputNotification.self)

        #expect(read.agentID == sent.agentID)
        #expect(read.bytes == sent.bytes)
        #expect(read.agentID == decoded.agentID)
        #expect(read.bytes == decoded.bytes)
    }

    @Test func everyByteSurvivesTheTrip() throws {
        // Not text. A terminal carries escape sequences, and anything a program writes
        // to its tty, which includes bytes that are not UTF-8 at all.
        let bytes = Data((0...255).map { UInt8($0) })
        let sent = DaemonAPI.ShellOutputNotification(agentID: UUID(), bytes: bytes)
        let read = try #require(DaemonAPI.ShellOutputNotification(params: JSONValue.encoding(sent)))
        #expect(read.bytes == bytes)
    }

    @Test func somethingThatIsNotAnOutputNotificationIsRefused() {
        #expect(DaemonAPI.ShellOutputNotification(params: ["agentID": .string("not a uuid")]) == nil)
        #expect(DaemonAPI.ShellOutputNotification(params: .string("nonsense")) == nil)
    }
}
