import Foundation

/// The shell in a project's own folder (#418), opened with Control-` rather than from
/// an agent's Terminal pane.
///
/// The daemon holds shells by an agent's id, and everything about one — input, size,
/// output, closing — is addressed that way. A project has no id of its own (its folder
/// is its identity), so its shell is given one made from the folder: the same folder is
/// the same id on every screen and every launch, and never an agent's.
public enum ProjectShell {
    /// The id the project's shell goes by. Made from the folder's path as the daemon
    /// names the project, so the window, the phone and the daemon arrive at one id.
    public static func id(for folder: URL) -> UUID {
        let path = Array(("project-shell:" + folder.path(percentEncoded: false)).utf8)
        // Two FNV-1a passes from different starting points: 128 bits, the same on every
        // platform, with no CryptoKit (the Linux daemon has none).
        var bytes = withUnsafeBytes(of: fnv(path, seed: 0xcbf2_9ce4_8422_2325).bigEndian, Array.init)
            + withUnsafeBytes(of: fnv(path, seed: 0x6c62_272e_07bb_0142).bigEndian, Array.init)
        // Version 8 (made by its own rule) and the RFC variant, so it is a valid UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func fnv(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}
