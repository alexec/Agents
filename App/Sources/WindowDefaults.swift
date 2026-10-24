import AgentsKitCore
import Foundation

/// Where every window preference is kept (#1029): the app's own defaults for the person's
/// window, and a domain of its own for any other copy of the app.
///
/// Every copy shares one bundle id, so one container and one defaults domain. A walk's
/// window (run-app, `--walk <name>`) reads the standard root, so the root alone does not
/// tell it apart; a branch build on another root (`--root`, `AGENTS_ROOT`) does. Either
/// keeps its keys in `<bundle id>.walk.<name>` or `<bundle id>.root.<name>`, and nothing
/// it chooses (a folder, a sidebar width, the appearance) reaches the person's window.
/// No key in App/ goes to `UserDefaults.standard` or a bare `@AppStorage` but through
/// here: `scripts/check-window-defaults.py` fails the build on one.
enum WindowDefaults {
    /// Nil for the person's window, else the domain this copy keeps to.
    static let scratchDomain: String? = domain(walk: ControlConfig.walk, locations: .default,
                                               bundle: Bundle.main.bundleIdentifier ?? "com.alexecollins.agents")

    nonisolated(unsafe) static let store: UserDefaults = {
        guard let scratchDomain, let own = UserDefaults(suiteName: scratchDomain) else { return .standard }
        own.set(Date(), forKey: launchedKey)
        return own
    }()

    static func domain(walk: String?, locations: StoreLocations, bundle: String) -> String? {
        if let walk { return "\(bundle)\(walkInfix)\(walk)" }
        guard !locations.isStandard else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let name = String(locations.name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return "\(bundle)\(rootInfix)\(name)"
    }

    private static let walkInfix = ".walk."
    private static let rootInfix = ".root."
    private static let launchedKey = "scratch.launched"
    /// A root's copy not opened for this long is gone: the window cannot look at a root
    /// outside its container to see, so it goes by when that copy last ran.
    static let rootKept: TimeInterval = 7 * 24 * 3600

    /// Run once at launch, by every copy, off the main thread: the domains of walks whose
    /// folder has gone (`stop.sh` removes it) and of roots not run for `rootKept` go.
    /// The copy's own domain is never one of them.
    static func sweep(now: Date = Date()) {
        let bundle = Bundle.main.bundleIdentifier ?? "com.alexecollins.agents"
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let preferences = library.appendingPathComponent("Preferences", isDirectory: true)
        let walks = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents/walks", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? []  // store-ok: the container's own Preferences
        for file in files where file.hasSuffix(".plist") {
            let name = String(file.dropLast(".plist".count))
            guard name != scratchDomain else { continue }
            if name.hasPrefix(bundle + walkInfix) {
                let walk = walks.appendingPathComponent(String(name.dropFirst((bundle + walkInfix).count)))
                if FileManager.default.fileExists(atPath: walk.path) { continue }  // store-ok: a walk's folder in the container
            } else if name.hasPrefix(bundle + rootInfix) {
                let launched = UserDefaults(suiteName: name)?.object(forKey: launchedKey) as? Date ?? .distantPast
                if now.timeIntervalSince(launched) < rootKept { continue }
            } else {
                continue
            }
            // Emptied by the first, and the empty file left behind goes with the second.
            UserDefaults.standard.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: preferences.appendingPathComponent(file))  // store-ok: the container's own Preferences
        }
    }
}
