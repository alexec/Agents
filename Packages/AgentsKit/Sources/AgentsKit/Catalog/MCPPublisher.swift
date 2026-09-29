import Foundation

/// Publisher label and known mark from a registry name (060, R8).
enum MCPPublisher {
    static func display(registryName: String) -> DaemonAPI.MCPPublisherInfo {
        let ns = namespace(of: registryName)
        if ns.hasPrefix("io.github.") {
            let org = String(ns.dropFirst("io.github.".count))
            return .init(label: "\(org) on GitHub", namespace: ns, known: KnownOwners.isKnown(org))
        }
        // com.example / ai.smithery / …
        let parts = ns.split(separator: ".")
        if parts.count >= 2 {
            let domain = parts.dropFirst().joined(separator: ".")
            let known = KnownOwners.isKnown(String(parts[1]))
                || ["github.com", "modelcontextprotocol.io"].contains(domain)
                || KnownOwners.isKnown(domain)
            return .init(label: domain, namespace: ns, known: known)
        }
        return .init(label: ns, namespace: ns, known: false)
    }

    static func namespace(of registryName: String) -> String {
        if let slash = registryName.firstIndex(of: "/") {
            return String(registryName[..<slash])
        }
        return registryName
    }

    static func shortName(registryName: String) -> String {
        if let slash = registryName.firstIndex(of: "/") {
            return String(registryName[registryName.index(after: slash)...])
        }
        return registryName
    }

    /// Host considered "the publisher's own" for a remote URL comparison.
    static func ownHosts(registryName: String, repositoryURL: String?) -> Set<String> {
        var hosts = Set<String>()
        let ns = namespace(of: registryName)
        if ns.hasPrefix("io.github.") {
            hosts.formUnion(["github.com", "api.github.com", "api.githubcopilot.com", "raw.githubusercontent.com"])
        }
        let parts = ns.split(separator: ".")
        if parts.count >= 2 {
            hosts.insert(parts.dropFirst().joined(separator: "."))
        }
        if let repositoryURL, let host = URL(string: repositoryURL)?.host {
            hosts.insert(host.lowercased())
        }
        return hosts
    }
}
