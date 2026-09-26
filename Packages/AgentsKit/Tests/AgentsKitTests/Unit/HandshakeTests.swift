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
                                                elicitationForm: true, elicitationURL: true,
                                                notices: true)
        let wire = everything.wire
        #expect(wire["fs"]?["readTextFile"]?.boolValue == true)
        #expect(wire["terminal"]?.boolValue == true)
        #expect(wire["session"]?["configOptions"]?["boolean"] != nil)
        #expect(wire["session"]?["compaction"] != nil)
        #expect(wire["session"]?["notices"] != nil)
        #expect(ACP.ClientCapabilities.none.wire["session"]?["notices"] == nil,
                "a runtime must not send notices to a client that did not ask for them")
        #expect(ACP.ClientCapabilities.app.notices, "the chat draws them")
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

    @Test func turningAProviderOffNamesIt() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(script: .init(agentCapabilities: ["providers": [:]]), transport: theirs)
        let session = ACPSession(transport: mine)
        _ = try await session.initialize()
        try await session.disableProvider(id: "openai")
        #expect(await agent.disabledProviders == ["openai"])
        await agent.stop()
    }

    @Test func aRuntimeWithoutProvidersIsNotAskedToDisableOne() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(script: .init(), transport: theirs)
        let session = ACPSession(transport: mine)
        _ = try await session.initialize()
        await #expect(throws: ACPSessionError.self) { try await session.disableProvider(id: "openai") }
        #expect(await agent.disabledProviders.isEmpty)
        await agent.stop()
    }

    @Test func aProviderReadsInEitherShape() throws {
        let old = try JSONValue.object(["id": "main", "name": "Main"]).decode(ACP.ProviderInfo.self)
        #expect(old.id == "main")
        #expect(old.canBeDisabled)
        let current = try JSONValue.object(["providerId": "main", "required": true])
            .decode(ACP.ProviderInfo.self)
        #expect(current.id == "main")
        #expect(!current.canBeDisabled, "required means the client must not call providers/disable")
    }

    /// Steering is advertised in `initialize`'s root `_meta`, beside the capabilities
    /// rather than in them, as the Claude adapter and codex-acp both put it.
    @Test func steeringIsReadOffTheRootMeta() throws {
        let said: JSONValue = ["protocolVersion": 1, "agentCapabilities": [:],
                               "_meta": ["steering": ["supported": true]]]
        let result = try said.decode(ACP.InitializeResult.self)
        #expect(result.supportsSteering)
        #expect(RuntimeAccount(runtimeID: "anything", handshake: result).canSteer)
        let silent = try JSONValue.object(["protocolVersion": 1]).decode(ACP.InitializeResult.self)
        #expect(!silent.supportsSteering)
    }

    @Test func steeringIsNotAskedOfARuntimeThatNeverOfferedIt() async throws {
        let (mine, theirs) = PairedTransport.pair()
        let agent = FakeACPAgent(script: .init(), transport: theirs)
        let session = ACPSession(transport: mine)
        _ = try await session.initialize()
        await #expect(throws: ACPSessionError.self) { _ = try await session.steer([.text("now")]) }
        #expect(await agent.steers.isEmpty)
        await agent.stop()
    }

    /// An account from a daemon that predates steering still reads, and never offers it.
    @Test func anOlderAccountReadsWithoutSteering() throws {
        var encoded = try JSONValue.encoding(RuntimeAccount(runtimeID: "claude", canSteer: true))
        if case .object(var object) = encoded {
            object.removeValue(forKey: "canSteer")
            encoded = .object(object)
        }
        #expect(try encoded.decode(RuntimeAccount.self).canSteer == false)
    }
}
