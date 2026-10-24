import Foundation

/// The marketplaces Add server… and Add skill… search (#687): a list the app provides, the
/// person's own in `~/.agents/marketplaces.json`, and a folder's in its committed
/// `.agents/marketplaces.json`. Like the rest of the catalogue, none is in `agentMethods`.
extension DaemonAPI.Method {
    public static let marketplacesList = "marketplaces/list"
    public static let marketplacesAdd = "marketplaces/add"
    public static let marketplacesRemove = "marketplaces/remove"
    public static let marketplacesSetEnabled = "marketplaces/set-enabled"
}

extension DaemonAPI {
    /// How a marketplace is asked.
    public enum MarketplaceFormat: String, Codable, Hashable, Sendable, CaseIterable {
        /// The MCP Registry API (`/v0.1/servers`): the official registry, GitHub's, and any
        /// company's own, self-hosted or not.
        case mcpRegistry = "mcp-registry"
        /// skills.sh's search.
        case skillsSh = "skills.sh"
        /// A GitHub repository of skills: every folder with a `SKILL.md`.
        case gitHubSkills = "github-skills"
        /// A JSON file, or a folder of them, in the MCP Registry's shape (#2155): the Agents
        /// marketplace inside the host, or a path in a person's or a folder's list.
        case file

        public var kind: CatalogKind {
            switch self {
            case .mcpRegistry, .file: .mcp
            case .skillsSh, .gitHubSkills: .skills
            }
        }
    }

    /// Where a marketplace in the list comes from.
    public enum MarketplaceOrigin: String, Codable, Hashable, Sendable {
        /// The app's own list. It can be turned off, not removed.
        case provided
        /// `~/.agents/marketplaces.json`.
        case personal
        /// A folder's `.agents/marketplaces.json`, committed with it. Shown, edited in the file.
        case folder
    }

    public struct Marketplace: Codable, Hashable, Sendable, Identifiable {
        /// `provided:<slug>`, `personal:<url>` or `folder:<url>`.
        public var id: String
        public var name: String
        public var format: MarketplaceFormat
        /// The registry's base URL, skills.sh's, or `owner/repo` for a GitHub repository.
        public var url: String
        /// The name in `~/.agents-secrets/secrets.env` whose value is sent as a bearer token.
        public var token: String?
        /// The token is named and has no value in `secrets.env`.
        public var tokenMissing: Bool
        public var origin: MarketplaceOrigin
        public var enabled: Bool
        /// One line on what it is, for the provided ones.
        public var about: String?

        public init(id: String, name: String, format: MarketplaceFormat, url: String, token: String? = nil,
                    tokenMissing: Bool = false, origin: MarketplaceOrigin, enabled: Bool = true, about: String? = nil) {
            self.id = id; self.name = name; self.format = format; self.url = url; self.token = token
            self.tokenMissing = tokenMissing; self.origin = origin; self.enabled = enabled; self.about = about
        }

        public var kind: CatalogKind { format.kind }

        /// What a result row and the sheet's footer name: the host, or `owner/repo`.
        public var host: String {
            if format == .gitHubSkills { return url }
            // The Agents marketplace (#2155) is inside the host; a file is its path.
            if format == .file { return url.hasPrefix("builtin:") ? "this machine" : url }
            return URL(string: url)?.host ?? url
        }
    }

    public struct MarketplacesListRequest: Codable, Sendable {
        public var kind: CatalogKind?
        /// A folder's marketplaces are listed only when it is the destination.
        public var destination: SkillDestination?
        public init(kind: CatalogKind? = nil, destination: SkillDestination? = nil) {
            self.kind = kind; self.destination = destination
        }
    }

    public struct MarketplacesListAnswer: Codable, Sendable, Equatable {
        public var marketplaces: [Marketplace]
        /// `marketplaces.json` (the person's or the folder's) could not be read; what it
        /// adds is missing, and the app will not write over it.
        public var problem: String?
        public init(marketplaces: [Marketplace], problem: String? = nil) {
            self.marketplaces = marketplaces; self.problem = problem
        }
    }

    /// Add one of your own to `~/.agents/marketplaces.json`.
    public struct MarketplaceAddRequest: Codable, Sendable {
        public var name: String
        public var format: MarketplaceFormat
        public var url: String
        /// The `secrets.env` name for a token, if the marketplace needs one.
        public var token: String?
        /// Its value, written to `secrets.env` and never shown again.
        public var tokenValue: String?
        public init(name: String, format: MarketplaceFormat, url: String, token: String? = nil, tokenValue: String? = nil) {
            self.name = name; self.format = format; self.url = url; self.token = token; self.tokenValue = tokenValue
        }
    }

    public struct MarketplaceIDRequest: Codable, Sendable {
        public var id: String
        public init(id: String) { self.id = id }
    }

    public struct MarketplaceSetEnabledRequest: Codable, Sendable {
        public var id: String
        public var enabled: Bool
        public init(id: String, enabled: Bool) { self.id = id; self.enabled = enabled }
    }
}
