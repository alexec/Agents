import Foundation

/// Which machine this is, the same for every process on it and across restarts (058,
/// R11). A window compares it with each host's to know which host is on its own Mac,
/// the one whose folders it may open in Finder.
public enum MachineID {
    public static let current: String = {
        // A second host on this Mac standing in for another machine, in a walk or a test
        // (US7's independent test).
        if let given = ProcessInfo.processInfo.environment["AGENTS_MACHINE_ID"], !given.isEmpty { return given }
        // macOS only: iOS has no `gethostuuid`, and a phone is never a host.
        #if os(macOS)
        var uuid = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        if gethostuuid(&uuid, &wait) == 0 {
            return UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
                               uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15])).uuidString
        }
        #endif
        for file in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let text = try? String(contentsOfFile: file, encoding: .utf8) {
                let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty { return id }
            }
        }
        return ProcessInfo.processInfo.hostName
    }()
}
