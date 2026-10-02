import Foundation
#if os(macOS)
import SystemConfiguration
#endif

/// `<name>.local`: the address another machine on the same network reaches this Mac at,
/// which a control plane on it puts in every code (058).
///
/// It is the Bonjour name, the one mDNS answers for (System Settings ▸ General ▸ Sharing ▸
/// Local hostname), and not `ProcessInfo.hostName`. That is the Unix host name, which a
/// managed Mac or a DHCP server may set to something else, such as `macos-<serial>`; with
/// `.local` after it nothing answers, and every dial failed to resolve it (#113).
public enum LocalHostName {
    public static var current: String {
        #if os(macOS)
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return "\(name).local".lowercased()
        }
        #endif
        return fromHostName(ProcessInfo.processInfo.hostName)
    }

    /// The Unix host name as a `.local` one: Linux, or a Mac with no Bonjour name.
    static func fromHostName(_ name: String) -> String {
        let local = name.hasSuffix(".local") ? name : (name.split(separator: ".").first.map { "\($0).local" } ?? name)
        return local.lowercased()
    }
}
