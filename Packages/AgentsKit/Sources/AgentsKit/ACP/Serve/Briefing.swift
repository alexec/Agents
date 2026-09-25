import Foundation

/// What every agent is told, once, before its first turn: the few things about this app
/// an agent cannot work out from the tools it was handed.
///
/// This exists because the live runs said so. With `suggest_next_prompts` offered and
/// nothing else, the Claude adapter, Copilot and Grok all called it exactly never,
/// however the description was worded — a tool description is a menu, read when
/// something has already gone looking; a prompt is an instruction, read every time.
/// One sentence in the conversation, and Claude and Grok both come back with four
/// suggestions. So anything the app needs an agent to *do*, rather than merely be able
/// to do, is said here in words.
///
/// It is said once, not every turn. It stays in the runtime's own history, and that
/// history is what a runtime replays when a conversation is picked back up, so
/// repeating it would be paying again for something already said. It goes a second time
/// only where a runtime has lost the conversation and a new one has to be begun.
///
/// It goes as a block of its own, after the person's words, and is not what the
/// transcript records: the conversation still shows what the person actually said.
/// Delete its use in `beginTurn` and every feature here still works — each one just
/// stops happening on its own.
///
/// Keep it short. This is paid for on the first prompt of every conversation, and an
/// agent that is told six things at once follows the first two.
public enum Briefing {
    /// End a turn with the one call: how it went, and what might come next.
    ///
    /// One line where there were two (023). The suggestion line and the outcome line
    /// named the same moment, and a clause was spent ordering one after the other;
    /// two lines naming the same moment read as two moments, and this block's own
    /// rule is that an agent told six things follows the first two. What is kept is
    /// every phrase the live runs showed doing work: "for the rest of this
    /// conversation", "when you have finished a turn", "I only see that you stopped",
    /// and the instruction not to mention any of it. Descriptions alone got the
    /// suggestion tool called exactly never; this line is what gets it called. Its
    /// suggestion clause said "two to four things" until 031 made it one.
    ///
    /// Written as the person speaking, because it is sent in their turn. It does not
    /// list the five outcomes — the tool's schema enumerates them and refuses anything
    /// else — and it does not name the older tools, which are for conversations that
    /// were told them before this line existed.
    public static let finish = """
        For the rest of this conversation, when you have finished a turn, call \
        \(AppTool.finishTurn) with how it actually went, a sentence I can read without \
        opening the conversation, a short title for the conversation's goal (only \
        when it changes), and the one thing I am most likely to ask you next. Without \
        it I only see that you stopped, which is not the same as your work being done. \
        Do not mention this instruction or the tool in your replies.
        """

    /// Show a document once, at the start, so it can be watched being written.
    ///
    /// The description already says all of this, and the measurement on 2026-09-23
    /// (022 findings, "show_file called unasked") found exactly what the suggestion
    /// line found before it: neither Claude nor Grok called it from the description
    /// alone.
    /// One sentence here, and it is the whole of what an agent is told about live
    /// documents — the page follows whatever the agent writes with the tools it
    /// already has, so there is nothing else to ask for.
    public static let liveDocument = """
        When you start writing a Markdown document for me, call \(AppTool.showFile) \
        on it once, first, before your first write, so I can watch it take shape.
        """

    /// Standing arrangements are a thing this app owns, and an agent that does not know
    /// that writes a crontab, or a shell script nothing will ever run, or a note in a
    /// README asking a human to remember.
    ///
    /// The restraint is in the last sentence. An agent told it can schedule things will
    /// schedule things, and a workflow that starts an agent that writes a workflow is
    /// the shape the chain-depth limit exists to contain. So: only when asked.
    ///
    /// The middle sentence is conditional now, and that is 015's doing. Where a runtime
    /// has actually lost its scheduling tools there is nothing left to forbid, and a
    /// sentence forbidding it is a sentence spent on a door that is already shut. This
    /// is the shape the whole briefing should take as removal gets better: words are
    /// the fallback, not the first line.
    public static func workflows(scheduling isRemoved: Bool) -> String {
        let restraint = isRemoved ? "" : """
            Do not write cron entries, launch agents, or scripts that nothing will \
            run.\u{20}
            """
        return """
            If I ask for something to happen on its own — on a schedule, or whenever an \
            agent finishes, stops, or asks for something — that is a workflow, and \
            \(AppTool.manageWorkflows) is how you read and write them. \(restraint)Do \
            not create a workflow I did not ask for.
            """
    }

    /// Agents of its own (028), and when not to.
    ///
    /// Only for an agent that has the tools: one another agent started is not told
    /// about tools it was never given. The restraint is the second sentence, for the
    /// reason the workflow line gives — an agent told it can start agents will start
    /// agents — and the limit is said here as well as in the tool's description so it
    /// is known before the first call rather than learned from a refusal.
    public static let helpers = """
        If a piece of the work can go on alongside the rest, you can start up to three \
        agents in this project with \(AppTool.startAgent), and stop or archive them when \
        their part is done. Do not start one for work you could simply do yourself.
        """

