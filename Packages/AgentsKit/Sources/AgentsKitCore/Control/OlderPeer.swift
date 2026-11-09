import Foundation
import os
import Synchronization

/// A call that an older control plane or machine refused (#4096). A newer client sends a
/// method or a field that the older end does not know, and Go answers `-32601` or `-32602`
/// with words such as "Those parameters are not a ProviderCreate.", which do not say that
/// the cause is the version. The Mac and the Remote say this instead; the web page says the
/// same (`Web/src/model/errors.ts`).
public enum OlderPeer {
    public enum Part: Sendable { case controlPlane, machine }

    /// The words for a refusal from an end older than this app, or nil when the refusal is
    /// not a missing method or bad parameters, or when that end is the same version or
    /// newer: then it is a real fault, and the client shows its own words.
    public static func sentence(_ error: JSONRPCError, from part: Part, runs theirs: String?, app ours: String?) -> String? {
        guard error.code == JSONRPCError.invalidParams || error.code == JSONRPCError.methodNotFound,
              let theirs, let ours, isOlder(theirs, than: ours) else { return nil }
        let who = part == .controlPlane ? "The control plane needs an update" : machineWords
        return "\(who) to do this. It runs Agents \(theirs); this app is \(ours)."
    }

    /// Whether dotted version `a` is older than `b`, such as 0.17.0 than 0.18.0. A `-dev…` or
    /// `+…` suffix is not compared, and a version that is not a number is never older.
    public static func isOlder(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let d = (i < x.count ? x[i] : 0) - (i < y.count ? y[i] : 0)
            if d != 0 { return d < 0 }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int]? {
        var core = version.hasPrefix("v") ? String(version.dropFirst()) : version
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = String(core[..<cut]) }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    // MARK: What this app knows

    /// The control plane's version as this app last read it in `control/status`, so that every
    /// place that says a refusal can use it without being passed it.
    public static var controlVersion: String? {
        get { known.withLock { $0 } }
        set { known.withLock { $0 = newValue } }
    }

    private static let known = Mutex<String?>(nil)

    /// This app's version, as Settings says it.
    public static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// A refusal from the control plane in words: "needs an update" when it is older than this
    /// app, else its own message. The control plane's words stay in the log.
    public static func controlRefusal(_ error: JSONRPCError) -> String {
        guard !saysMachine(error), let words = sentence(error, from: .controlPlane, runs: controlVersion, app: appVersion) else {
            return error.message
        }
        log.notice("older control plane refused (\(error.code, privacy: .public)): \(error.message, privacy: .public)")
        return words
    }

    /// Each machine's version as this app last read it in `machines/list` (#4101), by its id.
    /// `home` is the machine this app calls `.mac`, when it has another id there.
    public static func know(_ listed: [DaemonAPI.ControlMachine], home: MachineRef?) {
        var versions = Dictionary(listed.map { ($0.id, $0.version) }, uniquingKeysWith: { a, _ in a })
        if let home, home != .mac, let version = versions[home] { versions[.mac] = version }
        machines.withLock { $0 = versions }
    }

    /// A machine's version as this app last read it, or nil when it has not been listed.
    public static func version(of machine: MachineRef) -> String? { machines.withLock { $0[machine] } }

    private static let machines = Mutex<[MachineRef: String]>([:])

    /// A refusal from `machine` with "needs an update" for its message when that machine is
    /// older than this app (#4101), else as it came. The machine's words stay in the log.
    public static func machineRefusal(_ error: JSONRPCError, from machine: MachineRef,
                                      app ours: String? = appVersion) -> JSONRPCError {
        guard let words = sentence(error, from: .machine, runs: version(of: machine), app: ours) else { return error }
        log.notice("older machine refused (\(error.code, privacy: .public)): \(error.message, privacy: .public)")
        return JSONRPCError(code: error.code, message: words, data: error.data)
    }

    /// Whether a refusal's words are already a machine's "needs an update", so the control
    /// plane's version does not take their place.
    static func saysMachine(_ error: JSONRPCError) -> Bool { error.message.hasPrefix(machineWords) }

    private static let machineWords = "This machine needs an update"

    private static let log = Logger(subsystem: "com.alexecollins.agents", category: "versions")
}
