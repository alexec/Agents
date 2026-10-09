import Foundation

/// A turn the agent did not account for, accounted for by the app (#479).
extension DaemonCore {
    /// Put an outcome, a sentence and — where nothing has named the conversation — a
    /// title on an agent whose clean ending said nothing about itself. Nothing is asked
    /// of the agent, and no prompt is sent: what the row shows comes from how the turn
    /// stopped, whether a question is open, and what the agent last said.
    ///
    /// A `finish_turn` call in the turn wins: this only writes where none landed.
    func deriveEnding(agentID: UUID, reason: EndedReason, closingWords words: String,
                      agentRecordedAnEnding: Bool) {
        // An outcome given with no words takes the agent's closing words, however the
        // turn then stopped: the app cancels one whose runtime holds on after the call.
        if unwordedReports.remove(agentID) != nil, agentRecordedAnEnding,
           var agent = agents[agentID], var report = agent.report {
            report.message = DerivedEnding.message(closingWords: words, outcome: report.outcome)
            agent.report = report
            changed(agent)
            return
        }
        guard reason == .endTurn, !agentRecordedAnEnding, var agent = agents[agentID] else { return }
        // A report this turn began under is the last turn's, not this one's (#149).
        let reported = agent.report != nil && agent.report != reportBeforeTurn[agentID]
        reportBeforeTurn.removeValue(forKey: agentID)
        if !reported {
            let questionOpen = pendingPermissions.values.contains { $0.agentID == agentID }
                || elicitations.values.contains { $0.agentID == agentID }
            let report = DerivedEnding.report(closingWords: words, questionOpen: questionOpen, at: now())
            agent.report = report
            if isWatched(agentID) { agent.reportSeenAt = report.at }
        }
        if agent.title == nil, let first = lastPrompts[agentID], first.from == .person,
           let title = DerivedEnding.title(fromPrompt: first.text) {
            agent.title = title
        }
        changed(agent)
    }
}