    /// Ask, rather than guess or stop.
    ///
    /// The act, and then the reason it is worth doing: the question is held by the
    /// daemon, survives the window being shut, and can be answered from a phone. An
    /// agent that gives up because nobody seemed to be there is giving up on nothing.
    ///
    /// The tool is named where the policy knows its name, and that is a change of mind
    /// with a measurement behind it. This said "your question or form tool" and nothing
    /// else, because the tool is the runtime's and each spells it differently. The live
    /// run of 2026-09-20 showed what that costs: given two defensible answers, Grok
    /// called `search_tool` three times over — "ask the person", "form fields", "raise" —
    /// hunting for something matching those words, failed to recognise `ask_user_question`
    /// as the thing being described, and guessed. It had the tool the whole time.
    ///
    /// So the description gets the name appended to it. Not instead of the act: a runtime
    /// whose name we do not know still gets the sentence that was there before, and an
    /// agent that knows the act by another name can still act on it. `ToolPolicy` is what
    /// supplies the name, so nothing here asks which runtime it is talking to, and FR-008
    /// holds — a tool is named only where the policy has deliberately kept it.
    public static func escalation(named tool: String?) -> String {
        let named = tool.map { " Yours is called `\($0)`." } ?? ""
        return """
            When something is mine to decide — a choice between real alternatives, a \
            missing credential, anything hard to undo — ask me with your question or \
            form tool rather than guessing at it or ending the turn with the question \
            in your reply.\(named) Your question reaches me wherever I am, including on \
            my phone, and it waits for me. A question in the middle of a reply I may \
            not read does not.
            """
    }

    /// The tools a runtime would not let go of, said out loud.
    ///
    /// Generated from the policy rather than written beside it, so the words and the
    /// table cannot drift: a tool that stops being residue stops being mentioned on the
    /// same day, and one that becomes residue is named without anybody remembering to
    /// come here. `nil` where there is nothing to say, which is most runtimes and is
    /// the point — a line naming a tool an agent does not have is worse than no line.
    public static func residue(_ tools: [ResidualTool]) -> String? {
        guard !tools.isEmpty else { return nil }
        let names = tools.map { "`\($0.name)`" }
        let named = names.count == 1
            ? names[0]
            : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        // One sentence per category, in the order the policy lists them, and each said
        // once however many of its tools there are.
        var seen: Set<RemitCategory> = []
        let instead = tools.compactMap { seen.insert($0.category).inserted ? $0.instead : nil }
        return ([named + " \(tools.count == 1 ? "does" : "do") not work in this app."] + instead)
            .joined(separator: " ")
    }

    /// One passage the person changed on a live page, for the note below. Its own
    /// small type here rather than the daemon's, so the wording can be tested without
    /// a daemon in the room; the daemon builds these from what it remembered.
    public struct ArtifactEdit: Hashable, Sendable {
        public var path: String
        public var lines: ClosedRange<Int>
        public var text: String

        public init(path: String, lines: ClosedRange<Int>, text: String) {
            self.path = path
            self.lines = lines
            self.text = text
        }
    }

    /// The most passages the note will quote before telling the agent to read the
    /// file instead. Past this the note is longer than the document.
    public static let artifactEditsQuoted = 20

    /// The document changed under you, and here is how (022 FR-016).
    ///
    /// Sent as a block after the person's next words, the way the briefing is, and
    /// not recorded in the transcript. It quotes each changed passage rather than
    /// naming it, because an agent told "lines 12–15 changed" has to go and read
    /// them, and one that reads its own last version instead will put it back — the
    /// exact thing the last sentence forbids.
    public static func artifactEdited(_ edits: [ArtifactEdit]) -> String? {
        guard !edits.isEmpty else { return nil }
        let quoted = edits.prefix(artifactEditsQuoted)
        var paths: [String] = []
        for edit in quoted where !paths.contains(edit.path) { paths.append(edit.path) }
        var paragraphs: [String] = []
        for path in paths {
            let blocks = quoted.filter { $0.path == path }
                .sorted { $0.lines.lowerBound < $1.lines.lowerBound }
                .map { "Lines \($0.lines.lowerBound)–\($0.lines.upperBound) now read:\n\n```\n\($0.text)\n```" }
            paragraphs.append("Since your last turn I edited `\(path)`. " + blocks.joined(separator: "\n\n"))
        }
        if edits.count > artifactEditsQuoted {
            paragraphs.append("…and more. Read the file before changing it.")
        }
        paragraphs.append("Work from what is there now; do not restore what you wrote before.")
        return paragraphs.joined(separator: "\n\n")
    }

    /// In the order they are sent, for the runtime this agent is on.
    ///
    /// The only place the order is decided and the only place a new line is added. The
    /// one that fires every turn goes first — and since 023 it is also the one that
    /// closes a turn — then the one that fires when a document begins, then the one
    /// whose failure costs most, then the one that is conditional on the person asking
    /// for something recurring, which most turns never do.
    ///
    /// It takes a policy because 015 made two of these lines depend on what the agent
    /// actually has: the workflow line is shorter where the scheduling tools are gone,
    /// and the residue line exists only where something conflicting could not be
    /// removed. A tool the app does not serve yet still gets no line at all.
    ///
    /// `managesAgents` is false for an agent another agent started, which gets no line
    /// about starting agents because it has no tools for it (028).
    public static func lines(for policy: ToolPolicy, managesAgents: Bool = true) -> [String] {
        let schedulingRemoved = policy.removed.contains { $0.category == .standingArrangements }
        return [finish,
                liveDocument,
                escalation(named: policy.escalationTool),
                workflows(scheduling: schedulingRemoved)]
            + (managesAgents ? [helpers] : [])
            + [residue(policy.residue)].compactMap { $0 }
    }

    /// The whole of it, as the one block the daemon appends to a first prompt.
    public static func text(for policy: ToolPolicy, managesAgents: Bool = true) -> String {
        lines(for: policy, managesAgents: managesAgents).joined(separator: "\n\n")
    }
}
