import Foundation

// The wire's host/* and hosts/* methods are renamed machine/* and machines/* over three
// releases (#2653): this tree's documents, and so every `DaemonAPI.Method` constant below,
// keep the old names until the last one, but a sender sends the new name. newMethodName is
// applied once, at each physical place a method is put on the wire (JSONRPCConnection.call,
// ControlUplink, ControlRelay, ControlCodeUse.announce), so the typed (old) names stay put
// everywhere else, including the schema-consistency tests.
public extension DaemonAPI {
    private static let renamed: [(new: String, old: String)] = [("machine/", "host/"), ("machines/", "hosts/")]

    /// method's new name: a host/* or hosts/* method sent as machine/* or machines/* (#2653).
    static func newMethodName(_ method: String) -> String {
        for pair in renamed where method.hasPrefix(pair.old) {
            return pair.new + method.dropFirst(pair.old.count)
        }
        return method
    }
}

/// What the control plane answers itself, and says (058, contracts/control-api.md).
public extension DaemonAPI.Method {
    static let controlStatus = "control/status"
    static let hostsList = "hosts/list"
    static let hostsStartEnroll = "hosts/startEnroll"
    static let hostsInstall = "hosts/install"
    static let hostsCheckAgain = "hosts/checkAgain"
    static let hostsUpdate = "hosts/update"
    static let hostsRemove = "hosts/remove"
    /// `{host, relay}`: whether a host carries the person's devices through iCloud (T097).
    static let hostsSetRelay = "hosts/setRelay"
    /// `{host, from, runtime, allowed}`: whether `host` may use `from`'s sign-in for a
    /// runtime, relayed through the control plane (058, T091). An operator's, after the
    /// window asked the person.
    static let hostsLendSignIn = "hosts/lendSignIn"
    /// `LendGit`: whether `host` may use `from`'s git access for one git server (#1122).
    /// Any client's, after it asked the person; a no ends a waiting ask.
    static let hostsLendGit = "hosts/lendGit"
    /// `hosts/detect` (#429): every server in the control plane's `~/.ssh/config` that
    /// answers, added as `hosts/install` would with no key. `[DetectedServer]`.
    static let hostsDetect = "hosts/detect"
    /// `hosts/sshHosts` (#610): the hosts in the control plane's ssh config, as `ssh -G`
    /// resolves each, with no network. `{destination}` resolves just that, as typed.
    /// `[SSHHost]`.
    static let hostsSSHHosts = "hosts/sshHosts"
    /// `FolderDetection` (#429, #656): whether the window suggests folders on a host, and
    /// where it looks for them. Nothing is added unless the person picks it.
    static let controlSetFolderDetection = "control/setFolderDetection"
    /// `Empty` → `Empty`, an admin's only (#997): a new control key; members take it as
    /// they connect again, with no new pairing.
    static let controlRotate = "control/rotate"
    /// A host, on its channel 0 (T091): a tunnel to the host that lends it a sign-in.
    static let tunnelOpen = "tunnel/open"
    /// On the Mac's host (T091): start relaying a runtime's sign-in, and say what a server
    /// needs to use it. Never the token.
    static let relayGrant = "relay/grant"
    /// `GitCredentialRequest` → `GitCredential` (#1122). Asked by the host's own git, through
    /// `agentsd git-credential`, of its daemon on its socket only; then by that host of the
    /// control plane on its channel 0.
    static let gitCredential = "git/credential"
    /// `GitCredentialRequest` → `GitCredential`: the control plane, on the lending host's
    /// channel 0 (#1122), for a lend an operator allowed. Nothing else can ask it.
    static let gitFill = "git/fill"
    static let clientsList = "clients/list"
    static let clientsStartPairing = "clients/startPairing"
    static let clientsStopPairing = "clients/stopPairing"
    static let clientsAnnounce = "clients/announce"
    /// Retired with grants (#111): an older window that asks is told there is nothing to
    /// set.
    static let clientsSetGrant = "clients/setGrant"
    static let clientsForget = "clients/forget"
    /// A client forgets itself, and only itself (071 FR-015).
    static let clientsForgetSelf = "clients/forgetSelf"
    /// How each client reaches the control plane now (frame N, T080).
    static let clientsConnections = "clients/connections"
    /// `PushToken` (#1460): a device's own APNs token, for the control plane to push to
    /// when no Mac host relays its notices. Only the device sets its own.
    static let clientsSetPushToken = "clients/setPushToken"
    /// A browser's Web Push subscription (#1486), set by the page over its own session, and the
    /// control plane's VAPID key it subscribes with. Only the web page calls them.
    static let clientsSetWebPush = "clients/setWebPush"
    static let clientsWebPushKey = "clients/webPushKey"
    /// `ActivityToken` (#1744): the push token of one session's Live Activity on a device,
    /// for the control plane to update it by APNs. Only the device sets its own.
    static let clientsSetActivityToken = "clients/setActivityToken"

