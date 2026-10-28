import Foundation
import Testing
@testable import AgentsKitCore

/// A project list that could not be read is not a list with none (#2756).
@Suite("Project words")
struct ProjectWordsTests {
    @Test func aFailedReadSaysWhyAndAnOlderControlPlaneSaysNothing() {
        #expect(ProjectWords.notRead(JSONRPCError(code: -32000, message: "The store is busy.", data: nil))
            == "Couldn’t read the projects. The store is busy.")
        #expect(ProjectWords.notRead(JSONRPCError.methodNotFound("projects/list")) == nil)
        #expect(ProjectWords.notRead(CancellationError()) == "Couldn’t read the projects. The control plane can’t be reached.")
    }
}
