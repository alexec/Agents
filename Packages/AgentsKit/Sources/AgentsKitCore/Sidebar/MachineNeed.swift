import Foundation

/// What a machine needs, as its row under Machines says it in one grey line (#3764). Only the
/// most urgent is said: offline, then stopped, then a set-up that failed, then an update, then
/// a runtime's sign-in. The web page's machineNeed picks it the same way.
public enum MachineNeed: Equatable, Sendable {
    case offline
    /// Its provider's workspace is stopped, starting, stopping or failed to start (#691).
    case stopped
    case setupFailed
    case update
    /// The runtimes installed there that are not signed in, by name.
    case signIn([String])

    /// The machine's most urgent need, or nil when it needs nothing. `offline` is whether the
    /// window can ask it now; `row` is the control plane's row, nil for a machine it does not list.
    public static func most(row: DaemonAPI.ControlMachine?, offline: Bool, runtimes: [RuntimeStatus]) -> MachineNeed? {
        if offline {
            if let row, let workspace = row.workspace,
               workspace.problem != nil || ["stopped", "starting", "stopping"].contains(row.state) {
                return .stopped
            }
            return row?.state == "failed" ? .setupFailed : .offline
        }
        if row?.state == "needsUpdate" { return .update }
        let signIn = runtimes.filter(\.needsSignIn).map(\.runtime.name)
        return signIn.isEmpty ? nil : .signIn(signIn)
    }
}

public extension RuntimeStatus {
    /// Installed but not signed in, as its line on the machine's page says (#3629): the Mac's
    /// runtime refused for its sign-in, or a server's that is not signed in and uses no Mac's.
    var needsSignIn: Bool {
        if case .needsSignIn = availability { return true }
        guard case .available = availability, let signIn else { return false }
        return !signIn.signedIn && signIn.relayed != true
    }
}