    // A host, on its channel 0.
    static let hostsAnnounce = "hosts/announce"
    static let hostHello = "host/hello"
    static let attentionNeed = "attention/need"
    static let controlPing = "control/ping"
    /// To a host just added, on its channel 0 (#429), never answered: `FolderDetection`.
    /// Sent only by a control plane before #656; a host since says `folders/detected` with
    /// nothing added.
    static let foldersDetect = "folders/detect"
    /// A host, on its channel 0 (#429): its answer to `folders/detect`. `{added}`.
    static let foldersDetected = "folders/detected"

    // To a relay host, on its channel 0 (058, T096–T097): notifications, never answered.
    /// `RelayDevices`: the devices it may carry for, with their keys.
    static let relayDevices = "relay/devices"
    /// `RelayDelivery`: one mailbox item to seal and post.
    static let relayDeliver = "relay/deliver"
    /// `RelayCount` (#1163): one device's Needs you count, to post as a silent push.
    static let relayCount = "relay/count"
    /// A relay host, on its channel 0 (#824): `RelaySwitch`, itself switched on or off,
    /// as `hosts/setRelay` would. What Agents Host has it say where it has no control
    /// plane's key (Join one elsewhere). Refused from a host that runs agents.
    static let relaySwitch = "relay/switch"
}

public extension DaemonAPI.Notification {
    static let controlHostChanged = "control/hostChanged"
    static let controlClientChanged = "control/clientChanged"
    static let controlPairingChanged = "control/pairingChanged"
    /// `WebRemoteStatus`: the web remote's listener started, or could not (071 R3).
    static let controlWebChanged = "control/webChanged"
    /// `MachineJoinStatus`: this Mac's host's join changed, as it said it (#113).
    static let controlThisMacHostChanged = "control/thisMacHostChanged"
    static let controlInstallProgress = "control/installProgress"
    /// `MachineTunnelChanged`: a server's reverse tunnel over ssh came up or went down (#435).
    static let controlTunnelChanged = "control/tunnelChanged"
    /// To a device on the old way, after the move (058, T085): `ControlMoved`.
    static let controlMoved = "control/moved"
}

public extension DaemonAPI {
    /// `clients/setPushToken` (#1460): a device's APNs token, in hex, and which APNs it is
    /// from. No token takes it away.
    struct PushToken: Codable, Sendable, Hashable {
        public enum Environment: String, Codable, Sendable {
            case development, production

            /// A Debug build is signed for the sandbox; TestFlight and the App Store for production.
            public static var ofThisBuild: Environment {
                #if DEBUG
                .development
                #else
                .production
                #endif
            }
        }

        public var token: String?
        public var environment: Environment

        public init(token: Data?, environment: Environment) {
            self.token = token.map { $0.map { String(format: "%02x", $0) }.joined() }
            self.environment = environment
        }
    }

    /// `clients/setActivityToken` (#1744): the push token of one session's Live Activity,
    /// in hex, which APNs it is from, and when the turn began. No token takes it away.
    struct ActivityToken: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var token: String?
        public var environment: PushToken.Environment
        public var startedAt: Date

