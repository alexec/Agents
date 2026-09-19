import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What every agent is told before its first turn.
///
/// Worth a test of its own because the briefing is the only thing that makes any of
/// these tools get used: a tool description is read by an agent already looking for
/// one, and this is read by every agent, once. A line that quietly drops out of it
/// takes its feature with it, and nothing else fails.
@Suite("What every agent is told")
struct BriefingTests {
    @Test func everyLineIsInTheBlockThatIsSent() {
        for line in Briefing.lines {
            #expect(Briefing.text.contains(line))
        }
    }

    /// Named, not described. An agent told "use the workflow tool" has to guess at what
    /// it is called; an agent told the name can call it.
    @Test func theToolsItNamesAreNamedExactly() {
        #expect(Briefing.suggestions.contains(AppTool.suggestPrompts))
        #expect(Briefing.workflows.contains(AppTool.manageWorkflows))
    }

    /// The escalation line names no tool, because the tool is the runtime's: an
    /// elicitation, which each adapter raises from something of its own. It has to say
    /// the act and the reason instead.
    @Test func theEscalationLineAsksForTheActRatherThanATool() {
        #expect(!Briefing.escalation.contains("mcp__"))
        #expect(Briefing.escalation.lowercased().contains("ask me"))
    }

    /// Short, because it is paid for on the first prompt of every conversation and an
    /// agent told six things at once follows the first two. The number is a ceiling to
    /// notice, not a rule: if a fourth line is worth more than this limit, raise it on
    /// purpose.
    @Test func itStaysShortEnoughToBeRead() {
        #expect(Briefing.text.count < 1_200)
        #expect(Briefing.lines.count <= 4)
    }
}
