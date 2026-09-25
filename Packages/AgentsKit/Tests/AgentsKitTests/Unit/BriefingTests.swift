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
        for policy in ToolPolicyCatalog.builtIn {
            for line in Briefing.lines(for: policy) {
                #expect(Briefing.text(for: policy).contains(line))
            }
        }
    }

    /// Named, not described. An agent told "use the workflow tool" has to guess at what
    /// it is called; an agent told the name can call it.
    @Test func theToolsItNamesAreNamedExactly() {
        #expect(Briefing.finish.contains(AppTool.finishTurn))
        #expect(Briefing.liveDocument.contains(AppTool.showFile))
        #expect(Briefing.workflows(scheduling: false).contains(AppTool.manageWorkflows))
        #expect(Briefing.workflows(scheduling: true).contains(AppTool.manageWorkflows))
    }

    /// The older names are for conversations that were told them; a fresh one is told
    /// the one tool and nothing older (023 FR-016).
    @Test func theFinishLineNamesNeitherOldName() {
        #expect(!Briefing.finish.contains(AppTool.suggestPrompts))
        #expect(!Briefing.finish.contains(AppTool.reportOutcome))
        for policy in ToolPolicyCatalog.builtIn {
            #expect(!Briefing.text(for: policy).contains(AppTool.suggestPrompts))
            #expect(!Briefing.text(for: policy).contains(AppTool.reportOutcome))
        }
    }

    /// The file's own rule: the line that fires every turn goes first. 014 put the
    /// outcome line after `escalation` so an agent read "ask with the tool that waits"
    /// before "you may end by saying you need an answer"; the merged line does not
    /// mention `needs_answer` at all, and the tool's description carries that order
    /// now, at the moment it matters (023 Research R6).
    @Test func theFinishLineGoesFirst() {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(Briefing.lines(for: policy).first == Briefing.finish)
        }
    }

    /// The escalation line asks for the act first, whatever the runtime, because the act
    /// is the part that is true everywhere and a runtime may know its tool by a name we
    /// have not written down.
    @Test func theEscalationLineAsksForTheActRatherThanATool() {
        for tool in [nil, "ask_user_question"] {
            let line = Briefing.escalation(named: tool)
            #expect(!line.contains("mcp__"))
            #expect(line.lowercased().contains("ask me"))
            // The reason, which is the load-bearing half: an agent that believes nobody
            // is there is the agent that guesses.
            #expect(line.contains("phone"))
        }
    }

    /// And names the tool on top of it where the policy has one. Claude's question
    /// arrives as a held elicitation, so an agent that knows the name can raise one.
    @Test func andNamesTheToolWhereThePolicyKnowsIt() {
        #expect(Briefing.escalation(named: "AskUserQuestion").contains("`AskUserQuestion`"))
        #expect(Briefing.text(for: ToolPolicyCatalog.claude).contains("`AskUserQuestion`"))
    }

    /// And names nothing on a runtime with no tool that can reach the person — which
    /// includes Grok, whose `ask_user_question` is a terminal-UI card with no ACP
    /// channel behind it (R13). Naming it was measured: the agent spent the turn
    /// searching the MCP catalogue for it and guessed anyway. Worse than saying nothing,
    /// which is what FR-008 is about.
    @Test func andNamesNothingWhereThereIsNoChannel() {
        for policy in [ToolPolicyCatalog.grok, ToolPolicyCatalog.copilot, ToolPolicyCatalog.cursor] {
            #expect(policy.escalationTool == nil, "\(policy.runtimeID)")
            #expect(Briefing.text(for: policy).contains("your question or form tool"))
            #expect(!Briefing.text(for: policy).contains("Yours is called"))
        }
        // Kept all the same: taking it out of the allowlist would buy nothing today and
        // cost us the day Grok gives it a way out.
        #expect(ToolPolicyCatalog.grok.kept.contains { $0.name == "ask_user_question" })
    }

    /// The name the briefing says out loud is the one the policy deliberately kept, not
    /// a second spelling maintained beside it that could drift.
    @Test func theNamedToolIsTheOneScopingKept() {
        for policy in ToolPolicyCatalog.builtIn {
            guard let tool = policy.escalationTool else { continue }
            #expect(policy.kept.contains { $0.name == tool },
                    "\(policy.runtimeID) names \(tool) in the briefing and does not keep it")
            #expect(!policy.removed.contains { $0.name == tool })
        }
    }

    /// Short, because it is paid for on the first prompt of every conversation and an
    /// agent told six things at once follows the first two. The number is a ceiling to
    /// notice, not a rule: if a fifth line is worth more than this limit, raise it on
    /// purpose.
    ///
    /// Raised on purpose in 014, from 1,200. The outcome line is the one thing here the
    /// app cannot learn any other way — a turn ending says nothing about whether the
    /// work is done — so it is worth the three hundred characters, and `Briefing.text`
    /// was read end to end for repetition before the number moved.
    ///
    /// Held against the longest of the four in 015, which is the runtime with the most
    /// residue. That feature pushes the other way: where a tool is actually gone the
    /// words about it go too, so three of the four now read shorter than they did.
    ///
    /// Lowered in 023, from 1,650 and six lines. The suggestion line and the outcome
    /// line became one, and the clause ordering them went with it, so the ceiling
    /// comes down rather than up — still a ceiling to notice, not a rule.
    ///
    /// Raised in 028, to 1,700 and six lines, for the one line about starting agents
    /// of its own. Measured then at 1,688 for the longest (Cursor, with the most
    /// residue), 1,608 and 1,532 for the next two. An agent another agent started is
    /// not told it, so its briefing is where it was.
    ///
    /// Raised in 036, to 2,100 and seven lines, for the one line about leasing what
    /// only one agent should use at a time (FR-015), cut to 396 characters. Measured
    /// then at 2,085 for the longest (Cursor), 2,084 and 2,005 for the next two. Every
    /// agent is told this one, so an agent another agent started goes up by the same.
    ///
    /// Raised in 042, to 2,450 and eight lines, for the one line about waiting on what
    /// happens instead of polling, and publishing (FR-006, FR-017), cut to 309
    /// characters. Every agent is told it, so both ceilings go up by the same.
    @Test func itStaysShortEnoughToBeRead() {
        for policy in ToolPolicyCatalog.builtIn {
            let text = Briefing.text(for: policy)
            #expect(text.count < 2_450, "\(policy.runtimeID): \(text.count)")
            #expect(Briefing.lines(for: policy).count <= 8, "\(policy.runtimeID)")
            #expect(Briefing.text(for: policy, managesAgents: false).count < 2_250,
                    "\(policy.runtimeID), for an agent another agent started")
        }
    }

    // MARK: What could not be taken away

    /// The residue line names this runtime's residue and nobody else's. It is generated
    /// from the policy precisely so that it cannot drift from it — a tool named here
    /// that the agent still has, or has never had, is the failure this guards.
    ///
    /// Names are matched in their backticks rather than bare, because the briefing says
    /// the word "workflow" in the ordinary course of telling an agent what a workflow
    /// is, and Grok's residue happens to be called that.
    @Test func theResidueLineNamesThisRuntimesResidueAndNoOthers() throws {
        let cursor = try #require(Briefing.residue(ToolPolicyCatalog.cursor.residue))
        #expect(Briefing.text(for: ToolPolicyCatalog.cursor).contains(cursor))
        for tool in ToolPolicyCatalog.cursor.residue {
            #expect(cursor.contains("`\(tool.name)`"))
        }
        for tool in ToolPolicyCatalog.grok.residue {
            #expect(!cursor.contains("`\(tool.name)`"))
        }
    }

    /// And a runtime that gave up everything we asked for is told nothing about it.
    /// A removed tool needs no words: the model never sees it.
    @Test func aRuntimeWithNoResidueIsToldNothingAboutIt() {
        #expect(ToolPolicyCatalog.claude.residue.isEmpty)
        #expect(Briefing.residue(ToolPolicyCatalog.claude.residue) == nil)
        let claude = Briefing.text(for: ToolPolicyCatalog.claude)
        #expect(!claude.contains("does not work in this app"))
        #expect(!claude.contains("do not work in this app"))
    }

    /// One sentence per category however many tools share it, so Cursor's two goal
    /// tools do not produce the same advice twice.
    @Test func theAdviceIsSaidOncePerCategory() throws {
        let line = try #require(Briefing.residue(ToolPolicyCatalog.cursor.residue))
        let advice = RemitCategory.standingArrangements.instead
        #expect(line.components(separatedBy: advice).count == 2)
        #expect(line.contains(RemitCategory.agents.instead))
    }

    /// The cron sentence is spent only where there is still something to forbid. On a
    /// runtime whose scheduling tools are gone it is a sentence about a door that is
    /// already shut.
    @Test func theCronSentenceGoesWhereTheCronToolsHave() {
        let cron = "cron entries"
        #expect(!Briefing.workflows(scheduling: true).contains(cron))
        #expect(Briefing.workflows(scheduling: false).contains(cron))
        // Both halves survive either way: name the tool, and say not to invent a
        // workflow nobody asked for. The second is the condition 016's reversal rests
        // on and must not be tidied away with the first.
        for text in [Briefing.workflows(scheduling: true), Briefing.workflows(scheduling: false)] {
            #expect(text.contains(AppTool.manageWorkflows))
            #expect(text.contains("did not ask for"))
        }
    }

    /// And it is decided by the policy rather than by a runtime's name: Claude and Grok
    /// lose their schedulers, Cursor keeps everything it has.
    @Test func whichOfThoseEachRuntimeGetsComesFromItsPolicy() {
        #expect(!Briefing.text(for: ToolPolicyCatalog.claude).contains("cron entries"))
        #expect(!Briefing.text(for: ToolPolicyCatalog.grok).contains("cron entries"))
        #expect(Briefing.text(for: ToolPolicyCatalog.cursor).contains("cron entries"))
    }

    // MARK: What the person changed on the page

    /// The note that tells an agent the document changed under it (022 FR-016). The
    /// wording is the contract in specs/022-live-artifacts/contracts/daemon-api.md, and
    /// the shape is what makes it usable: the path once, each passage's lines, the
    /// passage itself in a fence, and the sentence that says what to do about it.
    @Test func theArtifactNoteSaysWhatChangedAndWhatToDo() throws {
        let edit = Briefing.ArtifactEdit(path: "/p/notes.md", lines: 12...15, text: "Second paragraph, as I put it.")
        let note = try #require(Briefing.artifactEdited([edit]))
        #expect(note.hasPrefix("Since your last turn I edited `/p/notes.md`. Lines 12–15 now read:"))
        #expect(note.contains("```\nSecond paragraph, as I put it.\n```"))
        #expect(note.hasSuffix("Work from what is there now; do not restore what you wrote before."))
    }

    @Test func twoPassagesInOneFileAreOneFileLineAndTwoBlocksInOrder() throws {
        let later = Briefing.ArtifactEdit(path: "/p/notes.md", lines: 20...21, text: "Later.")
        let earlier = Briefing.ArtifactEdit(path: "/p/notes.md", lines: 3...3, text: "Earlier.")
        let note = try #require(Briefing.artifactEdited([later, earlier]))
        #expect(note.components(separatedBy: "I edited `/p/notes.md`").count == 2)
        let first = try #require(note.range(of: "Lines 3–3 now read:"))
        let second = try #require(note.range(of: "Lines 20–21 now read:"))
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func twoFilesAreTwoParagraphs() throws {
        let a = Briefing.ArtifactEdit(path: "/p/a.md", lines: 1...1, text: "A.")
        let b = Briefing.ArtifactEdit(path: "/p/b.md", lines: 1...1, text: "B.")
        let note = try #require(Briefing.artifactEdited([a, b]))
        #expect(note.contains("I edited `/p/a.md`"))
        #expect(note.contains("I edited `/p/b.md`"))
    }

    @Test func pastTwentyTheNoteSaysToReadTheFile() throws {
        let edits = (1...21).map { Briefing.ArtifactEdit(path: "/p/n.md", lines: $0...$0, text: "Line \($0).") }
        let note = try #require(Briefing.artifactEdited(edits))
        #expect(note.components(separatedBy: "now read:").count == 21)
        #expect(note.contains("…and more. Read the file before changing it."))
    }

    @Test func nothingEditedIsNoNote() {
        #expect(Briefing.artifactEdited([]) == nil)
    }

    // MARK: Agents of its own (028)

    @Test func anAgentThatMayStartAgentsIsToldSoAndHowMany() {
        for policy in ToolPolicyCatalog.builtIn {
            let text = Briefing.text(for: policy)
            #expect(text.contains(Briefing.helpers), "\(policy.runtimeID)")
            #expect(text.contains(AppTool.startAgent))
            #expect(text.contains("three"))
        }
    }

    @Test func anAgentAnotherAgentStartedIsNotToldAboutToolsItDoesNotHave() {
        for policy in ToolPolicyCatalog.builtIn {
            let text = Briefing.text(for: policy, managesAgents: false)
            #expect(!text.contains(Briefing.helpers), "\(policy.runtimeID)")
            #expect(!text.contains(AppTool.startAgent))
            #expect(text.contains(Briefing.finish), "and is told everything else")
        }
    }

    /// After the workflow line, where the other standing things an agent can set going
    /// are said, and before anything about residue, which is last on purpose.
    @Test func theLineComesAfterTheWorkflowLine() {
        for policy in ToolPolicyCatalog.builtIn {
            let lines = Briefing.lines(for: policy)
            #expect(lines.firstIndex(of: Briefing.helpers) == 4, "\(policy.runtimeID)")
        }
    }
}
