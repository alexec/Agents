#if canImport(CryptoKit)
import Foundation

/// The key a client (the Remote, the Mac window) proves itself to a control plane with
/// (058): 32 raw bytes, as `ControlAgreement` makes them, kept in the keychain on this
/// device only (#1031). Not a file, which went into backups and so to a second device.
///
/// A key kept by an older build in `control-client-key` is not read: the device pairs
/// again once (v0.x, no migration).
public enum ControlClientKey {
    /// The key for `account`, made and kept on first use.
    public static func loadOrMake(account: String = "control-client-key") throws -> Data {
        let keychain = DeviceKey.Keychain(accessGroup: nil)
        if let stored = try keychain.read(account: account), stored.count == 32 { return stored }
        let made = ControlAgreement.generate().privateKey
        if try keychain.add(made, account: account) { return made }
        // One there already: kept by another call at the same moment, or not a key at all.
        if let stored = try keychain.read(account: account), stored.count == 32 { return stored }
        try keychain.write(made, account: account)
        return made
    }
}
#endif
