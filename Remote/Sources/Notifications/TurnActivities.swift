import ActivityKit
import AgentsKitCore
import Foundation

/// The turns sent from this phone or iPad, as one Live Activity on the Lock Screen and in
/// the Dynamic Island (#1657, #2991).
///
/// One in total, not one for each session (Alex, 2026-10-30): started when the person sends
/// a prompt from here, or starts a session from here, while none shows; a prompt to another
/// session joins it. It shows the session that most needs the person, with a count of the
/// others (`TurnActivityContent.summary`). A turn that ends while others run leaves it; the
/// last one to end ends it with Done, or the reason. A session archived or gone leaves at
/// once; the switch in Settings turned off ends it at once.
///
/// Updated from the Remote's own connection while the app runs; the timer counts on its
/// own when the app is suspended, and the line says to open the app once it has not been
/// heard from for a while. The turns it speaks for are kept in the defaults, so a launch
/// finds them again.
///
/// While the app is not running, the control plane updates it by push (#1744): the activity
/// is asked for with a push token, and `tokenChanged` gives the token to the control plane
/// for each session it speaks for, and takes it back for each that leaves. A push carries
/// the phase, the session, the counts and the times, never the words.
@MainActor
final class TurnActivities {
    /// Settings ▸ Notifications ▸ Live Activities.
    static let onKey = "liveActivitiesOn"
    static let onAtFirst = true
    /// The turns the activity speaks for, kept across launches.
    static let turnsKey = "liveActivityTurns"

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

    /// A turn the activity speaks for: when it began, and the runtime and folder it runs in.
    struct Turn: Codable, Hashable {
        var startedAt: Date
        var place: String
    }

    /// Starts asked for from here, by `requestID`, until the session they make is heard of.
    private var startsAsked: Set<UUID> = []
    /// Sessions sent a prompt from here, and when, until the Mac says the turn runs.
    private var sentAt: [UUID: Date] = [:]
    /// The turns the activity speaks for, by session.
    private var turns: [UUID: Turn] = TurnActivities.savedTurns() {
        didSet { if turns != oldValue { Self.save(turns) } }
    }
    /// What watches the activity's push token, and which activity.
    private var watching: (id: String, task: Task<Void, Never>)?

    /// The activity's push token for a session, and when its turn began; nil when the
    /// session left it. The model sends it to the control plane (`clients/setActivityToken`).
    var tokenChanged: (_ agentID: UUID, _ token: Data?, _ startedAt: Date) -> Void = { _, _, _ in }

    var isOn: Bool {
        (WindowDefaults.store.object(forKey: Self.onKey) as? Bool) ?? Self.onAtFirst
    }

