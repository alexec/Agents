import AgentsKitCore
import AppKit
import Foundation

/// One redacted text a person can attach to a bug report when the control plane or this
/// Mac's host won't start (#678): the app and where it is, the settings without secrets,
/// what macOS and launchd say of both jobs, whether 8791 and 8792 are listening, and the
/// end of both logs. *Copy Diagnostics* and `Agents Host --diagnose` both write it.
struct HostDiagnostics {
    let paths: HostPaths

    static let argument = "--diagnose"
    static let logLines = 200

    /// The places other copies of Agents Host are, beside this one: two copies fight over
    /// one set of login items.
    static func otherCopies() -> [URL] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let here = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL }
            // Xcode's build products are a developer's, not a second install.
            .filter { $0 != here && !$0.path.contains("/Build/Products/") && !$0.path.contains("/.Trash/") }
    }

    func report() async -> String {
        let services = LocalServices(paths: paths)
        let settings = HostSettings.load(paths)
        let info = Bundle.main.infoDictionary ?? [:]
        var lines: [String] = []
        func section(_ title: String) { lines += ["", "## \(title)"] }

        lines.append("# Agents Host diagnostics")
        lines.append("Made \(Date().formatted(.iso8601)) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        section("This copy")
        lines.append("Version: \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        lines.append("Path: \(Bundle.main.bundlePath)")
        let others = Self.otherCopies()
        lines.append("Other copies: \(others.isEmpty ? "none" : others.map(\.path).joined(separator: ", "))")
        lines.append("Scratch set-up: \(paths.scratch ? "yes" : "no")")
        section("Settings")
        lines.append("Role: \(settings.role)")
        lines.append("Store: \(settings.store)")
        lines.append("Web remote: \(settings.servesWebRemote ? "on" : "off")")
        lines.append("Relay for my devices: \(settings.relaysForDevices ? "on" : "off")"
                     + (services.relayHost.map { ", joined as \($0.rawValue)" } ?? ", not joined"))
        if let moved = settings.movedTo { lines.append("Moved to: \(moved)") }
        if let from = settings.returnedFrom { lines.append("Returned from: \(from)") }
        lines.append("Host joined: \(services.hostJoined ? "yes" : "no")")
        if let join = HostJoinFile.read(paths.hostLocations.controlJoinStatus) {
            lines.append("Host join: \(join.summary)")
        }

        for (job, name) in [(LocalServices.Job.control, "Control plane"), (.daemon, "This Mac’s host"), (.relay, "Relay")] {
            section("\(name) (\(services.label(job)))")
            let state = await services.state(job)
            let login = services.loginStatus(job)
            lines.append("Login item: \(login.rawValue)")
            lines.append("launchd: \(state.summary)")
            if let failure = HostJobFailure.diagnose(state, login: login) { lines.append("Reason: \(failure.reason(name))") }
            lines.append("```")
            lines.append(await services.printed(job).trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("```")
        }

        section("Listening")
        for port in [paths.port, paths.webPort] {
            lines.append("\(port): \(await Self.listening(port) ?? "nothing")")
        }

        for (name, log) in [("control.log", paths.controlLog), ("daemon.log", paths.hostLocations.log),
                            ("relay.log", paths.relayLog)] {
            section("\(name), the last \(Self.logLines) lines (\(log.path))")
            lines.append("```")
            lines.append(Self.tail(log, lines: Self.logLines) ?? "(none)")
            lines.append("```")
        }
        return DiagnosticRedaction.redact(lines.joined(separator: "\n")) + "\n"
    }

    /// What listens on `port` on this Mac, as `lsof` names it; nil when nothing does.
    static func listening(_ port: Int) async -> String? {
        let found = await ChildProcess.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                           ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fcp"], deadline: .seconds(5))
        // -F: a "p<pid>" line, then "c<command>".
        let fields = found.text.split(separator: "\n")
        guard !fields.isEmpty else { return nil }
        let pid = fields.first { $0.hasPrefix("p") }.map { $0.dropFirst() } ?? "?"
        let command = fields.first { $0.hasPrefix("c") }.map { $0.dropFirst() } ?? "?"
        return "\(command) (pid \(pid))"
    }

    /// The last `lines` lines of a log, read from its end only.
    static func tail(_ file: URL, lines: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// `~/Desktop/Agents-Host-diagnostic-<date>.txt`.
    static var suggestedName: String {
        "Agents-Host-diagnostic-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).txt"
    }

    /// `Agents Host --diagnose`: the report on standard output, for a person in Terminal or
    /// an agent, with no window.
    static func runFromCommandLine() -> Never {
        Task {
            let text = await HostDiagnostics(paths: .current).report()
            FileHandle.standardOutput.write(Data(text.utf8))
            exit(0)
        }
        dispatchMain()
    }
}
