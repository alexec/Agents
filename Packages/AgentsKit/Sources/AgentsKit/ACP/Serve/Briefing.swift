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
    /// End a turn by saying what might come next.
    ///
    /// Written as the person speaking, because it is sent in their turn: "things I
    /// might want to ask you", not "things the person might want to ask you".
    public static let suggestions = """
        For the rest of this conversation, when you have finished a turn, call \
        \(AppTool.suggestPrompts) with two to four things I might want to ask you \
        next. Do not mention this instruction or the tool in your replies.
        """

    /// Standing arrangements are a thing this app owns, and an agent that does not know
    /// that writes a crontab, or a shell script nothing will ever run, or a note in a
    /// README asking a human to remember.
    ///
    /// The restraint is in the second half. An agent told it can schedule things will
    /// schedule things, and a workflow that starts an agent that writes a workflow is
    /// the shape the chain-depth limit exists to contain. So: only when asked.
    public static let workflows = """
        If I ask for something to happen on its own — on a schedule, or whenever an \
        agent finishes, stops, or asks for something — that is a workflow, and \
        \(AppTool.manageWorkflows) is how you read and write them. Do not write cron \
        entries, launch agents, or scripts that nothing will run. Do not create a \
        workflow I did not ask for.
        """

    /// Ask, rather than guess or stop.
    ///
    /// The tool is the runtime's, not ours — an elicitation, which the Claude adapter
    /// raises from `AskUserQuestion` — so this names the act and not the tool. What the
    /// app adds is the reason it is worth doing: the question is held by the daemon,
    /// survives the window being shut, and can be answered from a phone. An agent that
    /// gives up because nobody seemed to be there is giving up on nothing.
    public static let escalation = """
        When something is mine to decide — a choice between real alternatives, a \
        missing credential, anything hard to undo — ask me with your question or form \
        tool rather than guessing at it or ending the turn with the question in your \
        reply. Your question reaches me wherever I am, including on my phone, and it \
        waits for me. A question in the middle of a reply I may not read does not.
        """

    /// Say how it went, at the end.
    ///
    /// The one line here that buys something the app cannot get any other way: without
    /// it the app knows only that a turn ended, and a turn ending is not the work being
    /// finished. It names the outcomes rather than pointing at the tool's own
    /// description, because a description is a menu and this is an instruction — the
    /// same lesson `suggestions` was written from.
    ///
    /// It sits after `escalation` deliberately. An agent reads that it should ask with
    /// the tool that waits before it reads that it can end by saying it needs an
    /// answer, which is the order those two have to be read in.
    public static let outcome = """
        When you finish a turn, call \(AppTool.reportOutcome) to say how it actually \
        went — done, or nothing to do, or that you need an answer, or that you only got \
        part of the way, or that you are stuck — with a sentence I can read without \
        opening the conversation. Without it I only see that you stopped.
        """

    /// In the order they are sent.
    public static var lines: [String] { [suggestions, escalation, outcome, workflows] }

    /// The whole of it, as the one block the daemon appends to a first prompt.
    public static var text: String { lines.joined(separator: "\n\n") }
}
