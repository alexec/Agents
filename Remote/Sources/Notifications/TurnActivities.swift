import ActivityKit
import AgentsKitCore
import Foundation

/// A turn sent from this phone or iPad, as a Live Activity on the Lock Screen and in the
/// Dynamic Island (#1657).
///
/// Started when the person sends a prompt from here, or starts a session from here; at most
/// one for each session. Updated from the Remote's own connection while the app runs, with
/// the words `TurnActivityContent` works out; the timer counts on its own when the app is
/// suspended, and the line says to open the app once it has not been heard from for a
/// while. Ended with Done, or the reason, when the turn ends; at once when the session is
/// archived or gone, or the switch in Settings is turned off.
///
/// While the app is not running, the control plane updates it by push (#1744): each
/// activity is asked for with a push token, and `tokenChanged` gives the token to the
/// control plane, and takes it back when the activity ends. A push carries the phase and
/// the times, never the words; the attributes keep the title it started with.
@MainActor
final class TurnActivities {
    /// Settings ▸ Notifications ▸ Live Activities.
    static let onKey = "liveActivitiesOn"
    static let onAtFirst = true

    /// How long a working activity's line is trusted without an update: the Lock Screen
    /// then says to open the app.
    static let staleAfter: TimeInterval = 10 * 60
    /// How long an ended one stays on the Lock Screen. The end's banner (#1170) says it as
    /// well, so not the system's four hours.
    static let keptAfterEnd: TimeInterval = 15 * 60
    /// How long a turn just sent is taken to be working, whatever the session last said: the
    /// Mac's word that it is running may come after the send's answer.
    static let sendSettles: TimeInterval = 60

    private typealias TurnActivity = Activity<TurnActivityAttributes>

    /// Starts asked for from here, by `requestID`, until the session they make is heard of.
    private var startsAsked: Set<UUID> = []
    /// Sessions sent a prompt from here, and when, until the Mac says the turn runs.
    private var sentAt: [UUID: Date] = [:]
    /// What watches each activity's push token, by activity id.
    private var watching: [String: Task<Void, Never>] = [:]

    /// An activity's push token for a session, and when its turn began; nil when it ended.
    /// The model sends it to the control plane (`clients/setActivityToken`).
    var tokenChanged: (_ agentID: UUID, _ token: Data?, _ startedAt: Date) -> Void = { _, _, _ in }

    var isOn: Bool {
        (WindowDefaults.store.object(forKey: Self.onKey) as? Bool) ?? Self.onAtFirst
    }

