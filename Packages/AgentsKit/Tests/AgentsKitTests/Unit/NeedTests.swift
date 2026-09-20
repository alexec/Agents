import Foundation
import Testing
@testable import AgentsKitCore

/// The same agent asking twice is two needs, and answering the first must not clear the
/// second — so the identity is the question's, never the agent's.
@Suite("What wants a person")
struct NeedTests {
    @Test func twoPermissionsOnOneAgentAreTwoNeeds() {
        #expect(NeedID.permission(UUID()) != NeedID.permission(UUID()))
    }

    @Test func aPermissionAndAnElicitationWithOneUUIDAreTwoNeeds() {
        let id = UUID()
        #expect(NeedID.permission(id) != NeedID.elicitation(id))
        #expect(NeedID.permission(id).token != NeedID.elicitation(id).token)
    }

    @Test func twoReportsAreTwoNeedsUnlessTheyAreTheSameReport() {
        let agent = UUID()
        let at = Date()
        #expect(NeedID.report(agent, at) == NeedID.report(agent, at))
        #expect(NeedID.report(agent, at) != NeedID.report(agent, at.addingTimeInterval(1)))
    }

    @Test func raisedAtIsUnchangedByARedecide() {
        let raised = Date(timeIntervalSinceReferenceDate: 500)
        let need = Need(id: .permission(UUID()), agentID: UUID(), folder: URL(filePath: "/p"),
                        kind: .permission, raisedAt: raised, headline: .placeholder)
        let thresholds = AttentionThresholds()
        _ = Routing.decide(need: need, presences: [:], devices: [], delivery: nil, thresholds: thresholds, now: raised)
        _ = Routing.decide(need: need, presences: [:], devices: [], delivery: nil, thresholds: thresholds,
                           now: raised.addingTimeInterval(1000))
        #expect(need.raisedAt == raised)
    }

    @Test func aHeadlineIsTruncatedBeforeItIsSealedAndNeverBlank() {
        let long = String(repeating: "x", count: 500)
        let cut = Headline(h1: long, h2: "", h3: "   ").truncating(to: 100)
        #expect(cut.fits(100))
        #expect(cut.h1.count == 100)
        #expect(cut.h1.hasSuffix("…"))
        #expect(cut.h2 == Headline.placeholder.h2, "an empty agent name still identifies an agent")
        #expect(cut.h3 == Headline.placeholder.h3)
        #expect(!Headline(h1: long, h2: "a", h3: "b").fits(100))
    }

    @Test func aSurfaceRoundTripsAsATaggedObject() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let id = UUID()
        for surface in [Surface.mac, .device(id)] {
            let data = try encoder.encode(surface)
            #expect(try decoder.decode(Surface.self, from: data) == surface)
        }
        let text = String(decoding: try encoder.encode(Surface.device(id)), as: UTF8.self)
        #expect(text.contains("\"device\""))
        #expect(String(decoding: try encoder.encode(Surface.mac), as: UTF8.self).contains("\"mac\""))
    }

    @Test func aNeedIDRoundTrips() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let at = Date(timeIntervalSinceReferenceDate: 12345)
        for id in [NeedID.permission(UUID()), .elicitation(UUID()), .report(UUID(), at)] {
            #expect(try decoder.decode(NeedID.self, from: try encoder.encode(id)) == id)
        }
    }
}
