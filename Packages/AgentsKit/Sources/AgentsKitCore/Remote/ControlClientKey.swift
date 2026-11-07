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

    /// Deletes the keys of walks that are gone (#3747): each `<account>.walk.<name>` item,
    /// the client key's and the lock's, whose `name` `isGone` says has gone. The person's
    /// own items have no `.walk.` and are never deleted. Gives the accounts deleted.
    @discardableResult
    public static func deleteWalkKeys(isGone: (String) -> Bool) -> [String] {
        deleteWalkKeys(in: DeviceKey.Keychain(accessGroup: nil), isGone: isGone)
    }

    static func deleteWalkKeys(in keychain: DeviceKey.Keychain, isGone: (String) -> Bool) -> [String] {
        var deleted: [String] = []
        for account in keychain.accounts() {
            guard let infix = account.range(of: walkInfix) else { continue }
            let walk = String(account[infix.upperBound...])
            guard !walk.isEmpty, isGone(walk) else { continue }
            keychain.delete(account: account)
            deleted.append(account)
        }
        return deleted
    }

    /// Between an account and a walk's name, as the Mac window names a walk's keys.
    static let walkInfix = ".walk."
}
#endif
