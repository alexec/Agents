import Foundation

/// A plan is a document, and is put in front of the person the way any document the
/// agent writes is: open in the files pane, filling as it is written, and open again
/// when the agent asks for it to be approved.
///
/// Claude writes its plan to `~/.claude/plans/…md`, outside every folder the agent was
/// given, so `show_file` would refuse it and a phone could not read it. The runtime's
/// own plan is not the agent reaching outside its folders, so the one file is granted
/// here — the file, never the folder beside it, which holds every other session's plans.
extension DaemonCore {
    /// Show the plan being written, the first time it is written to.
    ///
    /// Only while the runtime says the agent is planning, and only Markdown: in plan
    /// mode the one thing written is the plan.
    func notePlanning(_ kind: TranscriptEntry.Kind, agentID: UUID) {
        let call: ToolCall
        switch kind {
        case .toolCall(let c), .toolCallUpdate(let c): call = c
        default: return
        }
        guard isPlanning(agentID) else { return }
        for file in call.markdownWritten where shownPlanFiles[agentID]?.contains(file.path) != true {
            showPlan(file, for: agentID)
        }
    }

    /// Whether the runtime has this agent in plan mode now.
    func isPlanning(_ agentID: UUID) -> Bool {
        guard let agent = agents[agentID] else { return false }
        let id = ModeMemory.modeOption(in: agent.advertisedOptions)?.id ?? "mode"
        return agent.startOptions.values[id]?.stringValue == "plan"
    }

    /// Open the plan beside the conversation, on every window and device, and let a
    /// device read it.
    func showPlan(_ file: ShownFile, for agentID: UUID) {
        shownPlanFiles[agentID, default: []].insert(file.url.standardizedFileURL.resolvingSymlinksInPath().path)
        broadcast(DaemonAPI.Notification.agentShowFile,
                  DaemonAPI.ShowFileNotification(agentID: agentID, file: file))
    }

    /// Whether this exact file is a plan this agent has had shown.
    func isShownPlan(_ url: URL, for agentID: UUID) -> Bool {
        shownPlanFiles[agentID]?.contains(url.path) == true
    }
}
