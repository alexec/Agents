// Not on Linux: as the mailbox, a push is a device's business (037).
#if canImport(CloudKit)
import Foundation

/// A push the control plane sends through APNs itself (#1460), for a person with no Mac
/// host relaying notices into their iCloud mailbox.
///
/// All of it but the `aps` is one `Envelope` under `agents`, sealed to this device: the
/// need's id, whether to buzz, and the banner's words. Apple sees only "An agent needs
/// you". `RemoteNotify` opens a loud one and the app a quiet one, as they do the mailbox's.
public enum ControlPush {
    /// Where the sealed item is in the push.
    public static let key = "agents"

    struct Body: Codable {
        var sealed: Envelope
    }

    /// `ControlPushItem` on the wire.
    struct Item: Codable {
        var needID: NeedID
        var alert: Bool
        var headline: Headline?
    }

    /// Whether this is the control plane's push, opened or not.
    public static func isControlPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo[key] is [String: Any]
    }

    /// What the push says, opened with the device's key: nil if it is not the control
    /// plane's, or if this device cannot open it, which shows only the generic alert.
    public static func pushed(from userInfo: [AnyHashable: Any], key deviceKey: DeviceKey?) -> CloudKitMailbox.Pushed? {
        guard let deviceKey, let body = userInfo[key] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: body),
              let sealed = try? JSONDecoder().decode(Body.self, from: data).sealed,
              let plaintext = try? deviceKey.open(sealed, info: Envelope.pushPurpose),
              let item = try? JSONDecoder().decode(Item.self, from: plaintext)
        else { return nil }
        return CloudKitMailbox.Pushed(needID: item.needID, token: item.needID.token, envelope: nil,
                                      alert: item.alert && item.headline != nil, withdrawn: item.headline == nil,
                                      count: nil, headline: item.headline?.truncating())
    }
}
#endif
