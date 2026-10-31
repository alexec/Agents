import Foundation

/// The organisation's ways to the model (#999, spec 999): an org key, or a gateway (Amazon
/// Bedrock, Google Vertex AI, Microsoft Azure, a base URL), kept by the control plane with its
/// secrets sealed, and sent to each machine that may use it. An admin manages them in Console ▸
/// Model Access on the web page; the window and the Remote show the routes a person may use, read
/// only, in Settings ▸ Policy. The types are hand-written against `Packages/Wire/daemon.schema.json`
/// (`WireSchemaTests`); a value is never in any of them (spec D14).
public extension DaemonAPI {
    /// An org route's settings that are not secret.
    struct OrgRouteSettings: Codable, Sendable, Hashable {
        public var address: String?
        public var apiVersion: String?
        public var clientID: String?
        public var header: String?
        public var location: String?
        public var project: String?
        public var region: String?
        public var resource: String?
        public var tenant: String?

        public init(address: String? = nil, apiVersion: String? = nil, clientID: String? = nil, header: String? = nil,
                    location: String? = nil, project: String? = nil, region: String? = nil, resource: String? = nil,
                    tenant: String? = nil) {
            self.address = address
            self.apiVersion = apiVersion
            self.clientID = clientID
            self.header = header
            self.location = location
            self.project = project
            self.region = region
            self.resource = resource
            self.tenant = tenant
        }
    }

    /// Who changed an org route, and when.
    struct OrgRouteStamp: Codable, Sendable, Hashable {
        public var by: AuditActor
        public var at: Date

        public init(by: AuditActor, at: Date) {
            self.by = by
            self.at = at
        }
    }

    /// An org route, as an admin reads it: no value, only the names of the secret fields set and
    /// a short fingerprint of each.
    struct OrgRoute: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// `key`, `bedrock`, `vertex`, `azure` or `baseURL`.
        public var kind: String
        /// `anthropic`, `openai` or `xai`.
        public var vendor: String?
        public var runtimes: [String]
        public var settings: OrgRouteSettings?
        public var models: [String: String]?
        public var groups: [String]?
        public var defaultFor: [String]?
        public var secretFields: [String]?
        public var fingerprint: [String: String]?
        public var version: Int?
        public var created: OrgRouteStamp?
        public var changed: OrgRouteStamp?
        public var machines: Int?

        public init(id: String, name: String, kind: String, vendor: String? = nil, runtimes: [String],
                    settings: OrgRouteSettings? = nil, models: [String: String]? = nil, groups: [String]? = nil,
                    defaultFor: [String]? = nil, secretFields: [String]? = nil, fingerprint: [String: String]? = nil,
                    version: Int? = nil, created: OrgRouteStamp? = nil, changed: OrgRouteStamp? = nil, machines: Int? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.vendor = vendor
            self.runtimes = runtimes
            self.settings = settings
            self.models = models
            self.groups = groups
            self.defaultFor = defaultFor
            self.secretFields = secretFields
            self.fingerprint = fingerprint
            self.version = version
            self.created = created
            self.changed = changed
            self.machines = machines
        }
    }

    /// An org route with its store tag, for an admin.
    struct OrgRouteKept: Codable, Sendable, Hashable {
        public var route: OrgRoute
        public var rev: String

        public init(route: OrgRoute, rev: String) {
            self.route = route
            self.rev = rev
        }
    }

    /// `orgRoutes/list`: every route, and whether this control plane can seal a secret.
    struct OrgRouteList: Codable, Sendable, Hashable {
        public var routes: [OrgRouteKept]
        public var sealing: Bool

        public init(routes: [OrgRouteKept], sealing: Bool) {
            self.routes = routes
            self.sealing = sealing
        }
    }

    /// `orgRoutes/set`: a route to add or change; secrets are written only.
    struct OrgRouteSet: Codable, Sendable, Hashable {
        public var route: OrgRoute
        public var secrets: [String: String]?
        public var rev: String?

        public init(route: OrgRoute, secrets: [String: String]? = nil, rev: String? = nil) {
            self.route = route
            self.secrets = secrets
            self.rev = rev
        }
    }

    /// `orgRoutes/replaceKey`: new values for a route's secret fields.
    struct OrgRouteReplaceKey: Codable, Sendable, Hashable {
        public var id: String
        public var secrets: [String: String]
        public var rev: String

        public init(id: String, secrets: [String: String], rev: String) {
            self.id = id
            self.secrets = secrets
            self.rev = rev
        }
    }

    /// `orgRoutes/check` and `orgRoutes/remove`: a route, and for remove the tag read.
    struct OrgRouteRequest: Codable, Sendable, Hashable {
        public var id: String
        public var rev: String?

        public init(id: String, rev: String? = nil) {
            self.id = id
            self.rev = rev
        }
    }

    /// `orgRoutes/check`: what one small request from the control plane found, in words.
    struct OrgRouteCheck: Codable, Sendable, Hashable {
        public var ok: Bool
        public var words: String

        public init(ok: Bool, words: String) {
            self.ok = ok
            self.words = words
        }
    }

    /// A route the caller may use: no settings, no fingerprint (spec FR-026).
    struct OrgRouteMine: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String
        public var runtimes: [String]
        public var defaultFor: [String]

        public init(id: String, name: String, kind: String, runtimes: [String], defaultFor: [String] = []) {
            self.id = id
            self.name = name
            self.kind = kind
            self.runtimes = runtimes
            self.defaultFor = defaultFor
        }
    }

    /// `orgRoutes/mine`.
    struct OrgRoutesMine: Codable, Sendable, Hashable {
        public var routes: [OrgRouteMine]

        public init(routes: [OrgRouteMine]) {
            self.routes = routes
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `OrgRoutesMine`: the routes the caller may use (#999).
    static let orgRoutesMine = "orgRoutes/mine"
    /// `Empty` → `OrgRouteList`: an admin's (#999).
    static let orgRoutesList = "orgRoutes/list"
    /// `OrgRouteSet` → `OrgRouteKept`: an admin's (#999).
    static let orgRoutesSet = "orgRoutes/set"
    /// `OrgRouteReplaceKey` → `OrgRouteKept`: an admin's (#999).
    static let orgRoutesReplaceKey = "orgRoutes/replaceKey"
    /// `OrgRouteRequest` → `OrgRouteCheck`: an admin's (#999).
    static let orgRoutesCheck = "orgRoutes/check"
    /// `OrgRouteRequest` → `{}`: an admin's (#999).
    static let orgRoutesRemove = "orgRoutes/remove"
}

public extension DaemonAPI.Notification {
    /// `Empty`: read the routes again (#999).
    static let controlOrgRoutesChanged = "control/orgRoutesChanged"
}
