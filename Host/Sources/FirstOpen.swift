import AgentsKitCore
import AppKit
import Observation

/// The first open of the one app (#4226): what **Run It Here** did, with no question, and
/// then the window pairs itself with this Mac's own control plane. The app holds the
/// control key, so it makes the window's client code itself: no code to type, no Bonjour
/// wait and no paste. The window is still a listed client, so agentsd's checks stay as
/// they are.
@MainActor
@Observable
final class FirstOpen {
    enum Step: Equatable {
        /// A step under way: "Starting the control plane…".
        case working(String)
        /// One line, what went wrong; `details` says more for Show Details.
        case failed(String, details: String)
        /// The control plane is not on this Mac (joined elsewhere, or the organisation pins
        /// one): the window connects to it as before.
        case elsewhere
    }

    let host: HostModel
    private(set) var step: Step = .working("Setting up Agents on this Mac…")
    /// macOS wants the person to allow Agents in System Settings ▸ General ▸ Login Items.
    var needsApproval: Bool { host.needsApproval }
    private var running = false

    init(host: HostModel) { self.host = host }

    /// Everything here, then the window paired with `pair`. Run again by Try Again, and by
    /// itself once Login Items allows the app.
    func run(pair: @escaping (ControlCode) async throws -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        if host.settings.role == .joinElsewhere || (host.settings.role == .none && host.pin?.namesAControlPlane == true) {
            step = .elsewhere
            return
        }
        step = .working("Setting up Agents on this Mac…")
        await host.refresh()
        // An alpha's Agents Host that runs here already is left as it is: only the window pairs.
        if host.settings.role == .none || !host.controlRunning || !host.daemonRunning {
            await host.runHere()
            if let problem = host.problem {
                // Login Items' own line says what to do; anything else is one line, and the
                // error itself is under Show Details.
                return needsApproval ? fail(problem) : fail("Agents could not start on this Mac.", why: problem)
            }
        }
        step = .working("Connecting this window…")
        // The control plane has just started: its listener may be a moment behind its store.
        var last = "No code could be made."
        for _ in 0..<20 {
            do {
                try await pair(try await host.windowCode())
                return
            } catch {
                last = "\(error)"
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        fail("This window could not connect to the control plane on this Mac.", why: last)
    }

    private func fail(_ line: String, why: String? = nil) {
        var details = [why ?? line]
        if let reason = host.failureReason, reason != line { details.append(reason) }
        details.append("The logs are at \(host.paths.controlLog.path) and \(host.paths.hostLocations.log.path).")
        step = .failed(line, details: details.joined(separator: "\n\n"))
    }

    /// While Login Items wants approval, the app looks every 2 seconds and carries on by
    /// itself once the person allows it (the spec's open question).
    func waitForApproval(pair: @escaping (ControlCode) async throws -> Void) async {
        while needsApproval, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if host.loginItemsAllowed { await run(pair: pair) }
        }
    }

    /// **Open Login Items**: System Settings ▸ General ▸ Login Items.
    func openLoginItems() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    /// **Show Logs**: both logs, in Finder.
    func showLogs() { host.showLogs() }
}

extension HostModel {
    /// The window's own client code (#4226): made here, with the control key, and used at
    /// once, so it is never shown.
    func windowCode() async throws -> ControlCode {
        let made = await ControlTool.run(["code", "--client", "--home", paths.controlHome.path], paths: paths, settings: settings)
        guard made.ok, let line = made.output.split(separator: "\n").last, let code = ControlCode(text: String(line)) else {
            throw ControlService.Failure(made.problem.isEmpty ? "No code could be made for this window." : made.problem)
        }
        return code
    }
}