    private var mayStart: Bool {
        isOn && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private func activity(for agentID: UUID) -> TurnActivity? {
        TurnActivity.activities.first {
            $0.attributes.agentID == agentID && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    /// A prompt went from here to this session: a new turn, or one more for the turn
    /// running, which the daemon queues.
    func sent(to agent: Agent?, id agentID: UUID, project: String) {
        guard mayStart else { return }
        let now = Date()
        if let running = activity(for: agentID), !running.content.state.isOver,
           agent.map({ $0.state.holdsRuntime }) ?? true {
            // Mid-turn: the same turn, and its time goes on counting.
            return
        }
        sentAt[agentID] = now
        let content = TurnActivityContent.sent(title: agent?.title, at: now)
        if let existing = activity(for: agentID) {
            Task { await Self.update(existing.id, Self.content(content)) }
            // A new turn: its timer counts from now, by push as well.
            if let token = existing.pushToken { tokenChanged(agentID, token, now) }
            return
        }
        let attributes = TurnActivityAttributes(agentID: agentID,
                                                runtime: PoolWords.runtimeName(agent?.runtimeID ?? ""),
                                                project: project, title: agent?.title)
        do {
            let activity = try TurnActivity.request(attributes: attributes, content: Self.content(content), pushType: .token)
            note("live activity: started for \(agentID)")
            watch(activity)
        } catch {
            note("live activity: could not start for \(agentID): \(error)")
        }
    }

    /// A start went from here; its session is not known until the Mac answers.
    func askedToStart(_ requestID: UUID) {
        guard mayStart else { return }
        startsAsked.insert(requestID)
    }

    /// A session the Mac told us about, after a change to it or to what it asks.
    func changed(_ agentID: UUID, in model: AgentsModel) {
        let agent = model.agent(agentID)
        if let agent, let request = agent.startRequestID, startsAsked.remove(request) != nil {
            sent(to: agent, id: agentID, project: model.project(agent.projectFolder)?.name
                 ?? agent.projectFolder.lastPathComponent)
        }
        guard let activity = activity(for: agentID) else { return }
        update(activity, agent: agent, needs: model.needs.values)
    }

    /// Every activity against the model, once it is caught up: on connecting, on coming to
    /// the front, and on launch, for those left from before.
    func settle(with model: AgentsModel) {
        for activity in TurnActivity.activities
        where activity.activityState == .active || activity.activityState == .stale {
            update(activity, agent: model.agent(activity.attributes.agentID), needs: model.needs.values)
        }
    }

    /// The switch turned off: every one goes, now.
    func endAll() {
        startsAsked.removeAll()
        sentAt.removeAll()
        for activity in TurnActivity.activities {
            ended(activity)
            Task { await Self.end(activity.id, nil, .immediate) }
        }
    }

    /// Every live activity's token again, for a control plane that may not have heard it:
    /// on each new link, and for those left from before a launch.
    func sayTokens() {
        for activity in TurnActivity.activities
        where activity.activityState == .active || activity.activityState == .stale {
            if watching[activity.id] == nil {
                watch(activity)
            } else if let token = activity.pushToken {
                tokenChanged(activity.attributes.agentID, token, activity.content.state.startedAt)
            }
        }
    }

    /// Gives each push token the activity is given to the control plane, until it ends.
    private func watch(_ activity: TurnActivity) {
        let id = activity.id
        let updates = activity.pushTokenUpdates
        watching[id]?.cancel()
        watching[id] = Task { [weak self] in
            for await token in updates {
                guard let self, let activity = TurnActivity.activities.first(where: { $0.id == id }) else { return }
                tokenChanged(activity.attributes.agentID, token, activity.content.state.startedAt)
            }
        }
    }

    /// The activity ends here: the control plane forgets its token.
    private func ended(_ activity: TurnActivity) {
        watching.removeValue(forKey: activity.id)?.cancel()
        if activity.pushToken != nil {
            tokenChanged(activity.attributes.agentID, nil, activity.content.state.startedAt)
        }
    }

    private func update(_ activity: TurnActivity, agent: Agent?, needs: some Sequence<Need>) {
        let agentID = activity.attributes.agentID
        let current = activity.content.state
        guard var next = TurnActivityContent.make(agent: agent, needs: needs, startedAt: current.startedAt) else {
            sentAt.removeValue(forKey: agentID)
            note("live activity: session \(agentID) gone or archived, ending")
            ended(activity)
            Task { await Self.end(activity.id, nil, .immediate) }
            return
        }
        if next.isOver, let sent = sentAt[agentID], Date().timeIntervalSince(sent) < Self.sendSettles {
            // What it said before this prompt, not the end of this turn.
            return
        }
        sentAt.removeValue(forKey: agentID)
        if next.isOver {
            if next.endedAt.map({ $0 > Date() }) ?? false { next.endedAt = Date() }
            note("live activity: \(agentID) \(next.phase.rawValue), ending")
            ended(activity)
            Task { await Self.end(activity.id, Self.content(next), .after(Date().addingTimeInterval(Self.keptAfterEnd))) }
            return
        }
        // Each update moves the stale date on, so a line that is still true is not called old.
        guard next != current || activity.activityState == .stale
                || (activity.content.staleDate.map { $0.timeIntervalSinceNow < Self.staleAfter / 2 } ?? true)
        else { return }
        Task { await Self.update(activity.id, Self.content(next)) }
    }

    // An `Activity` is not `Sendable`, so a task is handed its id and finds it again.

    private nonisolated static func update(_ id: String, _ content: ActivityContent<TurnActivityContent>) async {
        await TurnActivity.activities.first { $0.id == id }?.update(content)
    }

    private nonisolated static func end(_ id: String, _ content: ActivityContent<TurnActivityContent>?,
                                        _ policy: ActivityUIDismissalPolicy) async {
        await TurnActivity.activities.first { $0.id == id }?.end(content, dismissalPolicy: policy)
    }

    private static func content(_ state: TurnActivityContent) -> ActivityContent<TurnActivityContent> {
        ActivityContent(state: state, staleDate: state.isOver ? nil : Date().addingTimeInterval(staleAfter),
                        relevanceScore: state.asks ? 100 : 50)
    }
}
