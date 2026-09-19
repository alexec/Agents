import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("The handshake")
struct HandshakeTests {
    @Test func aVersionWeDoNotSpeakIsReportedRatherThanCarriedOn() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(script: .init(protocolVersion: 2), transport: theirs)
        let session = ACPSession(transport: mine)
        do {
            _ = try await session.initialize()
            Issue.record("expected the version to be refused")
        } catch ACPSessionError.unsupportedProtocolVersion(let version) {
            #expect(version == 2)
        }
        await agent.stop()
    }

    @Test func theVersionWeDoSpeakIsFine() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(transport: theirs)
        let session = ACPSession(transport: mine)
        let result = try await session.initialize()
        #expect(result.speaksOurVersion)
        #expect(result.protocolVersion == ACP.protocolVersion)
        await agent.stop()
    }

    @Test func whatWeAdvertiseIsWhatWeSend() {
        #expect(ACP.ClientCapabilities.none.wire["terminal"]?.boolValue == false)
        #expect(ACP.ClientCapabilities.none.wire["plan"] == nil)

        let everything = ACP.ClientCapabilities(readTextFile: true, writeTextFile: true,
                                                terminal: true, booleanConfigOptions: true,
                                                compaction: true, plan: true, terminalAuth: true,
                                                elicitationForm: true, elicitationURL: true)
        let wire = everything.wire
        #expect(wire["fs"]?["readTextFile"]?.boolValue == true)
        #expect(wire["terminal"]?.boolValue == true)
        #expect(wire["session"]?["configOptions"]?["boolean"] != nil)
        #expect(wire["session"]?["compaction"] != nil)
        #expect(wire["plan"] != nil)
        #expect(wire["auth"]?["terminal"]?.boolValue == true)
        #expect(wire["elicitation"]?["form"] != nil)
        #expect(wire["elicitation"]?["url"] != nil)
    }

    @Test func whatTheAgentAdvertisedDecidesWhatWeOffer() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(script: .init(sessionCapabilities: ["close": [:], "list": [:],
                                                                    "fork": [:], "delete": [:]],
                                               agentCapabilities: ["promptCapabilities": ["image": true],
                                                                   "auth": ["logout": [:]]]),
                                 transport: theirs)
        let session = ACPSession(transport: mine)
        let result = try await session.initialize()
        #expect(result.supportsList)
        #expect(result.supportsFork)
        #expect(result.supportsDelete)
        #expect(result.supportsLogout)
        #expect(!result.supportsResume, "not advertised, so not offered")
        #expect(result.accepts.allows(.image))
        #expect(!result.accepts.allows(.audio))
        #expect(result.accepts.allows(nil), "text and file references need nothing")
        await agent.stop()
    }
}
