import AgentsKitCore
import Foundation
import Observation

/// What a client keeps of the user scope (#1760): the person's settings and the names of
/// their secrets, read again when the control plane says they changed, and the last
/// machine that went with secrets on it.
///
/// The window's model and the Remote's each own one, fed from the control plane's own
/// connection: `heard` for each notification.
@MainActor @Observable
final class UserScopeState {
    private(set) var settings: DaemonAPI.UserSettings?
    private(set) var secrets: DaemonAPI.UserSecretNames?
    /// The last control/secretsLeft, until the person reads it.
    var left: DaemonAPI.SecretsLeft?
    /// Why the user scope could not be read, or nil.
    private(set) var problem: String?

    func load(_ control: DaemonClient?) async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        do {
            settings = try await control.call(DaemonAPI.Method.userSettings, DaemonAPI.Empty(),
                                              returning: DaemonAPI.UserSettings.self)
            secrets = try await control.call(DaemonAPI.Method.userSecretNames, DaemonAPI.Empty(),
                                             returning: DaemonAPI.UserSecretNames.self)
            problem = nil
        } catch {
            problem = UserScopeWords.refusal(error)
        }
    }

    /// A notification from the control plane. True when it was the user scope's.
    func heard(_ method: String, _ params: JSONValue?, on control: DaemonClient) async -> Bool {
        switch method {
        case DaemonAPI.Notification.controlUserSettingsChanged:
            await load(control)
        case DaemonAPI.Notification.controlSecretsLeft:
            left = try? params?.decode(DaemonAPI.SecretsLeft.self)
            await load(control)
        default:
            return false
        }
        return true
    }

    /// Sets a part at the user scope, or with `.null` gives it back to each machine. Nil
    /// once done, else why not.
    func set(_ part: DaemonAPI.UserSettingsPartName, to value: JSONValue, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            _ = try await control.call(DaemonAPI.Method.userSetSettings, DaemonAPI.UserSettingsPart(part: part, value: value))
            await load(control)
            return nil
        } catch {
            return UserScopeWords.refusal(error)
        }
    }

    func setSecret(_ name: String, value: String, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            _ = try await control.call(DaemonAPI.Method.userSetSecret, DaemonAPI.UserSecret(name: name, value: value))
            await load(control)
            return nil
        } catch {
            return UserScopeWords.refusal(error)
        }
    }

    func removeSecret(_ name: String, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            _ = try await control.call(DaemonAPI.Method.userRemoveSecret, DaemonAPI.UserSecretRequest(name: name))
            await load(control)
            return nil
        } catch {
            return UserScopeWords.refusal(error)
        }
    }
}
