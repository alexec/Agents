import Foundation

/// What launchd says of one of Agents Host's jobs (#678), read from `launchctl print`.
///
/// `refresh()` once asked only whether it had a pid, so a job launchd could not spawn sat
/// on *Starting…* with nothing said. This keeps what the print says of why: its job state
/// (`spawn failed`), its last exit (`78: EX_CONFIG`), and whether its launch constraint is
/// out of date with the app on disk (`needs LWCR update`).
public struct LaunchJobState: Sendable, Equatable {
    /// launchd knows the label at all.
    public var loaded: Bool
    /// `job state`, else `state`: `running`, `spawn failed`, `spawn scheduled`, `not running`…
    public var state: String?
    public var pid: Int32?
    /// `last exit code = 78: EX_CONFIG`: 78 here, and the whole of it in `lastExit`.
    public var lastExitCode: Int32?
    public var lastExit: String?
    /// The job's launch constraint is from another build of the app: re-registering fixes it.
    public var needsLWCRUpdate: Bool
    /// How many times launchd has started it.
    public var runs: Int?
    /// What it runs, in the bundle: `program identifier = Contents/MacOS/Agents Host (mode: 2)`
    /// is `Contents/MacOS/Agents Host`. Another than the bundle's plist names is a login item
    /// registered from an older plist (#1379).
    public var program: String?

    public init(loaded: Bool, state: String? = nil, pid: Int32? = nil, lastExitCode: Int32? = nil,
                lastExit: String? = nil, needsLWCRUpdate: Bool = false, runs: Int? = nil, program: String? = nil) {
        self.loaded = loaded
        self.state = state
        self.pid = pid
        self.lastExitCode = lastExitCode
        self.lastExit = lastExit
        self.needsLWCRUpdate = needsLWCRUpdate
        self.runs = runs
        self.program = program
    }

    public static let notLoaded = LaunchJobState(loaded: false)

    public var running: Bool { state == "running" && pid != nil }

    /// `launchctl print gui/<uid>/<label>`'s output and exit status. Only the job's own
    /// top-level lines are read: nested blocks (endpoints, event channels) have states too.
    public static func parse(_ text: String, exitStatus: Int32) -> LaunchJobState {
        guard exitStatus == 0, !text.isEmpty else { return .notLoaded }
        var read = LaunchJobState(loaded: true)
        var topState: String?
        var jobState: String?
        var depth = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("needs LWCR update") { read.needsLWCRUpdate = true }
            // The first line opens the job's own block: its fields are at depth 1.
            let opens = line.hasSuffix("{")
            let closes = line == "}"
            defer {
                if opens { depth += 1 }
                if closes { depth -= 1 }
            }
            guard depth == 1, !opens, let equals = line.range(of: " = ") else { continue }
            let key = String(line[..<equals.lowerBound])
            let value = String(line[equals.upperBound...])
            switch key {
            case "state": topState = value
            case "job state": jobState = value
            case "pid": read.pid = Int32(value)
            case "runs": read.runs = Int(value)
            case "program identifier":
                read.program = value.range(of: " (mode:").map { String(value[..<$0.lowerBound]) } ?? value
            case "last exit code":
                read.lastExit = value
                read.lastExitCode = Int32(value.prefix { $0 == "-" || $0.isNumber })
            default: break
            }
        }
        read.state = jobState ?? topState
        return read
    }

    /// For the diagnostics: `running, pid 123` or `spawn failed, last exit 78: EX_CONFIG, needs LWCR update`.
    public var summary: String {
        guard loaded else { return "not loaded" }
        var parts = [state ?? "unknown state"]
        if let pid { parts.append("pid \(pid)") }
        if let lastExit { parts.append("last exit \(lastExit)") }
        if let runs { parts.append("\(runs) run\(runs == 1 ? "" : "s")") }
        if needsLWCRUpdate { parts.append("needs LWCR update") }
        return parts.joined(separator: ", ")
    }
}

/// `SMAppService.Status` of a job's login item, as plain values the diagnosis can read.
/// `scratch` for a walk's own jobs, which `launchctl bootstrap` loads and Login Items never sees.
public enum LoginItemStatus: String, Sendable, Equatable {
    case notRegistered, enabled, requiresApproval, notFound, scratch
}