        public init(agentID: UUID, token: Data?, environment: PushToken.Environment, startedAt: Date) {
            self.agentID = agentID
            self.token = token.map { $0.map { String(format: "%02x", $0) }.joined() }
            self.environment = environment
            self.startedAt = startedAt
        }
    }

    /// `control/status`.
    struct ControlStatus: Codable, Sendable, Hashable {
        public var name: String
        public var version: String
        public var homeHost: MachineRef?
        public var machineID: String
        /// When this run of the control plane started (frame D).
        public var startedAt: Date?
        /// The port clients and hosts reach it on over the network, if it listens on one.
        public var port: Int?
        /// Whether devices reach it through iCloud when away from home (R6).
        public var awayFromHome: Bool?
        /// The asking client's own record, so a window can mark itself "you".
        public var you: UUID?
        /// The public key of the host that relays through iCloud, if one does (T077): what a
        /// device keeps so it can reach the control plane through the relay when away.
        public var relayKey: Data?
        /// The web remote's loopback listener (071 R3): whether the page is served, and why
        /// not. Nil when this copy was not asked to serve it.
        public var web: WebRemoteStatus?
        /// Where a browser anywhere opens the page, on the control plane's own domain
        /// (#1459): its https address. Nil when it serves no page there.
        public var publicWeb: String?
        /// The origin of the sandbox proxy that draws MCP Apps views on that page (#1484): a
        /// second name in front of the same control plane. Nil when it draws none there.
        public var publicViews: String?
        /// This Mac's host, as it says its join stands (#113), when the control plane runs
        /// beside it: "Couldn't join the control plane: …". Nil elsewhere.
        public var thisMacHost: MachineJoinStatus?
        /// Where a host added from now on has its folders found (#429). Nil from a control
        /// plane older than that.
        public var folderDetection: FolderDetection?
        /// Servers installed over an ssh tunnel that have not joined yet (#660), each with how
        /// its tunnel stands: they have no host row, so this is where ssh's reason shows.
        /// Nil from a control plane older than that, or one that holds no tunnels.
        public var unjoinedTunnels: [MachineTunnelChanged]?
        /// The control plane's own capabilities, and what it requires of hosts and clients
        /// (#1748). Nil from a control plane older than that.
        public var capabilities: [String]?
        public var required: RequiredCapabilities?
        /// Who this client belongs to (#994). Nil from a control plane older than people.
        public var person: ControlPerson?
        /// The one line to run on a server so that it asks to join as this client's person,
        /// with no code (#994). Nil from a control plane that does not say.
        public var joinCommand: String?

        public init(name: String, version: String, homeHost: MachineRef?, machineID: String,
                    startedAt: Date? = nil, port: Int? = nil, awayFromHome: Bool? = nil) {
            self.name = name
            self.version = version
            self.homeHost = homeHost
            self.machineID = machineID
            self.startedAt = startedAt
            self.port = port
            self.awayFromHome = awayFromHome
        }
    }

    /// Whether the control plane serves the web remote on its loopback port (071 R3): what
    /// Agents Host's row and the window's Settings say, rather than the address regardless.
    struct WebRemoteStatus: Codable, Sendable, Hashable {
        /// The port asked for: 8792 for Agents Host's copy.
        public var port: Int
        public var served: Bool
        /// Why not, when it isn't: `portInUse`, `build` or `failed`.
        public var reason: String?
        /// The error as the control plane met it.
        public var detail: String?

        public static let portInUse = "portInUse"
        public static let build = "build"
        public static let failed = "failed"

        public init(port: Int, served: Bool, reason: String? = nil, detail: String? = nil) {
            self.port = port
            self.served = served
            self.reason = reason
            self.detail = detail
        }

        public var address: String { "http://localhost:\(port)" }

        /// In plain words, for the row that would otherwise give the address.
        public var summary: String {
            if served { return "At \(address), for a browser on this Mac only." }
            switch reason {
            case Self.portInUse: return "Not serving: port \(port) is in use by another app."
            case Self.build: return "Not serving: this copy of Agents Host’s web app is damaged or missing."
            default: return "Not serving: port \(port) couldn’t be opened\(detail.map { " (\($0))" } ?? "")."
            }
        }
    }

    /// What the control plane needs of a host and of a client to route for it (#1748).
    struct RequiredCapabilities: Codable, Sendable, Hashable {
        public var host: [String]
        public var client: [String]
        public init(host: [String], client: [String]) {
            self.host = host
            self.client = client
        }
    }

    /// One row of `hosts/list`.
    struct ControlMachine: Codable, Sendable, Hashable, Identifiable {
        public var id: MachineRef
        public var name: String
        public var platform: String
        public var version: String
        /// `online`, `offline`, `connecting`, `needsUpdate` or `failed`; for a host linked to
        /// a workspace (#691) also `stopped`, `starting` or `stopping`.
        public var state: String
        public var reach: String
        public var machineID: String?
        /// A relay host (`agents-relay`): it carries devices through iCloud and runs no agents.
        /// True while it relays, false while it is switched off, nil on a host that runs agents.
        public var relay: Bool?
        /// Not a relay host. A relay switched off is still a relay (`relay` false), and still
        /// runs no agents (#1507).
        public var runsAgents: Bool { relay == nil }
        /// The hosts whose sign-in this one may use, by runtime (T091).
        public var signInFrom: [String: MachineRef]?
        /// The hosts whose git access this one may use, by git server (#1122).
        public var gitFrom: [String: MachineRef]?
        /// Its git asking to use a host's git access, waiting on a person's answer (#1122).
        public var gitAsks: [GitAsk]?
        /// A server behind a bastion dials the control plane through a reverse tunnel the
        /// control plane holds over ssh (#435): how that session stands. Nil for a host
        /// that dials it directly.
        public var tunnel: MachineTunnel?
        /// The provider's workspace it runs on, which can be started and stopped (#691).
        public var workspace: MachineWorkspace?
        /// `swift` or `go`, as the host said in `host/hello` (#1134); nil when it never said.
        public var implementation: String?
        /// The capabilities the host said in its last `host/hello` (#1748); nil from a host
        /// older than that, which is taken to have them all.
        public var capabilities: [String]?
        /// Of the control plane's required capabilities, the ones it does not have: it is
        /// then `needsUpdate`.
        public var missing: [String]?

        /// Whether the host answers calls: `online`, or `needsUpdate`, which is connected and
        /// serves what its list says (#1771). Its features are gated by `has(_:)`.
        public var answers: Bool { Self.answers(state) }

        /// Whether a host in `state` answers calls (`answers`), for a state read from a notification.
        public static func answers(_ state: String?) -> Bool { state == "online" || state == "needsUpdate" }

        /// Whether the host can do what `capability` names (`Capability.chatBranch1`). True for
        /// a host that said no list: it works as it did before capabilities (#1748).
        public func has(_ capability: String) -> Bool {
            capabilities?.contains(capability) ?? true
        }
        /// The user who owns the machine (#994).
        public var owner: String?

        public init(id: MachineRef, name: String, platform: String, version: String, state: String,
                    reach: String, machineID: String?, relay: Bool? = nil) {
            self.relay = relay
            self.id = id
            self.name = name
            self.platform = platform
            self.version = version
            self.state = state
            self.reach = reach
            self.machineID = machineID
        }
    }

    /// One host in the ssh config, and what `hosts/detect` did with it (#429).
    struct DetectedServer: Codable, Sendable, Hashable, Identifiable {
        public enum Outcome: String, Codable, Sendable {
            /// It answered, and was installed: it joins by itself.
            case added
            /// A host by that name is already on the control plane.
            case known
            /// Another host's `ProxyJump` or `ProxyCommand` goes through it.
            case bastion
            /// It did not answer, or would not let ssh in without a prompt.
            case unreachable
            /// It answered, and the install failed.
            case failed
        }

        /// The `Host` name in the config.
        public var alias: String
        /// `user@hostname:port`, as `ssh -G` resolved it.
        public var resolved: String
        public var outcome: Outcome
        /// Why, in words, when it was not added.
        public var detail: String?

        public var id: String { alias }

        public init(alias: String, resolved: String, outcome: Outcome, detail: String? = nil) {
            self.alias = alias
            self.resolved = resolved
            self.outcome = outcome
            self.detail = detail
        }
    }

    /// A server ssh knows by a name, for Add a Machine's server box (#610).
    struct SSHHost: Codable, Sendable, Hashable, Identifiable {
        /// The `Host` name in the config, or the destination as typed.
        public var alias: String
        /// `user@hostname:port`, as `ssh -G` resolved it.
        public var resolved: String
        /// Reached through a `ProxyJump` or `ProxyCommand`: it rarely can dial back, so a
        /// tunnel is the default.
        public var throughBastion: Bool
        /// Another host's way in, not a server to add.
        public var isBastion: Bool
        /// A host by that name is on the control plane already.
        public var known: Bool

        public var id: String { alias }

        public init(alias: String, resolved: String, throughBastion: Bool, isBastion: Bool = false, known: Bool = false) {
            self.alias = alias
            self.resolved = resolved
            self.throughBastion = throughBastion
            self.isBastion = isBastion
            self.known = known
        }
    }

    /// A reverse tunnel over ssh to the control plane, held for one server (#435).
    struct MachineTunnel: Codable, Sendable, Hashable {
        /// Whether ssh has the server's end of the tunnel open now.
        public var up: Bool
        /// Why it is down, in ssh's words, when it said any.
        public var problem: String?

        public init(up: Bool, problem: String? = nil) {
            self.up = up
            self.problem = problem
        }
    }

    /// `control/tunnelChanged`: by name, since a server's tunnel is up before it joins.
    struct MachineTunnelChanged: Codable, Sendable, Hashable {
        public var name: String
        public var host: MachineRef?
        public var tunnel: MachineTunnel

        public init(name: String, host: MachineRef?, tunnel: MachineTunnel) {
            self.name = name
            self.host = host
            self.tunnel = tunnel
        }
    }

    /// `control/hostChanged`.
    struct ControlHostChanged: Codable, Sendable, Hashable {
        public var host: MachineRef
        /// As in `ControlMachine.state`, or `removed`.
        public var state: String
        /// As in `ControlMachine.workspace`.
        public var workspace: MachineWorkspace?
    }

    /// `host/hello`, on every connect of an uplink.
    struct MachineHello: Codable, Sendable, Hashable {
        /// Which host this is. Said only on the control plane's local socket, where the
        /// uid and the code signature are the door; over TLS the key says it, and this
        /// is ignored.
        public var host: MachineRef?
        public var version: String
        public var platform: String
        public var machineID: String
        public var name: String?
        /// Said by `agents-relay` (T096): this host only relays, and gets no client channels.
        public var relay: Bool?
        /// The language the host is written in, `swift` or `go` (#1134), shown beside its
        /// version in Hosts. Nil from a host built before it was said.
        public var implementation: String?

        public init(host: MachineRef? = nil, version: String, platform: String, machineID: String, name: String? = nil,
                    relay: Bool? = nil, implementation: String? = nil) {
            self.relay = relay
            self.implementation = implementation
            self.host = host
            self.version = version
            self.platform = platform
            self.machineID = machineID
            self.name = name
        }
    }

    /// `attention/need`, unsealed, on a host's channel 0 (058, R6).
    ///
    /// A host no longer knows devices, so it cannot seal. It sends the need and whether
    /// it should buzz; `{withdraw}` is the need being over. The control plane chooses
    /// the device and seals.
    ///
    /// `waiting` is the host's whole Needs you count, the badge's (#1163): carried by every
    /// offer and withdrawal, and said on its own (`{waiting}`) when it moves with no need
    /// to offer, so a phone hears a count that changed at the Mac. Nil from an older host.
    struct AttentionNeed: Codable, Sendable, Hashable {
        public var need: Need?
        public var headline: Headline?
        public var buzz: Bool?
        public var withdraw: NeedID?
        public var waiting: Int?

        public init(need: Need?, headline: Headline?, buzz: Bool?, withdraw: NeedID?, waiting: Int? = nil) {
            self.need = need
            self.headline = headline
            self.buzz = buzz
            self.withdraw = withdraw
            self.waiting = waiting
        }

        public static func offer(_ need: Need, buzz: Bool, waiting: Int? = nil) -> AttentionNeed {
            AttentionNeed(need: need, headline: need.headline, buzz: buzz, withdraw: nil, waiting: waiting)
        }

        public static func withdraw(_ id: NeedID, waiting: Int? = nil) -> AttentionNeed {
            AttentionNeed(need: nil, headline: nil, buzz: nil, withdraw: id, waiting: waiting)
        }

        /// The count alone: nothing to offer or withdraw (#1163).
        public static func count(_ waiting: Int) -> AttentionNeed {
            AttentionNeed(need: nil, headline: nil, buzz: nil, withdraw: nil, waiting: waiting)
        }
    }


    /// `clients/forget`, `hosts/remove`.
    struct ClientRequest: Codable, Sendable, Hashable {
        public var client: UUID
        public init(client: UUID) { self.client = client }
    }

    struct MachineRequest: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var purge: Bool?
        public init(host: MachineRef, purge: Bool? = nil) {
            self.host = host
            self.purge = purge
        }
    }

    /// One row of `clients/connections`: a client connected now, and how.
    struct ClientConnection: Codable, Sendable, Hashable {
        public var client: UUID
        /// Only through the iCloud relay.
        public var relayed: Bool
        /// The relaying host's name, when relayed.
        public var through: String?
        public init(client: UUID, relayed: Bool, through: String? = nil) {
            self.client = client
            self.relayed = relayed
            self.through = through
        }
    }

    /// `control/moved`: where the control plane is now, told to a device over the old
    /// bridge link or relay it already trusts. It dials there as itself, with the key it
    /// paired with, which the move gave the control plane (T084–T085).
    struct ControlMoved: Codable, Sendable, Hashable {
        public var url: String
        public var pin: String?
        public var controlKey: Data
        public var name: String
        public init(url: String, pin: String?, controlKey: Data, name: String) {
            self.url = url
            self.pin = pin
            self.controlKey = controlKey
            self.name = name
        }
    }

    /// `hosts/lendSignIn`.
    struct LendSignIn: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var from: MachineRef
        public var runtime: String
        public var allowed: Bool
        public init(host: MachineRef, from: MachineRef, runtime: String, allowed: Bool) {
            self.host = host
            self.from = from
            self.runtime = runtime
            self.allowed = allowed
        }
    }

    /// `tunnel/open`, from the borrowing host.
    struct TunnelOpen: Codable, Sendable, Hashable {
        public var runtime: String
        public var ref: String
        public init(runtime: String, ref: String) {
            self.runtime = runtime
            self.ref = ref
        }
    }

    /// `relay/grant`'s request and answer: what the borrowing host's gate needs. The
    /// stand-in holds no secret of the Mac's (S4).
    struct RelayGrantRequest: Codable, Sendable, Hashable {
        public var runtime: String
        public init(runtime: String) { self.runtime = runtime }
    }

    struct RelayGrantReply: Codable, Sendable, Hashable {
        public var runtime: String
        public var caCertificate: String
        public var standIn: String
        public init(runtime: String, caCertificate: String, standIn: String) {
            self.runtime = runtime
            self.caCertificate = caCertificate
            self.standIn = standIn
        }
    }

    /// `relay/switch` (#824): the relay host that says it, on or off.
    struct RelaySwitch: Codable, Sendable, Hashable {
        public var relay: Bool
        public init(relay: Bool) { self.relay = relay }
    }

    /// `hosts/setRelay`.
    struct MachineRelayRequest: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var relay: Bool
        public init(host: MachineRef, relay: Bool) {
            self.host = host
            self.relay = relay
        }
    }

    /// `relay/devices`: every device client, with the key its frames are sealed to.
    struct RelayDevices: Codable, Sendable, Hashable {
        public struct Device: Codable, Sendable, Hashable {
            public var id: UUID
            public var publicKey: Data
            public init(id: UUID, publicKey: Data) {
                self.id = id
                self.publicKey = publicKey
            }
        }
        public var devices: [Device]
        public init(devices: [Device]) { self.devices = devices }
    }

    /// `relay/deliver`: what the control plane chose (T097). The relay host seals the
    /// headline to `publicKey` and posts it for `device`; no headline is a withdrawal.
    /// `waiting` is the count across the hosts at that moment, as `RelayCount` says it (#1163).
    struct RelayDelivery: Codable, Sendable, Hashable {
        public var needID: NeedID
        public var device: UUID
        public var publicKey: Data?
        public var headline: Headline?
        public var alert: Bool
        public var waiting: Int?
        public init(needID: NeedID, device: UUID, publicKey: Data? = nil, headline: Headline? = nil, alert: Bool = false,
                    waiting: Int? = nil) {
            self.needID = needID
            self.device = device
            self.publicKey = publicKey
            self.headline = headline
            self.alert = alert
            self.waiting = waiting
        }
    }

    /// `relay/count` (#1163): how many sessions need the person across the hosts, for one
    /// device's widget and badge, posted as a silent push. Only a number: nothing to seal.
    struct RelayCount: Codable, Sendable, Hashable {
        public var device: UUID
        public var waiting: Int
        public var countedAt: Date
        public init(device: UUID, waiting: Int, countedAt: Date) {
            self.device = device
            self.waiting = waiting
            self.countedAt = countedAt
        }
    }
}
