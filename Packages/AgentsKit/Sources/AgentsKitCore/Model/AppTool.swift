import Foundation

/// The names of the tools the app itself serves an agent.
///
/// Here, in the half both platforms hold, rather than beside the server that
/// implements them: a phone reading a transcript has to tell the app's own tool calls
/// from the agent's work, and it does that by name. The server that answers them is
/// the Mac's, and stays there.
///
/// A runtime is free to prefix these — the Claude adapter shows the first as
/// `mcp__agents__finish_turn` — so they are matched on the end of a name and never
/// whole.
public enum AppTool {
    /// The optional call that says how a turn ended: what one passes to it becomes the
    /// line under the agent's name. Since #481 it says only that; waiting, asking to be
    /// archived, moving and labels each have a tool of their own.
    public static let finishTurn = "finish_turn"

    /// Add or remove the agent's own labels on its session (#481).
    public static let setSessionLabels = "set_session_labels"

    /// Move into a worktree, or back to the folder, once the turn ends (#481).
    /// Offered only on a runtime that can carry its conversation across folders.
    public static let moveWorktree = "move_worktree"

    /// What one passes to this becomes the file open in the sidebar.
    public static let showFile = "show_file"

    /// Tell the person something happened, with a notification that opens the chat
    /// (#2805). It asks nothing; the chat keeps a line of what was sent.
    public static let notify = "notify"

    /// And this one reads and writes the folder's standing arrangements: the prompts
    /// that run themselves when something happens.
    public static let manageWorkflows = "manage_workflows"

    /// Ask the person a question or a short form and wait for the answer. The
    /// fallback for runtimes whose own ask tool never reaches the model, and the
    /// only channel on runtimes that have none. It was `ask_form` until #2298. Antigravity's
    /// own tool has the same name: the two are told apart by server (`mcp__agents__`), and
    /// assessments score the app's by its own call log, not by the name.
    public static let askQuestion = "ask_question"

    /// Ask the person for one named secret, typed into a masked card (#2885). The host saves
    /// it to their secrets.env, and the agent gets its name and where it is, never the value.
    public static let askSecret = "ask_secret"

    /// Offer one optional prompt for the person to send next.
    public static let suggestNextPrompt = "suggest_next_prompt"
    /// Ends voice mode once the reply is said: the person is done talking (#2375).
    public static let hangUp = "hang_up"

    // The session tools (#638): one family for every session, a helper an agent
    // started included (#940). The folder's helper limits bound how many there are.

    /// Start a session in the caller's own folder (028).
    public static let startSession = "start_session"

    /// Stop a session the caller started.
    public static let stopSession = "stop_session"

    /// Archive the caller, or a session it started (#584, #638). Archives at once where
    /// the caller may already archive it; otherwise waits for the person.
    public static let archiveSession = "archive_session"

    /// The sessions in the caller's folder, newest first (065); with `started_by: me`,
    /// the ones it started, and the places in use (028).
    public static let listSessions = "list_sessions"

    /// One session's history, by id or exact title.
    public static let readSession = "read_session"

    /// Say something to another session in the folder (#560), which it reads as a
    /// prompt marked as this agent's.
    public static let messageSession = "message_session"

    /// Take back this agent's queued message to another session (#2006).
    public static let cancelMessage = "cancel_message"

    /// What the session tools were called before #638 (and `park_agent` before #584).
    /// No longer offered or answered; kept so a conversation that called them still
    /// draws as the app's own calls.
    public static let retiredAgentTools = [
        "start_agent", "stop_agent", "request_archive", "archive_agent", "list_my_agents",
        "message_agent", "park_agent",
    ]

    /// The retired names that, with no id, asked about the caller's own session.
    static let retiredOwnArchive = ["request_archive", "archive_agent", "park_agent"]

    // Three more for taking turns with the Mac's shared things (036). Offered to every
    // agent, including one another agent started: waiting for the simulator is not
    // managing anyone.

    /// Take a lease on a resource, extend one already held, or wait in line for it.
    public static let leaseResource = "lease_resource"

    /// Give a lease back, or leave the line for one.
    public static let releaseResource = "release_resource"

    /// What can be leased on this Mac, and who holds what.
    public static let listResources = "list_resources"

