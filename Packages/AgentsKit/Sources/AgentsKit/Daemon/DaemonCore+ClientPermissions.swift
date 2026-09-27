import Foundation
import AgentsKitCore

extension DaemonCore {
    public func clientPermissionState() -> ClientPermissionSettings { clientPermissions }

    public func setClientPermissions(_ settings: ClientPermissionSettings) throws -> ClientPermissionSettings {
        try clientPermissionStore.save(settings)
        clientPermissions = settings
        broadcast(DaemonAPI.Notification.clientPermissionsChanged, settings)
        return settings
    }
}
