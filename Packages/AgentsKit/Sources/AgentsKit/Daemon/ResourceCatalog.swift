import CoreServices
import Foundation
import AgentsKitCore

/// Something the Mac has that one agent should use at a time (036 US6).
public struct FoundResource: Sendable, Hashable {
    public var name: ResourceName
    public var kind: ResourceKind
    public var displayName: String
    /// Other things an agent might call it: a simulator's UDID alone, or its display
    /// name; a browser's display name. Compared the way names are.
    public var aliases: [String]

    public init(name: ResourceName, kind: ResourceKind, displayName: String, aliases: [String] = []) {
        self.name = name
        self.kind = kind
        self.displayName = displayName
        self.aliases = aliases
    }

    public static let screen = FoundResource(name: .screen, kind: .screen,
                                             displayName: "Screen, mouse and keyboard")
}

/// What can say what the Mac has. The daemon asks the real one; a test gives a list.
public protocol ResourceFinding: Sendable {
    func found() async -> [FoundResource]
}

extension ResourceFinding {
    /// What a name an agent gave comes to: a found resource, by its key or any alias,
    /// or else a resource of the agent's own naming (FR-013).
    ///
    /// An alias shared by two found resources resolves to neither. Two simulators with
    /// the same name and system are two resources, and guessing between them would put
    /// two agents on one device while each believed it had its own.
    public func resolve(_ given: String) async -> FoundResource? {
        guard let name = ResourceName(given) else { return nil }
        let found = await found()
        if let exact = found.first(where: { $0.name == name }) { return exact }
        let matching = found.filter { $0.aliases.contains { ResourceName($0) == name } }
        if matching.count == 1 { return matching[0] }
        return FoundResource(name: name, kind: .named,
                             displayName: given.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The Mac's screen, its simulators and its browsers, looked up at most once a minute.
///
/// Off the daemon's actor: `simctl` takes a second or so when cold, and nothing about
/// a lease should wait for that while holding the lock every other agent needs.
public actor ResourceCatalog: ResourceFinding {
    private var cache: (at: Date, list: [FoundResource])?
    private let freshFor: TimeInterval

    public init(freshFor: TimeInterval = 60) {
        self.freshFor = freshFor
    }

    public func found() async -> [FoundResource] {
        if let cache, Date().timeIntervalSince(cache.at) < freshFor { return cache.list }
        let simulators = Self.simulators(from: await Self.simctlDevices())
        let list = [FoundResource.screen] + simulators + Self.browsers()
        cache = (Date(), list)
        return list
    }

    // MARK: Simulators

    /// `xcrun simctl list devices available -j`, or nothing. A Mac without Xcode has no
    /// simulators, and that is not worth saying.
    ///
    /// Ended on the output closing, never `waitUntilExit`, which hangs when called off
    /// the main thread (see the memory on it). A read that has not finished in ten
    /// seconds gives up and the process is told to stop.
    static func simctlDevices() async -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "-j"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(10))
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: output.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }

    /// Every available device, keyed by its UDID: the one name for a simulator that two
    /// devices can never share.
    static func simulators(from data: Data) -> [FoundResource] {
        struct Listing: Decodable {
            struct Device: Decodable {
                var name: String
                var udid: String
                var isAvailable: Bool?
            }
            var devices: [String: [Device]]
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.devices.flatMap { runtime, devices -> [FoundResource] in
            let system = systemName(runtime)
            return devices.filter { $0.isAvailable ?? true }.compactMap { device in
                guard let name = ResourceName("simulator:\(device.udid)") else { return nil }
                let display = system.map { "\(device.name) · \($0)" } ?? device.name
                return FoundResource(name: name, kind: .simulator, displayName: display,
                                     aliases: [device.udid, display])
            }
        }
        // As Finder sorts: "iPad" before "Twin", and "iPhone 9" before "iPhone 17".
        .sorted {
            switch $0.displayName.localizedStandardCompare($1.displayName) {
            case .orderedSame: return $0.name < $1.name
            case let order: return order == .orderedAscending
            }
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-0" → "iOS 26.0".
    static func systemName(_ runtime: String) -> String? {
        guard let last = runtime.split(separator: ".").last else { return nil }
        let parts = last.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]) " + parts.dropFirst().joined(separator: ".")
    }

    // MARK: Browsers

    /// Every app that says it opens `https:` links, by bundle id.
    static func browsers() -> [FoundResource] {
        guard let url = URL(string: "https:"),
              let apps = LSCopyApplicationURLsForURL(url as CFURL, .all)?.takeRetainedValue() as? [URL]
        else { return [] }
        var seen = Set<String>()
        return apps.compactMap { app -> FoundResource? in
            guard let bundleID = Bundle(url: app)?.bundleIdentifier?.lowercased(),
                  seen.insert(bundleID).inserted,
                  let name = ResourceName("browser:\(bundleID)") else { return nil }
            let display = app.deletingPathExtension().lastPathComponent
            return FoundResource(name: name, kind: .browser, displayName: display, aliases: [display])
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

/// A catalog that says what it is told. For tests, and for nothing else.
public struct FixedCatalog: ResourceFinding {
    public var list: [FoundResource]
    public init(_ list: [FoundResource]) { self.list = list }
    public func found() async -> [FoundResource] { list }
}
