import Foundation

/// The plan in force, as the strip at the head of every client's chat says it (#341).
///
/// The Remote's `CurrentPlanStrip` worked these out for itself; with the window and the
/// page drawing the strip too, they are said once here. The page has its own copy in
/// `Web/src/model/currentPlan.ts`, held to `Fixtures/web/plan/strip.json`.
extension Agent {
    /// The last plan the agent put forward that it has not dropped. A dropped plan is kept
    /// on the record and shown in the transcript where it happened, but it is not what the
    /// agent is doing now, so it is not at the head of the chat.
    public var planInForce: Plan? {
        plans.last { $0.state == .current && !$0.entries.isEmpty }
    }
}

extension Plan {
    /// The step being worked, because that is the one thing worth a line of the screen;
    /// how far along, because that is the other. No plan has a title.
    public var stripSummary: String {
        let done = entries.filter { $0.status == .completed }.count
        let progress = "\(done) of \(entries.count) done"
        guard let doing = entries.first(where: { $0.status == .inProgress }) else {
            return "Plan — \(progress)"
        }
        return "\(doing.content) — \(progress)"
    }
}
