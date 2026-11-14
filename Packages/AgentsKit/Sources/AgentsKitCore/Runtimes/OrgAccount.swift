import Foundation

/// The organisation's ways to the model (#999, spec 999): an org key, or a gateway (Amazon
/// Bedrock, Google Vertex AI, Microsoft Azure, a base URL), kept by the control plane with its
/// secrets sealed by an admin's client to each machine that may use it (#3397, `ClientSealing`):
/// the control plane cannot open them. An admin manages them in Console ▸
/// Model Access on the web page; the window and the Remote show the routes a person may use, read
/// only, in Settings ▸ Policy. The types are hand-written against `Packages/Wire/schema`
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
        /// One more each time the secrets or where they go change (#3397).
        public var sealVersion: Int?
        public var created: OrgRouteStamp?
        public var changed: OrgRouteStamp?
        public var machines: Int?
        /// The machines that may use it and have no copy yet (#3397).
        public var waiting: Int?

        public init(id: String, name: String, kind: String, vendor: String? = nil, runtimes: [String],
                    settings: OrgRouteSettings? = nil, models: [String: String]? = nil, groups: [String]? = nil,
                    defaultFor: [String]? = nil, secretFields: [String]? = nil, fingerprint: [String: String]? = nil,
                    version: Int? = nil, sealVersion: Int? = nil, created: OrgRouteStamp? = nil, changed: OrgRouteStamp? = nil,
                    machines: Int? = nil, waiting: Int? = nil) {
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
            self.sealVersion = sealVersion
            self.created = created
            self.changed = changed
            self.machines = machines
            self.waiting = waiting
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

    /// `orgRoutes/list`: every route.
    struct OrgRouteList: Codable, Sendable, Hashable {
        public var routes: [OrgRouteKept]

        public init(routes: [OrgRouteKept]) {
            self.routes = routes
        }
    }

    /// A route's secrets as an admin's client sealed them (#3397): every field, to every
    /// recipient, by recipient and then by field.
    struct OrgRouteSealed: Codable, Sendable, Hashable {
        public var sealVersion: Int
        public var fingerprint: [String: String]
        public var values: [String: [String: Envelope]]

        public init(sealVersion: Int, fingerprint: [String: String], values: [String: [String: Envelope]]) {
            self.sealVersion = sealVersion
            self.fingerprint = fingerprint
            self.values = values
        }
    }

    /// `orgRoutes/set`: a route to add or change; its secrets sealed by the client, or none to
    /// keep them as they are.
    struct OrgRouteSet: Codable, Sendable, Hashable {
        public var route: OrgRoute
        public var sealed: OrgRouteSealed?
        public var rev: String?

        public init(route: OrgRoute, sealed: OrgRouteSealed? = nil, rev: String? = nil) {
            self.route = route
            self.sealed = sealed
            self.rev = rev
        }
    }

    /// `orgRoutes/replaceKey`: new values for every one of a route's secret fields, sealed.
    struct OrgRouteReplaceKey: Codable, Sendable, Hashable {
        public var id: String
        public var sealed: OrgRouteSealed
        public var rev: String

        public init(id: String, sealed: OrgRouteSealed, rev: String) {
            self.id = id
            self.sealed = sealed
            self.rev = rev
        }
    }

    /// `orgRoutes/recipients`: the groups a route is for; none for everyone (#3397).
    struct OrgRouteRecipientsRequest: Codable, Sendable, Hashable {
        public var groups: [String]?

        public init(groups: [String]? = nil) { self.groups = groups }
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

    /// `orgRoutes/check`: what one small request from a machine that holds the route found, in words.
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
        /// One of the caller's machines may use it and waits for an admin's app to seal it (#3397).
        public var waiting: Bool?

        public init(id: String, name: String, kind: String, runtimes: [String], defaultFor: [String] = [], waiting: Bool? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.runtimes = runtimes
            self.defaultFor = defaultFor
            self.waiting = waiting
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
    /// `OrgRouteRecipientsRequest` → `SealRecipients`: an admin's (#3397).
    static let orgRoutesRecipients = "orgRoutes/recipients"
    /// `OrgRouteRequest` → `SealingItem`: an admin's own copy (#3397).
    static let orgRoutesSealed = "orgRoutes/sealed"
}

public extension DaemonAPI.Notification {
    /// `Empty`: read the routes again (#999).
    static let controlOrgRoutesChanged = "control/orgRoutesChanged"
}
