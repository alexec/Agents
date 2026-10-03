import Foundation
import AgentsKitCore

extension DaemonCore {
    /// What agents call the person, as given: a blank name follows this machine's
    /// account, which is resolved where it is said, in the briefing (#121).
    public func personState() -> PersonSettings { personSettings }

    /// Said to agents from their next briefing on; one already briefed keeps what it
    /// was told, since the briefing is said once.
    public func setPerson(_ settings: PersonSettings) throws -> PersonSettings {
        try personStore.save(settings)
        personSettings = settings
        broadcast(DaemonAPI.Notification.personChanged, settings)
        return settings
    }
}
