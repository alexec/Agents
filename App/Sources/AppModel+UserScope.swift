import AgentsKitCore
import AppKit
import Foundation
import os

/// The user scope (#1760).
extension AppModel {
    // MARK: The user scope (#1760)

    /// Sets a part at the user scope: nil once done, else why not.
    func setUserPart(_ part: DaemonAPI.UserSettingsPartName, _ value: some Encodable) async -> String? {
        guard let encoded = try? JSONValue.encoding(value) else { return "That could not be written." }
        return await userScope.set(part, to: encoded, on: controlRequests)
    }

    /// The person's time zone (#4818): this Mac's, set at the user scope when it differs, so
    /// a workflow's `hours:` with no `time-zone:` go by it on a server too. It has no control.
    func keepTimeZone() async {
        guard let settings = userScope.settings else { return }
        let here = TimeZone.current.identifier
        if (try? settings.timeZone?.decode(DaemonAPI.UserTimeZone.self))?.identifier == here { return }
        _ = await setUserPart(.timeZone, DaemonAPI.UserTimeZone(identifier: here))
    }

    /// After an edit in Agent Configuration or Agent Runtimes: a part that follows the person
    /// is set again from this Mac, when it changed here.
    func keepFollowingParts() async {
        for part in [DaemonAPI.UserSettingsPartName.mcpServers, .agentConfig, .runtimes] {
            guard let here = try? await macClient.call(DaemonAPI.Method.settingsUserPart, DaemonAPI.UserPartRequest(part: part),
                                                       returning: DaemonAPI.UserPartHere.self),
                here.value != userScope.settings?[part] else { continue }
            _ = await userScope.set(part, to: here.value, on: controlRequests)
        }
    }

    func refreshCostState() async {
        guard let state = try? await macClient.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
    }

    /// The reader setting or clearing a limit. Theirs alone: nothing an agent or a
    /// workflow can reach calls this.
}
