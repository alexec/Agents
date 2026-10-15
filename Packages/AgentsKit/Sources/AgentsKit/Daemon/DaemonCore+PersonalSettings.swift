import Foundation
import AgentsKitCore

extension DaemonCore {
    /// Watch the person's settings folder (#1033), so a file edited by hand, or brought by
    /// a sync from another Mac, is read again without a restart. The folder is made first:
    /// a watch on a folder that does not exist reports nothing.
    func watchPersonalSettings() {
        guard personalSettingsWatch == nil else { return }
        let folder = locations.personalSettings
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            DaemonLog.shared.write("settings: could not make \(folder.path): \(error.localizedDescription)")
            return
        }
        seenLimits = limitStore.load()
        seenModes = modeStore.remembered()
        seenDisplay = displayStore.load()
        personalSettingsWatch = FolderWatch(root: folder) { [weak self] _ in
            Task { await self?.personalSettingsChanged() }
        }
    }

    /// Read every setting again and tell the clients of each that changed. The daemon's own
    /// writes come back through here too, and change nothing, so they say nothing.
    func personalSettingsChanged() {
        let person = personStore.load()
        if person != personSettings {
            personSettings = person
            broadcast(DaemonAPI.Notification.personChanged, person)
        }
        let permissions = clientPermissionStore.load()
        if permissions != clientPermissions {
            clientPermissions = permissions
            broadcast(DaemonAPI.Notification.clientPermissionsChanged, permissions)
        }
        let sandbox = sandboxStore.load()
        if sandbox != sandboxSettings {
            sandboxSettings = sandbox
            broadcast(DaemonAPI.Notification.sandboxChanged, sandbox)
        }
        if let kept = workflowLimitSettings {
            workflowLimitSettings = nil
            if readWorkflowLimit() != kept { rebroadcastAllWorkflows() }
        }
        // Applied at the next hourly check, as the person's own edit: no confirmation is
        // asked of a file.
        if retentionIsLoaded {
            let settings = retentionStore.load().settings
            if settings != retention.settings {
                retention.settings = settings
                broadcast(DaemonAPI.Notification.retentionChanged, retentionState())
            }
        }
        // The limits and the modes are read from disk each time they are wanted; only the
        // clients need telling.
        let limits = limitStore.load()
        if limits != seenLimits {
            seenLimits = limits
            broadcastCostState()
        }
        let display = displayStore.load()
        if display != seenDisplay {
            seenDisplay = display
            broadcast(DaemonAPI.Notification.preferencesChanged, display)
        }
        let modes = modeStore.remembered()
        if modes != seenModes {
            seenModes = modes
            broadcast(DaemonAPI.Notification.modesChanged, modes)
        }
    }

    /// `preferences/get` (#1033).
    public func displayPreferences() -> DaemonAPI.DisplayPreferences { displayStore.load() }

    /// `preferences/set`: merged into `display.json`, and every client told.
    public func setDisplayPreferences(_ changes: DaemonAPI.DisplayPreferences) throws -> DaemonAPI.DisplayPreferences {
        let all = try displayStore.merge(changes)
        if all != seenDisplay {
            seenDisplay = all
            broadcast(DaemonAPI.Notification.preferencesChanged, all)
        }
        return all
    }
}
