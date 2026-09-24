import Foundation

/// Where half-typed prompts are kept across a relaunch (025 US5).
///
/// In `UserDefaults`, where the window already keeps the selected project and the
/// sidebar's width — not under the daemon's root, which promises the daemon is its only
/// writer. A draft is not the work: it is what one person has half-typed in front of one
/// app, and the daemon is never told about it.
///
/// The defaults are handed in, as `SidebarFrame` takes them, so the rules can be tested
/// against a domain of their own.
///
/// **Scoped by root.** A copy of the app on a scratch root has the same bundle id as the
/// ordinary one, so it shares its defaults — and the start form is one key for the whole
/// app. Unscoped, every scratch run would write its folder and runtime over the real
/// app's, and the next ordinary launch would put them back. So a store for any other root
/// keeps to a scope of its own, and never reads, writes or sweeps outside it.
public struct DraftStore {
    /// Every key any store writes starts with this.
    public static let prefix = "draft."
    /// How many bytes held by value a draft may carry. A pasted screenshot is the case in
    /// mind: `UserDefaults` is not where megabytes belong, so over this the words and the
    /// files sent by reference are kept, the rest is not, and the draft says so.
    public static let inlineCap = 512 * 1024
    /// A draft untouched this long is let go. Twenty abandoned prompts should not become
    /// permanent, and this is also what catches a conversation that has gone altogether.
    public static let horizon: TimeInterval = 30 * 24 * 60 * 60

    private let defaults: UserDefaults
    /// Where this store's keys live: `draft.` for the ordinary root, `draft.root:<name>.`
    /// for any other. The ordinary scope's keys go on with `agent.`, `new.` or `start`,
    /// never `root:`, so no scope can mistake another's keys for its own.
    public let scopePrefix: String

    /// - Parameter scope: the root's name when it is not the ordinary one; `nil` when it is.
    public init(defaults: UserDefaults = .standard, scope: String? = nil) {
        self.defaults = defaults
        scopePrefix = Self.prefix + (scope.map { "root:\($0)." } ?? "")
    }

    /// The `UserDefaults` key a draft lives under, in this store.
    public func defaultsKey(for key: DraftKey) -> String { scopePrefix + key.name }

    private var startKey: String { scopePrefix + "start" }

    // MARK: The words

    public func draft(for key: DraftKey) -> Draft? {
        guard let data = defaults.data(forKey: defaultsKey(for: key)) else { return nil }
        guard let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
            // Discarded rather than migrated, and rather than failed over: nothing about
            // a draft is worth an error, and one left in place fails again next launch.
            defaults.removeObject(forKey: defaultsKey(for: key))
            return nil
        }
        return draft
    }

    /// Keep this draft, or forget it if there is nothing in it.
    public func save(_ draft: Draft, for key: DraftKey) {
        guard !draft.isEmpty else {
            clear(key)
            return
        }
        let kept = draft.inlineBytes > Self.inlineCap ? draft.withoutInlineData() : draft
        guard let data = try? JSONEncoder().encode(kept) else { return }
        defaults.set(data, forKey: defaultsKey(for: key))
    }

    public func clear(_ key: DraftKey) {
        defaults.removeObject(forKey: defaultsKey(for: key))
    }

    /// Let go of drafts that are over.
    ///
    /// Only what is known to be over: a draft whose conversation is *known and archived*,
    /// and any draft untouched for `horizon`. An agent this has not heard of costs
    /// nothing — the sweep can run before the agent list has arrived, and an absence then
    /// is not evidence of anything.
    public func sweep(archived: Set<UUID>, now: Date) {
        let archivedKeys = Set(archived.map { defaultsKey(for: .agent($0)) })
        let agents = scopePrefix + DraftKey.agentPrefix, newAgents = scopePrefix + DraftKey.newAgentPrefix
        // Only this scope's drafts: another root's, and the start form, are not this
        // sweep's to judge.
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(agents) || key.hasPrefix(newAgents) {
            if archivedKeys.contains(key) {
                defaults.removeObject(forKey: key)
                continue
            }
            guard let data = defaults.data(forKey: key),
                  let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
                defaults.removeObject(forKey: key)
                continue
            }
            if now.timeIntervalSince(draft.editedAt) >= Self.horizon {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: The start form

    public func startDraft() -> StartDraft? {
        guard let data = defaults.data(forKey: startKey) else { return nil }
        guard let form = try? JSONDecoder().decode(StartDraft.self, from: data) else {
            defaults.removeObject(forKey: startKey)
            return nil
        }
        return form
    }

    public func saveStartDraft(_ form: StartDraft) {
        guard let data = try? JSONEncoder().encode(form) else { return }
        defaults.set(data, forKey: startKey)
    }
}
