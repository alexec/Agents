#if canImport(CryptoKit)
import Foundation
import AgentsKitCore

/// The marketplaces a catalogue sheet can search (#687): the app's own list, then the
/// person's `~/.agents/marketplaces.json`, then the destination project's
/// `.agents/marketplaces.json`, committed with it so a company can ship its registry.
///
/// ```json
/// { "marketplaces": [ { "name": "Acme", "format": "mcp-registry",
///                       "url": "https://mcp.acme.example", "token": "ACME_MCP_TOKEN" } ],
///   "off": ["provided:official-mcp"] }
/// ```
///
/// `token` names a line in `secrets.env`, sent as a bearer token; the file never holds the
/// value. `off` and `on` are the person's only. A project's marketplaces start off, and
/// are used once the person names them in `on`: a committed file could otherwise send one
/// of their secrets to any host it names, as an MCP server from a pull waits for an OK.
enum Marketplaces {
    static let fileName = "marketplaces.json"

    /// The app's own list, in the order the sheet offers them: GitHub's registry first,
    /// because it is curated and ranked, where the official one is neither (060 R1).
    static func provided(environment: [String: String] = ProcessInfo.processInfo.environment) -> [DaemonAPI.Marketplace] {
        // A walk points every provided registry, or skills.sh, at its fixture server.
        let registry = environment[MCPRegistryEndpoints.variable]
        let catalog = environment[CatalogEndpoints.catalogVariable]
        return [
            .init(id: "provided:github-mcp", name: "GitHub MCP Registry", format: .mcpRegistry,
                  url: registry ?? "https://api.mcp.github.com", origin: .provided,
                  about: "Curated by GitHub, most starred first."),
            .init(id: "provided:official-mcp", name: "MCP Registry", format: .mcpRegistry,
                  url: registry ?? "https://registry.modelcontextprotocol.io", origin: .provided,
                  about: "The open registry: everything published, in its own order."),
            .init(id: "provided:skills-sh", name: "skills.sh", format: .skillsSh,
                  url: catalog ?? "https://skills.sh", origin: .provided,
                  about: "Skills on GitHub, most installed first."),
            .init(id: "provided:anthropic-skills", name: "Anthropic skills", format: .gitHubSkills,
                  url: "anthropics/skills", origin: .provided,
                  about: "Anthropic's own skills."),
        ]
    }

    /// What a `marketplaces.json` says.
    struct File: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            var name: String
            var format: DaemonAPI.MarketplaceFormat
            var url: String
            var token: String?
        }
        var marketplaces: [Entry] = []
        var off: [String]? = nil
        /// A project's marketplaces the person has turned on.
        var on: [String]? = nil
    }

    struct Unreadable: Error, Equatable {
        var path: String
        var message: String { "\(path) could not be read, so the marketplaces in it are left out and nothing is written to it" }
    }

    static func personalURL(home: URL) -> URL {
        home.appending(path: PersonalDotAgents.folder).appending(path: fileName)
    }

    static func projectURL(folder: URL) -> URL {
        folder.appending(path: DotAgents.folder).appending(path: fileName)
    }

    /// A missing file is an empty one; one that is there and does not read is refused, so
    /// nothing is written over it.
    static func load(_ url: URL) throws -> File {
        guard FileManager.default.fileExists(atPath: url.path) else { return File() }
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw Unreadable(path: url.path)
        }
        return file
    }

    static func save(_ file: File, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreCoding.writeAtomically(try encoder.encode(file) + Data("\n".utf8), to: url, permissions: 0o644)
    }

    /// Every marketplace for a kind, provided first, then the person's, then the project's.
    static func list(kind: DaemonAPI.CatalogKind?, personal: File, project: File?,
                     secretIsSet: (String) -> Bool,
                     environment: [String: String] = ProcessInfo.processInfo.environment) -> [DaemonAPI.Marketplace] {
        let off = Set(personal.off ?? []), on = Set(personal.on ?? [])
        var out = provided(environment: environment)
        out += personal.marketplaces.map { marketplace($0, origin: .personal, secretIsSet: secretIsSet) }
        out += (project?.marketplaces ?? []).map { marketplace($0, origin: .project, secretIsSet: secretIsSet) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted && (kind == nil || $0.kind == kind) }
            .map { var m = $0; m.enabled = m.origin == .project ? on.contains(m.id) : !off.contains(m.id); return m }
    }

    /// Turn one on or off in the person's file.
    static func setEnabled(_ marketplace: DaemonAPI.Marketplace, _ enabled: Bool, in file: inout File) {
        if marketplace.origin == .project {
            var on = (file.on ?? []).filter { $0 != marketplace.id }
            if enabled { on.append(marketplace.id) }
            file.on = on.isEmpty ? nil : on
        } else {
            var off = (file.off ?? []).filter { $0 != marketplace.id }
            if !enabled { off.append(marketplace.id) }
            file.off = off.isEmpty ? nil : off
        }
    }

    static func id(origin: DaemonAPI.MarketplaceOrigin, url: String) -> String {
        "\(origin.rawValue):\(normalized(url))"
    }

    static func normalized(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func marketplace(_ entry: File.Entry, origin: DaemonAPI.MarketplaceOrigin,
                                    secretIsSet: (String) -> Bool) -> DaemonAPI.Marketplace {
        DaemonAPI.Marketplace(id: id(origin: origin, url: entry.url), name: entry.name, format: entry.format,
                              url: normalized(entry.url), token: entry.token,
                              tokenMissing: entry.token.map { !secretIsSet($0) } ?? false, origin: origin)
    }

    /// Why an entry typed on the sheet cannot be added, or nil.
    static func problem(_ request: DaemonAPI.MarketplaceAddRequest) -> String? {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = normalized(request.url)
        if name.isEmpty { return "Give it a name." }
        switch request.format {
        case .gitHubSkills:
            if SkillsCatalog.gitHubSource(url) == nil { return "A GitHub repository is owner/repo." }
        case .mcpRegistry, .skillsSh:
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), parsed.host != nil else {
                return "The address is a URL, such as https://mcp.example.com."
            }
            if scheme != "https" && !(scheme == "http" && ["localhost", "127.0.0.1"].contains(parsed.host ?? "")) {
                return "The address must be https (http only for localhost)."
            }
        }
        if let token = request.token, !token.isEmpty,
           !(token.first!.isLetter || token.first == "_") || !token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return "A token name is letters, digits and _, such as ACME_MCP_TOKEN."
        }
        return nil
    }
}
#endif
