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
}
