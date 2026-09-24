import Foundation
import Testing
@testable import AgentsKitCore

/// The person is typing in one passage and the agent rewrites the file underneath.
///
/// The claim: whatever the merge decides, the person's text is in the result — merged
/// where it was, or kept and set beside the agent's version on a collision. FR-015:
/// nothing typed is lost without the page saying so, and the merge is where it would be.
@Suite("Merging one passage")
struct PassageMergeTests {
    private let base = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n"

    /// The person is in the second paragraph.
    private var mine: Passage { Passage.split(base)[2] }
    private let edited = "Second paragraph, as I would put it."

    private func text(_ result: PassageMerge.Result) -> String {
        switch result {
        case .merged(let text, _), .collided(let text, _, _): return text
        }
    }

    @Test func nothingChangedUnderMeIsMergedInPlace() {
        let result = PassageMerge.apply(base: base, theirs: base, mine: mine, edited: edited)
        guard case .merged(let text, let index) = result else { Issue.record("collided"); return }
        #expect(index == 2)
        #expect(text == "# Title\n\nFirst paragraph.\n\nSecond paragraph, as I would put it.\n\nThird paragraph.\n")
    }

    @Test func aChangeBeforeMeShiftsMyPassageDown() {
        let theirs = "# Title\n\nA new opening.\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited)
        guard case .merged(let text, let index) = result else { Issue.record("collided"); return }
        #expect(index == 3)
        #expect(text.contains("A new opening.\n\nFirst paragraph.\n\nSecond paragraph, as I would put it.\n\nThird"))
    }

    @Test func aChangeAfterMeLeavesMyIndexAlone() {
        let theirs = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird, rewritten.\n\nFourth.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited)
        guard case .merged(let text, let index) = result else { Issue.record("collided"); return }
        #expect(index == 2)
        #expect(text.contains("Second paragraph, as I would put it.\n\nThird, rewritten."))
    }

    @Test func aPassageDeletedBeforeMeShiftsMyPassageUp() {
        let theirs = "# Title\n\nSecond paragraph.\n\nThird paragraph.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited)
        guard case .merged(let text, let index) = result else { Issue.record("collided"); return }
        #expect(index == 1)
        #expect(text == "# Title\n\nSecond paragraph, as I would put it.\n\nThird paragraph.\n")
    }

    @Test func theirRewriteOfMyPassageIsACollisionThatKeepsMine() {
        let theirs = "# Title\n\nFirst paragraph.\n\nSecond paragraph, as the agent put it.\n\nThird paragraph.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited)
        guard case .collided(let text, let index, let agents) = result else { Issue.record("merged"); return }
        #expect(index == 2)
        #expect(agents == "Second paragraph, as the agent put it.")
        #expect(text == "# Title\n\nFirst paragraph.\n\nSecond paragraph, as I would put it.\n\nThird paragraph.\n")
    }

    @Test func theirDeletionOfMyPassageIsACollisionWithNothingOfTheirs() {
        let theirs = "# Title\n\nFirst paragraph.\n\nThird paragraph.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited)
        guard case .collided(let text, let index, let agents) = result else { Issue.record("merged"); return }
        #expect(agents == "")
        #expect(index == 2)
        #expect(text.contains(edited))
        // Mine is put back where its line was, before what now sits there.
        #expect(text == "# Title\n\nFirst paragraph.\n\nSecond paragraph, as I would put it.\n\nThird paragraph.\n")
    }

    @Test func theirEmptyDocumentIsACollisionHoldingOnlyMine() {
        let result = PassageMerge.apply(base: base, theirs: "", mine: mine, edited: edited)
        guard case .collided(let text, let index, let agents) = result else { Issue.record("merged"); return }
        #expect(index == 0)
        #expect(agents == "")
        #expect(text == edited)
    }

    @Test func nothingTypedIsTheirsUnchanged() {
        let theirs = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird, rewritten.\n"
        let result = PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: mine.source)
        guard case .merged(let text, let index) = result else { Issue.record("collided"); return }
        #expect(index == 2)
        #expect(text == theirs)
    }

    @Test func mineIsInEveryResult() {
        let cases = [base,
                     "# Title\n\nA new opening.\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird paragraph.\n",
                     "# Title\n\nFirst paragraph.\n\nSecond paragraph, as the agent put it.\n\nThird paragraph.\n",
                     "# Title\n\nFirst paragraph.\n\nThird paragraph.\n",
                     "Entirely different.",
                     ""]
        for theirs in cases {
            #expect(text(PassageMerge.apply(base: base, theirs: theirs, mine: mine, edited: edited))
                .contains(edited), "\(theirs.debugDescription)")
        }
    }
}