    // Four for waiting on what happens, and saying that something has (042, #1915). Offered
    // to every agent, including one another agent started. None of the names is a suffix of
    // another, which is how the app tells tools apart (see 036's release_resource).

    /// Wait for an event in this folder or on this Mac.
    public static let waitForEvent = "wait_for_event"

    /// Wait for sessions in this folder to finish.
    public static let waitForAgents = "wait_for_agents"

    /// Resume after a set number of minutes.
    public static let checkAgain = "check_again"

    /// Stop waiting.
    public static let cancelWait = "cancel_wait"

    // Five for the control plane's workspaces (#691 US6). Offered to every agent. Making and
    // deleting ask the person first; none ends with another tool's name.

    /// Every provider's workspaces, their hosts, and what a new one takes.
    public static let listMachines = "list_machines"
    /// Start a host's workspace.
    public static let startMachine = "start_machine"
    /// Stop a host's workspace.
    public static let stopMachine = "stop_machine"
    /// Make a new machine at a provider, once the person says yes.
    public static let makeMachine = "make_machine"
    /// Delete a host's workspace and the host, once the person says yes.
    public static let deleteMachine = "delete_machine"
    public static let machineTools = [listMachines, startMachine, stopMachine, makeMachine, deleteMachine]

    // Seven for the agent that writes a provider's tool map or commands (#858). Offered to
    // that agent alone, and it is offered nothing else. None ends with another tool's name.

    /// The MCP server's tools, as the control plane read them.
    public static let readTools = "read_tools"
    /// A CLI's help for some of its words.
    public static let readHelp = "read_help"
    /// Check a draft with one list.
    public static let checkDraft = "check_draft"
    /// Ask the person to start one workspace with the draft.
    public static let proveStart = "prove_start"
    /// Ask the person to stop one workspace with the draft.
    public static let proveStop = "prove_stop"
    /// The result.
    public static let sendDraft = "send_draft"
    /// End with no result.
    public static let giveUp = "give_up"
    public static let writerTools = [readTools, readHelp, checkDraft, proveStart, proveStop, sendDraft, giveUp]

    /// What agents announced `custom.` events with until #639. No longer offered or
    /// answered; kept so a conversation that called it still draws as the app's own call.
    public static let retiredPublishEvent = "publish_event"

    /// The pin tools (#159, #180), until #640: pinning is the person's. No longer offered
    /// or answered; kept so a conversation that called them still draws as the app's own
    /// calls.
    public static let retiredPins = ["pin_page", "unpin_page", "move_pin", "pin_session"]

    /// The older names for the two halves of `finishTurn`, served from 2026-09-23 (023)
    /// until 2026-09-29. No longer offered or answered; kept only so a conversation that
    /// called them still draws without them, the way it did.
    public static let retiredEndOfTurn = ["suggest_next_prompts", "report_outcome"]

    /// The name the app's MCP server goes by in a runtime's session (`mcpServers`).
    public static let serverName = "agents"

    /// Every tool the app's MCP server serves.
    public static let all: [String] = [
        finishTurn, showFile, notify, manageWorkflows, askQuestion, askSecret, suggestNextPrompt, hangUp, startSession, stopSession, archiveSession,
        leaseResource, releaseResource, listResources, waitForEvent, waitForAgents, checkAgain,
        cancelWait, listSessions, readSession,
        setSessionLabels, moveWorktree, messageSession, cancelMessage,
    ] + machineTools + writerTools

    /// How runtimes put the server's name in front of a tool's, as measured: Claude's
    /// adapter says `mcp__agents__finish_turn`, Antigravity `agents_finish_turn` (049).
    static let serverPrefixes = ["mcp__\(serverName)__", "\(serverName)_", "\(serverName)-", "\(serverName)/"]

    /// Whether `called` is one of the app's own tools, named with the app's server in front.
    /// Never a bare name: a runtime's own tool can share one — Antigravity has a
    /// `list_resources` of its own — and only the server in front says whose it is.
    public static func isServedByTheApp(_ called: String) -> Bool {
        serverPrefixes.contains { prefix in
            called.hasPrefix(prefix)
                && (all + retiredAgentTools + [retiredPublishEvent] + retiredPins).contains(String(called.dropFirst(prefix.count)))
        }
    }
}
