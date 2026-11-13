#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Client sealing (#3397, `specs/3397-client-sealing`): a client seals an org route's secrets,
/// and a person's own secrets, with HPKE straight to each machine (and each client) that may hold
/// them. The control plane keeps and sends the envelopes and never opens one. The window and the
/// Remote seal again for a machine that joined, or a client paired, after a value was sealed:
/// `ClientSealing.sealWaiting`, at each connection and on `control/sealingWanted`.
/// The types are hand-written against `Packages/Wire/daemon.schema.json` (`WireSchemaTests`).
public extension DaemonAPI {
    /// A machine or a client to seal to: `m:<machine id>` or `c:<CLIENT ID>`, and its key.
    struct SealRecipient: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        /// A machine's person, whose lock names its key (#3491, D8); nil for a client.
        public var owner: String?
        /// P256, X9.63, 65 bytes.
        public var publicKey: Data

        public init(id: String, name: String, owner: String? = nil, publicKey: Data) {
            self.id = id
            self.name = name
            self.owner = owner
            self.publicKey = publicKey
        }
    }

    /// `orgRoutes/recipients` and `user/secretRecipients`; `user` is the person a secret is for.
    struct SealRecipients: Codable, Sendable, Hashable {
        public var recipients: [SealRecipient]
        public var user: String?
    }

    /// What a sealing item is.
    enum SealingItemKind: String, Codable, Sendable, Hashable {
        case orgRoute, userSecret
    }

    /// `sealing/work` and `orgRoutes/sealed`: a value this client has a copy of (`mine`, by
    /// field; a person's secret has the one field `value`), what makes its associated data, and
    /// the recipients that have none.
    struct SealingItem: Codable, Sendable, Hashable {
        public var item: SealingItemKind
        public var id: String
        public var user: String?
        public var version: Int
        public var kind: String?
        public var vendor: String?
        public var settings: OrgRouteSettings?
        /// Ask before use (#4014), for a person's secret: every copy's associated data ends `|ask`.
        public var needsApproval: Bool?
        public var mine: [String: Envelope]
        public var missing: [SealRecipient]
    }

    /// `sealing/work`.
    struct SealingWork: Codable, Sendable, Hashable {
        public var items: [SealingItem]
    }

    /// One item of `sealing/add`: copies by recipient, then by field.
    struct SealingAddItem: Codable, Sendable, Hashable {
        public var item: SealingItemKind
        public var id: String
        public var version: Int
        public var values: [String: [String: Envelope]]

        public init(item: SealingItemKind, id: String, version: Int, values: [String: [String: Envelope]]) {
            self.item = item
            self.id = id
            self.version = version
            self.values = values
        }
    }

    /// `sealing/add`.
    struct SealingAdd: Codable, Sendable, Hashable {
        public var items: [SealingAddItem]

        public init(items: [SealingAddItem]) { self.items = items }
    }
}

public extension DaemonAPI.Method {
    /// `{}` → `SealingWork` (#3397).
    static let sealingWork = "sealing/work"
    /// `SealingAdd` → `{}` (#3397).
    static let sealingAdd = "sealing/add"
}

public extension DaemonAPI.Notification {
    /// `{}`: something waits for this client to seal it; call `sealing/work` (#3397).
    static let controlSealingWanted = "control/sealingWanted"
}

#if canImport(CryptoKit)
/// The associated data and the seal of #3397, byte for byte Go's `controllink.OrgRouteAD` and
/// `UserSecretAD`, and the web page's `Web/src/wire/sealing.ts`.
public enum ClientSealing {
    public static let orgRoutePurpose = "com.alexecollins.agents.orgroute.v3"
    public static let userSecretPurpose = "com.alexecollins.agents.usersecret.v1"

    /// A client as a recipient: its id in upper case.
    public static func clientRecipient(_ client: UUID) -> String { "c:" + client.uuidString.uppercased() }

