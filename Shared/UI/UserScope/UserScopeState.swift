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
    /// The machine lock, so a secret is sealed only to the machines it names (#3491, D8).
    @ObservationIgnored weak var lock: LockState?

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

    /// Seals the value here to each of the person's machines and apps (#3397), and sends only
    /// the envelopes: the control plane never has it. `replacing` is the row replaced, for its
    /// version.
    func setSecret(_ name: String, value: String, replacing: DaemonAPI.UserSecretRow? = nil, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            let to = try await control.call(DaemonAPI.Method.userSecretRecipients, DaemonAPI.Empty(),
                                            returning: DaemonAPI.SealRecipients.self)
            let version = UserScopeWords.nextVersion(replacing ?? secrets?.secrets.first { $0.name == name }, now: Date())
            // Only to the machines the lock names (#3491, D8): the control plane cannot add a key of its own.
            let recipients = if let lock { await lock.signed(to.recipients, on: control) } else { to.recipients }
            let values = try ClientSealing.sealSecret(user: to.user ?? "", name: name, version: version, value: value, to: recipients)
            _ = try await control.call(DaemonAPI.Method.userSetSecret, DaemonAPI.UserSecretSet(name: name, version: version, values: values))
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