    private var mayStart: Bool {
        isOn && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var live: [TurnActivity] {
        TurnActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    private var current: TurnActivity? { live.first }

    /// A prompt went from here to this session: a new turn, or one more for the turn
    /// running, which the daemon queues.
    func sent(to agentID: UUID, in model: AgentsModel) {
        guard mayStart else { return }
        let agent = model.agent(agentID)
        if turns[agentID] != nil, current != nil, agent.map({ $0.state.holdsRuntime }) ?? true {
            // Mid-turn: the same turn, and its time goes on counting.
            return
        }
        let now = Date()
        let turn = Turn(startedAt: now, place: Self.place(of: agent, in: model))
        turns[agentID] = turn
        sentAt[agentID] = now
        if let activity = current {
            refresh(activity, with: model)
            // A new turn: its timer counts from now, by push as well.
            if let token = activity.pushToken { tokenChanged(agentID, token, now) }
            return
        }
        guard let content = summary(with: model) else { return }
        do {
            let activity = try TurnActivity.request(attributes: TurnActivityAttributes(), content: Self.content(content),
                                                    pushType: .token)
            note("live activity: started for \(agentID)")
            watch(activity)
        } catch {
            note("live activity: could not start for \(agentID): \(error)")
            turns.removeAll()
        }
    }

    /// A start went from here; its session is not known until the Mac answers.
    func askedToStart(_ requestID: UUID) {
        guard mayStart else { return }
        startsAsked.insert(requestID)
    }

    /// A session the Mac told us about, after a change to it or to what it asks.
    func changed(_ agentID: UUID, in model: AgentsModel) {
        if let agent = model.agent(agentID), let request = agent.startRequestID, startsAsked.remove(request) != nil {
            sent(to: agentID, in: model)
        }
        guard turns[agentID] != nil, let activity = current else { return }
        refresh(activity, with: model)
    }

    /// The activity against the model, once it is caught up: on connecting, on coming to
    /// the front, and on launch, for one left from before. More than one, from a build
    /// before #2991, are one too many: all but one end at once.
    func settle(with model: AgentsModel) {
        let live = live
        for extra in live.dropFirst() {
            note("live activity: one of \(live.count), ending")
            Task { await Self.end(extra.id, nil, .immediate) }
        }
        guard let activity = live.first else {
            turns.removeAll()
            return
        }
        refresh(activity, with: model)
    }

    /// The switch turned off: it goes, now.
    func endAll() {
        startsAsked.removeAll()
        sentAt.removeAll()
        for activity in TurnActivity.activities {
            ended(activity)
            Task { await Self.end(activity.id, nil, .immediate) }
        }
        turns.removeAll()
    }

    /// The activity's token again, for a control plane that may not have heard it: on each
    /// new link, and for one left from before a launch.
    func sayTokens() {
        guard let activity = current else { return }
        if watching?.id != activity.id {
            watch(activity)
        } else if let token = activity.pushToken {
            for (agentID, turn) in turns { tokenChanged(agentID, token, turn.startedAt) }
        }
    }

    /// Gives each push token the activity is given to the control plane, for each session it
    /// speaks for, until it ends.
    private func watch(_ activity: TurnActivity) {
        let id = activity.id
        let updates = activity.pushTokenUpdates
        watching?.task.cancel()
        watching = (id, Task { [weak self] in
            for await token in updates {
                guard let self else { return }
                for (agentID, turn) in turns { tokenChanged(agentID, token, turn.startedAt) }
            }
        })
    }

    /// The activity ends here: the control plane forgets its token for every session.
    private func ended(_ activity: TurnActivity) {
        if watching?.id == activity.id {
            watching?.task.cancel()
            watching = nil
        }
        if activity.pushToken != nil {
            for (agentID, turn) in turns { tokenChanged(agentID, nil, turn.startedAt) }
        }
    }

    /// A session leaves the activity, which goes on for the others.
    private func leave(_ agentID: UUID, _ activity: TurnActivity) {
        guard let turn = turns.removeValue(forKey: agentID) else { return }
        sentAt.removeValue(forKey: agentID)
        if activity.pushToken != nil { tokenChanged(agentID, nil, turn.startedAt) }
    }

    /// What each turn says now. A session gone or archived is not in it; nor is the end of a
    /// turn before the prompt just sent, which is taken to be working.
    private func contents(with model: AgentsModel) -> [UUID: TurnActivityContent] {
        var out: [UUID: TurnActivityContent] = [:]
        for (agentID, turn) in turns {
            let agent = model.agent(agentID)
            let made = TurnActivityContent.make(agent: agent, needs: model.needs.values, startedAt: turn.startedAt,
                                                place: turn.place)
            if made?.isOver ?? true, let sent = sentAt[agentID], Date().timeIntervalSince(sent) < Self.sendSettles {
                // What it said before this prompt, not the end of this turn; or not heard of yet.
                out[agentID] = .sent(agentID: agentID, title: agent?.title, place: turn.place, at: turn.startedAt)
                continue
            }
            guard let content = made else { continue }
            if !content.isOver { sentAt.removeValue(forKey: agentID) }
            out[agentID] = content
        }
        return out
    }

    private func summary(with model: AgentsModel) -> TurnActivityContent? {
        TurnActivityContent.summary(of: contents(with: model).values)
    }

    private func refresh(_ activity: TurnActivity, with model: AgentsModel) {
        let contents = contents(with: model)
        for agentID in turns.keys where contents[agentID] == nil {
            note("live activity: session \(agentID) gone or archived, leaving")
            leave(agentID, activity)
        }
        let running = contents.filter { !$0.value.isOver }
        guard var next = TurnActivityContent.summary(of: contents.values) else {
            ended(activity)
            turns.removeAll()
            Task { await Self.end(activity.id, nil, .immediate) }
            return
        }
        if next.isOver {
            if next.endedAt.map({ $0 > Date() }) ?? false { next.endedAt = Date() }
            note("live activity: every turn ended, the last \(next.phase.rawValue), ending")
            ended(activity)
            turns.removeAll()
            sentAt.removeAll()
            Task { await Self.end(activity.id, Self.content(next), .after(Date().addingTimeInterval(Self.keptAfterEnd))) }
            return
        }
        for agentID in contents.keys where running[agentID] == nil {
            note("live activity: \(agentID) ended while others run, leaving")
            leave(agentID, activity)
        }
        // Each update moves the stale date on, so a line that is still true is not called old.
        guard next != activity.content.state || activity.activityState == .stale
                || (activity.content.staleDate.map { $0.timeIntervalSinceNow < Self.staleAfter / 2 } ?? true)
        else { return }
        Task { await Self.update(activity.id, Self.content(next)) }
    }

    /// "Claude · api": the runtime and the folder a session runs in.
    private static func place(of agent: Agent?, in model: AgentsModel) -> String {
        let runtime = PoolWords.runtimeName(agent?.runtimeID ?? "")
        let folder = agent.map { model.folder($0.folderPath)?.name ?? $0.folderPath.lastPathComponent } ?? ""
        return [runtime, folder].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func savedTurns() -> [UUID: Turn] {
        guard let data = WindowDefaults.store.data(forKey: turnsKey) else { return [:] }
        return (try? JSONDecoder().decode([UUID: Turn].self, from: data)) ?? [:]
    }

    private static func save(_ turns: [UUID: Turn]) {
        WindowDefaults.store.set(try? JSONEncoder().encode(turns), forKey: turnsKey)
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