    /// The hex SHA-256 of a route's settings, one `name=value` line each, in this order.
    public static func binding(_ settings: DaemonAPI.OrgRouteSettings?) -> String {
        let s = settings ?? DaemonAPI.OrgRouteSettings()
        let lines: [(String, String?)] = [("address", s.address), ("apiVersion", s.apiVersion), ("clientID", s.clientID),
                                          ("header", s.header), ("location", s.location), ("project", s.project),
                                          ("region", s.region), ("resource", s.resource), ("tenant", s.tenant)]
        let text = lines.compactMap { name, value in value.map { "\(name)=\($0)\n" } }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func orgRouteAD(route: String, recipient: String, field: String, sealVersion: Int, kind: String,
                                  vendor: String?, settings: DaemonAPI.OrgRouteSettings?) -> Data {
        Data("orgroute.v3|\(route)|\(recipient)|\(field)|\(sealVersion)|\(kind)|\(vendor ?? "")|\(binding(settings))".utf8)
    }

    /// Ask before use (#4014) adds `|ask`, as Go's `UserSecretADAsk`, so a flag the control plane
    /// changed does not open.
    public static func userSecretAD(user: String, recipient: String, name: String, version: Int, ask: Bool = false) -> Data {
        Data("usersecret.v1|\(user)|\(recipient)|\(name)|\(version)\(ask ? "|ask" : "")".utf8)
    }

    /// A person's secret sealed to each recipient.
    public static func sealSecret(user: String, name: String, version: Int, value: String, ask: Bool = false,
                                  to recipients: [DaemonAPI.SealRecipient]) throws -> [String: Envelope] {
        var out: [String: Envelope] = [:]
        for r in recipients {
            out[r.id] = try Envelope.seal(Data(value.utf8), to: r.publicKey, info: userSecretPurpose,
                                          authenticating: userSecretAD(user: user, recipient: r.id, name: name, version: version, ask: ask))
        }
        return out
    }

    /// This client's copy of an item, opened, by field: in memory only.
    public static func open(_ item: DaemonAPI.SealingItem, with key: DeviceKey, client: UUID) throws -> [String: Data] {
        let me = clientRecipient(client)
        var out: [String: Data] = [:]
        for (field, sealed) in item.mine {
            switch item.item {
            case .userSecret:
                out[field] = try key.open(sealed, info: userSecretPurpose,
                                          authenticating: userSecretAD(user: item.user ?? "", recipient: me, name: item.id, version: item.version,
                                                                       ask: item.needsApproval == true))
            case .orgRoute:
                out[field] = try key.open(sealed, info: orgRoutePurpose,
                                          authenticating: orgRouteAD(route: item.id, recipient: me, field: field, sealVersion: item.version,
                                                                     kind: item.kind ?? "", vendor: item.vendor, settings: item.settings))
            }
        }
        return out
    }

    /// `user/sealedSecret`'s copy (#5114, #5115), opened with this client's own key, to reveal or
    /// copy it: in memory only. `user` is the person (`user/secretRecipients`'s `user`).
    public static func open(_ secret: DaemonAPI.UserSealedSecret, user: String, with key: DeviceKey, client: UUID) throws -> String {
        let plain = try key.open(secret.sealed, info: userSecretPurpose,
                                 authenticating: userSecretAD(user: user, recipient: clientRecipient(client), name: secret.name,
                                                              version: secret.version, ask: secret.needsApproval == true))
        return String(decoding: plain, as: UTF8.self)
    }

    /// What `sealing/work` asks, sealed for each recipient missing. An item whose copy does not
    /// open here (its route's address changed since an admin sealed it) is left out.
    public static func seal(_ work: DaemonAPI.SealingWork, with key: DeviceKey, client: UUID) -> [DaemonAPI.SealingAddItem] {
        work.items.compactMap { item in
            guard let values = try? open(item, with: key, client: client) else { return nil }
            var sealed: [String: [String: Envelope]] = [:]
            for r in item.missing {
                for (field, value) in values {
                    let info: String
                    let ad: Data
                    switch item.item {
                    case .userSecret:
                        info = userSecretPurpose
                        ad = userSecretAD(user: item.user ?? "", recipient: r.id, name: item.id, version: item.version,
                                          ask: item.needsApproval == true)
                    case .orgRoute:
                        info = orgRoutePurpose
                        ad = orgRouteAD(route: item.id, recipient: r.id, field: field, sealVersion: item.version,
                                        kind: item.kind ?? "", vendor: item.vendor, settings: item.settings)
                    }
                    guard let e = try? Envelope.seal(value, to: r.publicKey, info: info, authenticating: ad) else { return nil }
                    sealed[r.id, default: [:]][field] = e
                }
            }
            return DaemonAPI.SealingAddItem(item: item.item, id: item.id, version: item.version, values: sealed)
        }
    }

    /// Seals what waits for a copy this client can make: `sealing/work`, then `sealing/add`.
    /// Quiet when the control plane is older, or nothing waits. `signed` leaves out each machine
    /// whose key its owner's lock does not name (#3491, D8).
    public static func sealWaiting(on control: DaemonClient, key: DeviceKey, client: UUID, isolation: isolated (any Actor)? = #isolation,
                                   signed: ([DaemonAPI.SealRecipient]) async -> [DaemonAPI.SealRecipient]) async {
        guard var work = try? await control.call(DaemonAPI.Method.sealingWork, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.SealingWork.self), !work.items.isEmpty else { return }
        for i in work.items.indices { work.items[i].missing = await signed(work.items[i].missing) }
        work.items.removeAll { $0.missing.isEmpty }
        let items = seal(work, with: key, client: client)
        guard !items.isEmpty else { return }
        _ = try? await control.call(DaemonAPI.Method.sealingAdd, DaemonAPI.SealingAdd(items: items))
    }
}
#endif
