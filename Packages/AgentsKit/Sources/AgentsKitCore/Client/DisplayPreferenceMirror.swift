import Foundation

/// Keeps a client's own defaults a mirror of the host's display choices (#1033), so the
/// views read them where they always did and every client shows the same.
///
/// The host's map wins: what it says is written into the defaults, and a key it does not
/// have is removed, so the view's own default shows. A change the person makes here is sent
/// to the host, which tells every client. Until the host has been heard from, nothing is
/// sent: a client that has not connected yet has nothing to say about the person's choices.
///
/// A change shows at once and stays pending until the host answers (#4814): a map the host
/// sends meanwhile, for another change, does not undo it, and a change the host did not
/// take goes back to what the host has, with one line that says so.
@MainActor
public final class DisplayPreferenceMirror {
    private let defaults: UserDefaults
    private let send: @MainActor (DaemonAPI.DisplayPreferences) async throws -> DaemonAPI.DisplayPreferences
    private let failed: @MainActor (any Error) -> Void
    /// The host's map as last heard, with the changes still on their way drawn over it.
    public private(set) var preferences: DaemonAPI.DisplayPreferences = [:]
    /// The host's own map, as last heard.
    private var hosts: DaemonAPI.DisplayPreferences = [:]
    /// Each key changed here and not yet answered, with the change that set it last.
    private var pending: [String: (value: JSONValue, change: Int)] = [:]
    private var changeCount = 0
    private var heard = false
    private var applying = false
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    /// The line a client says when the host did not take a change (#4814).
    public static func failure(_ reason: String) -> String { AgentWrite.failure("save the setting", reason) }

    /// `send` gives the host the changes and answers its whole map; `failed` is told why a
    /// change did not go, after it has been put back.
    public init(defaults: UserDefaults,
                send: @escaping @MainActor (DaemonAPI.DisplayPreferences) async throws -> DaemonAPI.DisplayPreferences,
                failed: @escaping @MainActor (any Error) -> Void) {
        self.defaults = defaults
        self.send = send
        self.failed = failed
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultsChanged() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// What the host said: `preferences/get` at connect, or `preferences/changed`.
    public func hostSaid(_ preferences: DaemonAPI.DisplayPreferences) {
        hosts = preferences
        heard = true
        draw()
    }

    /// The host's map with what is pending over it, into the defaults.
    private func draw() {
        var preferences = hosts
        for (key, change) in pending { preferences[key] = change.value == .null ? nil : change.value }
        self.preferences = preferences
        applying = true
        defer { applying = false }
        for (key, kind) in DisplayPreference.mirrored {
            switch (kind, preferences[key]) {
            case (.bool, .bool(let value)?):
                if defaults.object(forKey: key) as? Bool != value { defaults.set(value, forKey: key) }
            case (.string, .string(let value)?):
                if defaults.string(forKey: key) != value { defaults.set(value, forKey: key) }
            case (.int, .int(let number)?):
                if defaults.object(forKey: key) as? Int != number { defaults.set(number, forKey: key) }
            default:
                if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            }
        }
    }

    /// Set some of the host's choices that are not kept in the defaults (`startChoices`).
    public func set(_ changes: DaemonAPI.DisplayPreferences) {
        guard heard, !changes.isEmpty else { return }
        changeCount += 1
        let change = changeCount
        for (key, value) in changes { pending[key] = (value, change) }
        draw()
        Task { [weak self] in
            guard let self else { return }
            do {
                let said = try await send(changes)
                settle(changes, change)
                hostSaid(said)
            } catch {
                settle(changes, change)
                draw()
                failed(error)
            }
        }
    }

    /// One change answered: its keys are the host's again, unless a later change set them.
    private func settle(_ changes: DaemonAPI.DisplayPreferences, _ change: Int) {
        for key in changes.keys where pending[key]?.change == change { pending[key] = nil }
    }

    private func defaultsChanged() {
        guard heard, !applying else { return }
        var changes: DaemonAPI.DisplayPreferences = [:]
        for (key, kind) in DisplayPreference.mirrored {
            let local: JSONValue? = switch kind {
            case .bool: (defaults.object(forKey: key) as? Bool).map(JSONValue.bool)
            case .string: defaults.string(forKey: key).map(JSONValue.string)
            case .int: (defaults.object(forKey: key) as? Int).map(JSONValue.int)
            }
            guard local != preferences[key] else { continue }
            changes[key] = local ?? .null
        }
        if !changes.isEmpty { set(changes) }
    }
}
