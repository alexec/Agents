import Foundation
import Testing
@testable import AgentsKitCore

/// #2358: approvals and plans by voice. Low risk once only, never "always"; high risk
/// needs the screen.
@Suite("Approvals by voice")
struct SpokenPermissionTests {
    private static let options = [
        PermissionOption(optionID: "always", name: "Always allow", kind: .allowAlways),
        PermissionOption(optionID: "once", name: "Allow", kind: .allowOnce),
        PermissionOption(optionID: "no", name: "Reject", kind: .rejectOnce),
    ]
    private static let worktree = URL(fileURLWithPath: "/tmp/repo/.agents/worktrees/lane")

    private static func request(_ title: String, kind: String, paths: [String] = [],
                                rawInput: JSONValue? = nil) -> PermissionRequest {
        PermissionRequest(agentID: UUID(),
                          toolCall: ToolCall(title: title, kind: kind,
                                             locations: paths.map { ToolCallLocation(path: $0) },
                                             rawInput: rawInput),
                          options: options)
    }

    @Test func aReadIsAllowedOnceNeverAlways() {
        let spoken = SpokenPermission(Self.request("Read README.md", kind: "read"), who: "Claude", worktree: nil)
        #expect(spoken.isAnswerable)
        #expect(spoken.sentences == ["Claude asks to read README.md.", "Allow it once?"])
        #expect(spoken.answer(for: "Yes.") == .allow(optionID: "once"))
        #expect(spoken.answer(for: "No, don't.") == .reject(optionID: "no"))
        #expect(spoken.answer(for: "What is it for?") == nil)
    }

    @Test func anEditInTheWorktreeIsLowRisk() {
        let inside = Self.request("Edit Sources/A.swift", kind: "edit", paths: [Self.worktree.path + "/Sources/A.swift"])
        #expect(SpokenPermission(inside, who: "Claude", worktree: Self.worktree).isAnswerable)
        let outside = Self.request("Edit A.swift", kind: "edit", paths: ["/tmp/repo/Sources/A.swift"])
        #expect(!SpokenPermission(outside, who: "Claude", worktree: Self.worktree).isAnswerable)
        // Not in a worktree: an edit needs the screen.
        #expect(!SpokenPermission(inside, who: "Claude", worktree: nil).isAnswerable)
    }

    @Test func highRiskNeedsTheScreen() {
        for (title, kind) in [("git push origin main", "execute"), ("Run the tests", "execute"),
                              ("Delete build", "delete"), ("Read and then rm -rf x", "read")] {
            let spoken = SpokenPermission(Self.request(title, kind: kind), who: "Claude", worktree: Self.worktree)
            #expect(!spoken.isAnswerable, "\(title)")
            #expect(spoken.sentences.last == SpokenPermission.needsTheScreen)
            #expect(spoken.answer(for: "yes") == nil)
        }
    }

    @Test func aPlanSaysItsStepsAndAsks() {
        let plan = """
        # Fix the bug

        1. Find where the tap is installed.
        2. Map the first channel.
        3. Add a test.
        """
        let request = Self.request("Ready to code?", kind: "switch_mode", rawInput: .object(["plan": .string(plan)]))
        let spoken = SpokenPermission(request, who: "Claude", worktree: nil)
        #expect(spoken.isPlan)
        #expect(spoken.sentences == ["The plan has 3 steps.", "First: Find where the tap is installed.",
                                     "Second: Map the first channel.", "Approve the plan?"])
        #expect(spoken.answer(for: "Approve it") == .allow(optionID: "once"))
    }

    @Test func aPlanOfHeadingsOrNoneAtAll() {
        #expect(SpokenPermission.planSteps("## Read\nsome text\n## Write\n") == ["Read", "Write"])
        #expect(SpokenPermission.planSentences("Just do it.") == ["The plan is on the screen."])
    }

    @Test func stillWorkingSaysTheStep() {
        #expect(StillWorking.line(step: "Running the tests") == "Still working. Running the tests.")
        #expect(StillWorking.line(step: nil) == "Still working.")
    }
}
