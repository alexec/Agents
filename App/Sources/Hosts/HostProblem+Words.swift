import AgentsKit
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
        }
    }

    /// Whether trying the same thing again could work without the person changing
    /// anything on the server or in their ssh setup first.
    var offersTryAgain: Bool {
        if case .hostKeyChanged = self { return false }
        return true
    }
}
