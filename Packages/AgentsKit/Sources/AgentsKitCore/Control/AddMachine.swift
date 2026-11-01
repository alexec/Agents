import Foundation

/// Add a Machine… (#2131): one sheet, reached from Settings ▸ Machines, Connectors set-up ▸
/// Where agents run and a provider's New Machine…, with three ways in. A provider first, as a
/// browser-only person gets any machine that way; then a server, by one command; then
/// another machine, by a code. The web page's `addMachine.ts` is the same.
public enum AddMachine {
    public enum Way: String, CaseIterable, Identifiable, Sendable {
        case provider, server, code
        public var id: String { rawValue }
    }

    /// A machine name from what is typed: letters, digits and dashes, as `machineName` makes one.
    public static func validName(_ text: String) -> Bool {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard let first = name.first, first.isASCII, first.isLetter else { return false }
        return name.count <= 63 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public enum Words {
        public static let title = "Add a Machine"
        public static let menuItem = "Add a Machine…"
        public static let addProvider = "Add Provider…"

        public static func choice(_ way: Way) -> String {
            switch way {
            case .provider: "From a machine provider"
            case .server: "A server"
            case .code: "Another Mac"
            }
        }

        /// The note under a choice. `ssh` is the Mac's: it can install over ssh too.
        public static func note(_ way: Way, ssh: Bool) -> String {
            switch way {
            case .provider: "A new machine from Docker, DigitalOcean, Codespaces, Coder and the others. It joins by itself."
            case .server: ssh ? "Run one command on it, or install it over ssh. It connects out, so nothing has to reach it."
                : "Run one command on it. It connects out, so nothing has to reach it."
            case .code: "Give it a code to join with. It works once."
            }
        }

        public static let noProviders = "No provider here can make a machine yet."
        public static let noProvidersAskAdmin = "No provider here can make a machine. An admin adds one in Settings ▸ Machine Providers."
        public static let needsControlPlane = "Needs a control plane, such as the one on your Mac."
        /// Said where a provider is added outside Settings (#1787).
        public static let providersYours = "Your providers are yours in every folder."
        public static let existing = "Or add one it has already"
        public static let next = "Next"
        public static let machineTitle = "New Machine"
        public static let namePrompt = "build-2"
        public static let repositoryOptional = "Clone a repository (optional)"
        public static let nameNote = "Letters, digits and dashes, starting with a letter."

        public static let serverTitle = "Add a Machine"
        public static let serverNote = "Run this on the machine. It installs Agents and joins as your machine. It works once."
        public static let codeTitle = "Add a Machine by Code"
        public static let codeNote = "On the other machine, start its agents with agentsd --control-code and this code. It works once."
        public static let makingCode = "Making a code…"
        public static func joined(_ name: String) -> String { "\(name) joined. The code can’t be used again." }

        /// The Machines page's line under Add a Machine….
        public static let machinesFoot = "Removing a machine stops it connecting. Its agents are left running where they are."
        public static func started(_ name: String) -> String {
            "\(name) is starting. It installs Agents and joins on its first boot."
        }
    }
}

/// Connectors set-up ▸ Where agents run (#2131): the machine the folder is on, the others
/// that are yours, and Add a Machine… and Add Provider… in place.
public enum WhereAgentsRun {
    /// The slot's title: the machine the folder is on.
    public static func title(onThisMac: Bool, hostName: String?) -> String {
        onThisMac ? "This Mac" : (hostName ?? "Its machine")
    }

    /// The slot's line: why it runs there, and what else is yours.
    public static func line(others: [String], providers: [String]) -> String {
        var parts = ["Agents run where this folder is."]
        if !others.isEmpty { parts.append("Your other machines: \(others.joined(separator: ", ")).") }
        if !providers.isEmpty { parts.append("Providers: \(providers.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    public static let hereNote = "This folder is here."
    public static let addMachineNote = "From a provider, a server or another Mac."
    public static let addProviderNote = "Docker, DigitalOcean, Codespaces, Coder and the others. " + AddMachine.Words.providersYours
}