/// Why a job Agents Host wants running is not (#678), in words a person can act on, and
/// whether Repair (unregister, register again, kickstart) is the thing to try.
public enum HostJobFailure: Sendable, Equatable {
    /// System Settings ▸ General ▸ Login Items has it switched off, or never allowed.
    case needsApproval
    /// The login item was registered by another build or copy of Agents Host.
    case staleRegistration
    /// launchd could not start it at all: `spawn failed`, or exit 78 (`EX_CONFIG`).
    case couldNotStart(lastExit: String?)
    /// It starts and stops again.
    case keepsStopping(lastExit: String?)
    /// Nothing of it is registered or loaded.
    case notRegistered

    /// Nil while it runs, and while it is between starts with nothing yet against it
    /// (that is still *Starting…*).
    public static func diagnose(_ job: LaunchJobState, login: LoginItemStatus) -> HostJobFailure? {
        if job.running { return nil }
        if login == .requiresApproval { return .needsApproval }
        if job.needsLWCRUpdate { return .staleRegistration }
        guard job.loaded else {
            // Registered, and launchd has no job: the registration is not what it says.
            return login == .enabled ? .staleRegistration : .notRegistered
        }
        if job.state == "spawn failed" || job.lastExitCode == 78 { return .couldNotStart(lastExit: job.lastExit) }
        if let code = job.lastExitCode, code != 0, (job.runs ?? 0) > 1 { return .keepsStopping(lastExit: job.lastExit) }
        return nil
    }

    /// What Repair is for. Approval is the person's, in System Settings.
    public var repairable: Bool { self != .needsApproval }

    /// One sentence, for `name` ("The control plane", "This Mac’s host").
    public func reason(_ name: String) -> String {
        switch self {
        case .needsApproval:
            return "\(name) is waiting to be allowed in System Settings ▸ General ▸ Login Items."
        case .staleRegistration:
            return "\(name)’s login item is out of date with this copy of Agents Host. Repair registers it again."
        case .couldNotStart(let exit):
            return "macOS couldn’t start \(lowered(name))\(exit.map { " (last exit \($0))" } ?? ""). Repair registers it again; if that doesn’t help, something on this Mac is blocking it."
        case .keepsStopping(let exit):
            return "\(name) keeps stopping\(exit.map { " (last exit \($0))" } ?? ""). Its log says why."
        case .notRegistered:
            return "\(name) isn’t registered with macOS. Repair registers it."
        }
    }

    private func lowered(_ name: String) -> String {
        name.hasPrefix("The ") ? "the " + name.dropFirst(4) : name
    }
}

/// What a diagnostics bundle must not carry (#678): host and pairing codes, keys and tokens.
public enum DiagnosticRedaction {
    public static func redact(_ text: String) -> String {
        var out = text
        for (pattern, template) in rules {
            out = pattern.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        // Long runs of base64 or hex: keys and signatures that say nothing a reader needs.
        // A path (it starts with a slash) or a run with no digit in it is words, and kept.
        for match in long.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let run = out[range]
            if run.hasPrefix("/") || !run.contains(where: \.isNumber) { continue }
            out.replaceSubrange(range, with: "<redacted>")
        }
        return out
    }

    private static let long = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9+/_.=-])[A-Za-z0-9+/_-]{40,}={0,2}"#)

    private static let rules: [(NSRegularExpression, String)] = [
        // A control code: agents-control:<version>:<purpose>:<payload>.
        (try! NSRegularExpression(pattern: #"agents-control:[^\s"'<>]+"#), "agents-control:<redacted>"),
        // key=…, "secret": "…", token: …, password …
        (try! NSRegularExpression(pattern: #"(?i)\b([A-Za-z_-]*(?:secret|token|password|passwd|access[_-]?key|api[_-]?key|authorization)[A-Za-z_-]*)("?\s*[:=]\s*"?)(?:Bearer\s+)?[^\s",}]+"#),
         "$1$2<redacted>"),
    ]
}
