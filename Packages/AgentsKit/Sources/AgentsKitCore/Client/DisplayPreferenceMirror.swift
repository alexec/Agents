import Foundation

/// Keeps a client's own defaults a mirror of the host's display choices (#1033), so the
/// views read them where they always did and every client shows the same.
///
/// The host's map wins: what it says is written into the defaults, and a key it does not
/// have is removed, so the view's own default shows. A change the person makes here is sent
/// to the host, which tells every client. Until the host has been heard from, nothing is
/// sent: a client that has not connected yet has nothing to say about the person's choices.
@MainActor
public final class DisplayPreferenceMirror {
    private let defaults: UserDefaults
    private let send: @MainActor (DaemonAPI.DisplayPreferences) -> Void
    /// The host's map, as last heard or sent.
    public private(set) var preferences: DaemonAPI.DisplayPreferences = [:]
    private var heard = false
    private var applying = false
    nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

    public init(defaults: UserDefaults, send: @escaping @MainActor (DaemonAPI.DisplayPreferences) -> Void) {
        self.defaults = defaults
        self.send = send
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
        self.preferences = preferences
        heard = true
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
        guard heard else { return }
        for (key, value) in changes { preferences[key] = value == .null ? nil : value }
        send(changes)
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
