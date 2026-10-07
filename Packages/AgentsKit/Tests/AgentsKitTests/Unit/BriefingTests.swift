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
    @Test func everyAgentIsToldHowToContinueAnotherSession() {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(Briefing.lines(for: policy).contains(Briefing.sessions))
            #expect(Briefing.lines(for: policy, managesAgents: false).contains(Briefing.sessions))
        }
    }

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

    @Test func cursorIsPointedToItsLiveMCPToolSchemas() {
        let text = Briefing.text(for: ToolPolicyCatalog.cursor)
        #expect(text.contains(AppToolPreface.firstPrompt))
        #expect(!text.contains("agents__\(AppTool.finishTurn)"))
    }

    /// The older names are retired; a fresh conversation is told the one tool and
    /// nothing older (023 FR-016, R5).
    @Test func theFinishLineNamesNeitherOldName() {
        for retired in AppTool.retiredEndOfTurn {
            #expect(!Briefing.finish.contains(retired))
            for policy in ToolPolicyCatalog.builtIn {
                #expect(!Briefing.text(for: policy).contains(retired))
            }
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

    // MARK: Who is who (#121)

    static let alex = Briefing.Naming(runtime: "Claude", person: "Alex")

    /// One sentence, second, naming the runtime by its display name and the person by
    /// theirs, with the rule for questions only: no bare "I" or "you" there, plain
    /// "I" and "you" anywhere else (#335).
    @Test func theNamingSentenceNamesTheRuntimeAndThePerson() {
        let line = Briefing.naming(Self.alex)
        #expect(line.hasPrefix("You are Claude and I am Alex:"))
        #expect(line.contains("in a question to me (a form card, a turn ending on my answer, or a question in a reply)"))
        #expect(!line.contains("messages to me"))
        #expect(line.contains("anywhere else plain \"I\" and \"you\" are fine"))
        #expect(line.contains("never write a bare \"I\" or \"you\""))
        #expect(line.contains("\"Claude (this agent) will…\""))
        #expect(line.contains("\"Alex, do you want…?\""))
        #expect(line.contains("name any other agent by its title"))
        // One sentence, said once.
        #expect(line.split(separator: ". ").count == 1)
        for policy in ToolPolicyCatalog.builtIn {
            let lines = Briefing.lines(for: policy, naming: Self.alex)
            #expect(lines.first == Briefing.finish)
            #expect(lines.dropFirst().first == line)
            #expect(Briefing.text(for: policy, naming: Self.alex).components(separatedBy: "You are Claude").count == 2)
        }
    }

    /// Pronouns are the person's to give: without them, the name or "they".
    @Test func withoutPronounsItIsTheNameOrThey() {
        #expect(Briefing.naming(Self.alex).hasSuffix("refer to me by name or as \"they\"."))
        let given = Briefing.naming(.init(runtime: "Grok", person: "Sam", pronouns: "she/her"))
        #expect(given.hasSuffix("refer to me by name or as she/her."))
        #expect(!given.contains("\"they\""))
    }

    /// A helper names the agent that started it by title, as the person sees it.
    @Test func aHelperIsToldWhoStartedIt() {
        let helper = Briefing.naming(.init(runtime: "Claude", person: "Alex", startedBy: "Project lead"))
        #expect(helper.hasPrefix("You are Claude, started by \u{201C}Project lead\u{201D}, and I am Alex:"))
        let untitled = Briefing.naming(.init(runtime: "Claude", person: "Alex", startedBy: ""))
        #expect(untitled.hasPrefix("You are Claude, started by another agent, and I am Alex:"))
    }

    /// The person's name: the one set, else the account's first name, else something
    /// that still reads.
    @Test func theNameFallsBackToTheAccountsFirstName() {
        #expect(PersonSettings(name: "Sam").effectiveName(accountName: "Alex Collins") == "Sam")
        #expect(PersonSettings(name: "  ").effectiveName(accountName: "Alex Collins") == "Alex")
        #expect(PersonSettings().effectiveName(accountName: "Alex Collins") == "Alex")
        #expect(PersonSettings().effectiveName(accountName: "") == "the person")
        #expect(PersonSettings(pronouns: " ").givenPronouns == nil)
        #expect(PersonSettings().resolved(accountName: "Alex Collins") == PersonSettings(name: "Alex"))
        // And what the daemon says with nothing set is this account's first name.
        let said = Briefing.naming(.init(runtime: "Claude", person: PersonSettings().effectiveName()))
        #expect(said.contains("I am \(PersonSettings.firstName(of: NSFullUserName()) ?? "the person"):"))
    }

    /// Without a naming, nothing is said: a caller that does not know says nothing.
    @Test func noNamingSaysNothing() {
        for policy in ToolPolicyCatalog.builtIn {
            #expect(!Briefing.text(for: policy).contains("You are "))
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
        #expect(Briefing.escalation(named: "AskUserQuestion").contains("`\(AppTool.askForm)`"))
        #expect(Briefing.text(for: ToolPolicyCatalog.claude).contains("`AskUserQuestion`"))
        #expect(Briefing.text(for: ToolPolicyCatalog.claude).contains("`\(AppTool.askForm)`"))
        // Antigravity's reaches the person as a permission request whose options are the
        // answers (049, R7), so it is named too.
        #expect(Briefing.text(for: ToolPolicyCatalog.antigravity).contains("`ask_question`"))
        // Cursor's AskQuestion is the primary; ask_form is the fallback Composer needs.
        #expect(Briefing.text(for: ToolPolicyCatalog.cursor).contains("`AskQuestion`"))
        #expect(Briefing.text(for: ToolPolicyCatalog.cursor).contains("`\(AppTool.askForm)`"))
    }

    /// And names `ask_form` on a runtime whose own ask tool has no channel that reaches
    /// the person — Grok's `ask_user_question` is a terminal-UI card with no ACP path
    /// (R13), Gemini and Copilot likewise. Naming the runtime tool was measured: the
    /// agent spent the turn searching the MCP catalogue for it and guessed anyway.
    /// Naming the app's own tool, which is always on that catalogue, is the fix.
    @Test func andNamesAskFormWhereThereIsNoRuntimeChannel() {
        for policy in [ToolPolicyCatalog.grok, ToolPolicyCatalog.copilot, ToolPolicyCatalog.gemini] {
            #expect(policy.escalationTool == nil, "\(policy.runtimeID)")
            #expect(Briefing.text(for: policy).contains("Yours is called `\(AppTool.askForm)`"))
            #expect(!Briefing.text(for: policy).contains("If you do not have it"))
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
    ///
    /// Raised with self-archiving, to 2,550 and 2,350, for one sentence on the finish
    /// line saying the call can also put the conversation away once the turn ends
    /// (104 characters; no new line). Measured then at 2,501 for the longest (Cursor).
    /// Every agent is told it, so both ceilings go up by the same.
    ///
    /// Raised with ask_form, to 2,650 and 2,450: every runtime is told the app's own
    /// ask tool by name, and Cursor names AskQuestion as well (~70 characters on the
    /// longest line).
    ///
    /// Raised with reading another session (065), to 2,800 and 2,600 and nine lines: one
    /// line, told to every agent, helpers included (about 150 characters with its break).
    ///
    /// Raised with who is who (#121), to 3,150 and 2,950 and ten lines: one sentence,
    /// told to every agent, about 300 characters with a long name and a helper's starter.
    @Test func itStaysShortEnoughToBeRead() {
        let naming = Briefing.Naming(runtime: "Antigravity", person: "Alexandra", pronouns: "they/them",
                                     startedBy: "#121 agent names and questions")
        for policy in ToolPolicyCatalog.builtIn {
            let text = Briefing.text(for: policy, naming: naming)
            #expect(text.count < 3_150, "\(policy.runtimeID): \(text.count)")
            #expect(Briefing.lines(for: policy, naming: naming).count <= 10, "\(policy.runtimeID)")
            #expect(Briefing.text(for: policy, managesAgents: false, naming: naming).count < 2_950,
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
        // Grok since 2026-09-29: Cursor's three tools came back, so the runtime with
        // residue left to warn about is Grok's, and Copilot's unknown-id one stands in
        // for "somebody else's residue".
        let grok = try #require(Briefing.residue(ToolPolicyCatalog.grok.residue))
        #expect(Briefing.text(for: ToolPolicyCatalog.grok).contains(grok))
        for tool in ToolPolicyCatalog.grok.residue {
            #expect(grok.contains("`\(tool.name)`"))
        }
        let others = ToolPolicyCatalog.copilot.residue.map(\.name) + ToolPolicyCatalog.cursor.kept.map(\.name)
        for name in others {
            #expect(!grok.contains("`\(name)`"))
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

    /// One sentence per category however many tools share it, so Grok's two standing
    /// arrangements do not produce the same advice twice, and Copilot's one leftover
    /// sub-agent tool is answered with the sub-agent advice rather than the scheduling one.
    @Test func theAdviceIsSaidOncePerCategory() throws {
        let grok = try #require(Briefing.residue(ToolPolicyCatalog.grok.residue))
        let advice = RemitCategory.standingArrangements.instead
        #expect(grok.components(separatedBy: advice).count == 2)
        #expect(!grok.contains(RemitCategory.agents.instead))

        let copilot = try #require(Briefing.residue(ToolPolicyCatalog.copilot.residue))
        #expect(copilot.contains(RemitCategory.agents.instead))
        #expect(!copilot.contains(advice))
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

    /// Told there are limits the person set, and never a number: the numbers are the
    /// project's and can change mid-conversation (#64).
    @Test func anAgentThatMayStartAgentsIsToldSoAndThatThePersonSetsTheLimits() {
        for policy in ToolPolicyCatalog.builtIn {
            let text = Briefing.text(for: policy)
            #expect(text.contains(Briefing.helpers), "\(policy.runtimeID)")
            #expect(text.contains(AppTool.startAgent))
        }
        #expect(Briefing.helpers.contains("the limits the person set"))
        for number in ["three", "five", "3", "5"] {
            #expect(!Briefing.helpers.contains(number), "\(number)")
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
