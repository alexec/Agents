import Testing
@testable import AgentsKitCore

/// Which of two modes asks less often, for an agent choosing one for another.
@Suite("How loose a mode is")
struct ModeLoosenessTests {
    @Test func theSameModeIsAlwaysAllowedEvenOneNobodyKnows() {
        #expect(ModeLooseness.isNoLooser("default", than: "default"))
        #expect(ModeLooseness.isNoLooser("somethingNew", than: "somethingNew"))
    }

    @Test func claudesModesRunFromPlanToBypass() {
        let order = ["plan", "default", "acceptEdits", "auto", "bypassPermissions"]
        for (i, stricter) in order.enumerated() {
            for looser in order[(i + 1)...] {
                #expect(ModeLooseness.isNoLooser(stricter, than: looser), "\(stricter) under \(looser)")
                #expect(!ModeLooseness.isNoLooser(looser, than: stricter), "\(looser) over \(stricter)")
            }
        }
    }

    @Test func copilotsModesAreWeighedByTheirLastPart() {
        let base = "https://agentclientprotocol.com/protocol/session-modes#"
        #expect(ModeLooseness.isNoLooser(base + "plan", than: base + "agent"))
        #expect(!ModeLooseness.isNoLooser(base + "autopilot", than: base + "agent"))
    }

    @Test func aModeNobodyKnowsIsNeverShownToBeStricter() {
        #expect(!ModeLooseness.isNoLooser("yolo", than: "bypassPermissions"))
        #expect(!ModeLooseness.isNoLooser("plan", than: "yolo"))
    }
}
