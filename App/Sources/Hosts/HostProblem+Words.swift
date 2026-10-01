import AgentsKitCore
import Foundation

/// Every sentence the window says about a server that cannot be used (037), in one
/// place, word for word from wireframes.md § Words.
extension HostProblem {
    func sentence(name: String, label: String) -> String {
        switch self {
        case .unknownHost:
            "ssh can’t find a host called “\(name)”. Check the name or your ~/.ssh/config."
        case .loginRefused:
            "\(label) refused the login. Is your key added to ssh-agent?"
        case .keyLocked:
            "Your key needs its passphrase. Run ssh-add in Terminal, then try again."
        case .hostKeyChanged:
            "\(label)’s host key has changed since you last connected. Agents won’t connect until you check it."
        case .unsupportedSystem(let system, let architecture):
            "\(label) is \(system == "Darwin" ? "macOS" : system) on \(architecture). Agents servers need Linux on x86-64 or ARM64."
        case .noStreamLocalForwarding:
            "\(label) doesn’t allow forwarding a socket over ssh (AllowStreamLocalForwarding), which Agents needs."
        case .diskFull:
            "There isn’t room on \(label) to set up Agents."
        case .serverNewer:
            "\(label) runs a newer Agents. Update this app."
        case .installFailed(let detail):
            detail.isEmpty ? "Setting up \(label) failed." : "Setting up \(label) failed: \(detail)"
        case .timedOut:
            "\(label) didn’t answer. Check it is on and reachable, then try again."
        case .offline:
            "\(label) is offline"
        case .noDownloader:
            "\(label) has neither curl nor wget to download Claude."
        case .noInternet:
            "\(label) can’t reach the internet to download Claude."
        case .unsupportedLibc(let libc):
            "Claude can’t be installed on \(label): it uses \(libc). Install Claude there yourself to use it."
        case .toolsetChecksum:
            "The download on \(label) didn’t match its checksum, so nothing was installed."
        case .toolsetInstallFailed(let detail):
            detail.isEmpty ? "Installing Claude on \(label) failed." : "Installing Claude on \(label) failed: \(detail)"
        case .diskFullForTools(let needed, let free):
            "\(label) needs \(Self.megabytes(needed)) free to install Claude, and has \(Self.megabytes(free))."
        }
    }

    /// Whether trying the same thing again could work without the person changing
    /// anything on the server or in their ssh setup first.
    static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var offersTryAgain: Bool {
        if case .hostKeyChanged = self { return false }
        return true
    }

    /// The window cannot reach the control plane at all (058, frame H). One strip for
    /// every host, naming where the window expected it.
    static func controlPlaneUnreachable(name: String, address: String) -> String {
        "Can’t reach the control plane on \(name) (\(address)). Your agents are still working there."
    }

    /// What Settings ▸ Control plane says when the control plane refused a change (058,
    /// T081): the two refusals that come from there being several copies over one store,
    /// in words, and anything else as the control plane said it.
    static func controlRefusal(_ error: JSONRPCError) -> String {
        switch error.code {
        case DaemonAPI.Failure.changedElsewhere:
            "Someone changed that from another window at the same moment, so nothing was changed. This shows it as it is now."
        case DaemonAPI.Failure.storeUnavailable:
            "The control plane can’t reach where it keeps its records, so nothing was changed. Agents that are running carry on."
        default:
            error.message
        }
    }
}
