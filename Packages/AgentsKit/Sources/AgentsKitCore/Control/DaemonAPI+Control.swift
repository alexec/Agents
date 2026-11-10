import Foundation

/// What the control plane answers itself, and says (058, contracts/control-api.md).
public extension DaemonAPI.Method {
    static let controlStatus = "control/status"
    static let hostsList = "machines/list"
    static let hostsStartEnroll = "machines/startEnroll"
    static let hostsInstall = "machines/install"
    static let hostsCheckAgain = "machines/checkAgain"
    static let hostsUpdate = "machines/update"
    static let hostsRemove = "machines/remove"
    /// `{host, from, runtime, allowed}`: whether `host` may use `from`'s sign-in for a
    /// runtime, relayed through the control plane (058, T091). An operator's, after the
    /// window asked the person.
    static let hostsLendSignIn = "machines/lendSignIn"
    /// `LendGit`: whether `host` may use `from`'s git access for one git server (#1122).
    /// Any client's, after it asked the person; a no ends a waiting ask.
    static let hostsLendGit = "machines/lendGit"
    /// `machines/detect` (#429): every server in the control plane's `~/.ssh/config` that
    /// answers, added as `machines/install` would with no key. `[DetectedServer]`.
    static let hostsDetect = "machines/detect"
    /// `machines/sshHosts` (#610): the hosts in the control plane's ssh config, as `ssh -G`
    /// resolves each, with no network. `{destination}` resolves just that, as typed.
    /// `[SSHHost]`.
    static let hostsSSHHosts = "machines/sshHosts"
    /// `FolderDetection` (#429, #656): whether the window suggests folders on a host, and
    /// where it looks for them. Nothing is added unless the person picks it.
    static let controlSetFolderDetection = "control/setFolderDetection"
    /// `Empty` → `Empty`, an admin's only (#997): a new control key; members take it as
    /// they connect again, with no new pairing.
    static let controlRotate = "control/rotate"
    /// `Empty` → `Empty`, an admin's only (#4252): the control plane stops, and Agents Host's
    /// launch agent starts it again (`ControlStatus.restartable`).
    static let controlRestart = "control/restart"
    /// `Empty` → `WebRemoteStatus`, an admin's only (#4252): open the loopback listener
    /// again when it isn't serving (Try Again).
    static let controlRetryWeb = "control/retryWeb"
    /// `WebServe` → `WebRemoteStatus`, an admin's only (#4252, 071 FR-002): serve Agents to
    /// browsers on this Mac, or stop; the control plane keeps it.
    static let controlSetWeb = "control/setWeb"
    /// `ConnectAnother.Request` → `Empty` (#4257): a client asks the window on the control
    /// plane's Mac to connect it to another; an admin's only.
    static let controlConnectAnother = "control/connectAnother"
    /// `ConnectAnother.Report` → `Empty`: the window says where it is in that connect.
    static let controlConnectReport = "control/connectReport"
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
    static let hostsAnnounce = "machines/announce"
    static let hostHello = "machine/hello"
    static let attentionNeed = "attention/need"
    static let controlPing = "control/ping"
    /// To a host just added, on its channel 0 (#429), never answered: `FolderDetection`.
    /// Sent only by a control plane before #656; a host since says `folders/detected` with
    /// nothing added.
    static let foldersDetect = "folders/detect"
    /// A host, on its channel 0 (#429): its answer to `folders/detect`. `{added}`.
    static let foldersDetected = "folders/detected"
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
    /// `ConnectAnother.Request`: a client asked for Connect to Another… (#4257); only the
    /// window whose Mac runs the control plane does it.
    static let controlConnectWanted = "control/connectWanted"
    /// `ConnectAnother.Report`: where the window is in that connect, to the person's clients.
    static let controlConnectReported = "control/connectReported"
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
        /// The asking client's own record, so a window can mark itself "you".
        public var you: UUID?
        /// The web remote's loopback listener (071 R3): whether the page is served, and why
        /// not. Nil when this copy was not asked to serve it.
        public var web: WebRemoteStatus?
        /// Whatever runs it starts it again after `control/restart` (#4252): Agents Host's
        /// launch agent. Nil where nothing would.
        public var restartable: Bool?
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
                    startedAt: Date? = nil, port: Int? = nil) {
            self.name = name
            self.version = version
            self.homeHost = homeHost
            self.machineID = machineID
            self.startedAt = startedAt
            self.port = port
        }
    }

    /// Whether the control plane serves the web remote on its loopback port (071 R3): what
    /// Agents Host's row and the window's Settings say, rather than the address regardless.
    struct WebRemoteStatus: Codable, Sendable, Hashable {
        /// The port asked for: 8792 for Agents Host's copy.
        public var port: Int
        public var served: Bool
        /// Why not, when it isn't: `off`, `portInUse`, `build` or `failed`.
        public var reason: String?
        /// The error as the control plane met it.
        public var detail: String?

        /// The person turned it off (071 FR-002, #4252).
        public static let off = "off"
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

        /// The person turned it off.
        public var isOff: Bool { !served && reason == Self.off }

        /// In plain words, for the row that would otherwise give the address.
        public var summary: String {
            if served { return "At \(address), for a browser on this Mac only." }
            switch reason {
            case Self.off: return "Off. Turn it on to use Agents at \(address), in a browser on this Mac only."
            case Self.portInUse: return "Not serving: port \(port) is in use by another app."
            case Self.build: return "Not serving: this copy of the Agents web app is damaged or missing."
            default: return "Not serving: port \(port) couldn’t be opened\(detail.map { " (\($0))" } ?? "")."
            }
        }
    }

    /// `control/setWeb`'s params (#4252).
    struct WebServe: Codable, Sendable, Hashable {
        public var on: Bool
        public init(on: Bool) { self.on = on }
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

    /// One row of `machines/list`.
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
        /// `swift` or `go`, as the host said in `machine/hello` (#1134); nil when it never said.
        public var implementation: String?
        /// The capabilities the host said in its last `machine/hello` (#1748); nil from a host
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
                    reach: String, machineID: String?) {
            self.id = id
            self.name = name
            self.platform = platform
            self.version = version
            self.state = state
            self.reach = reach
            self.machineID = machineID
        }
    }

    /// One host in the ssh config, and what `machines/detect` did with it (#429).
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

    /// `machine/hello`, on every connect of an uplink.
    struct MachineHello: Codable, Sendable, Hashable {
        /// Which host this is. Said only on the control plane's local socket, where the
        /// uid and the code signature are the door; over TLS the key says it, and this
        /// is ignored.
        public var host: MachineRef?
        public var version: String
        public var platform: String
        public var machineID: String
        public var name: String?
        /// The language the host is written in, `swift` or `go` (#1134), shown beside its
        /// version in Hosts. Nil from a host built before it was said.
        public var implementation: String?

        public init(host: MachineRef? = nil, version: String, platform: String, machineID: String, name: String? = nil,
                    implementation: String? = nil) {
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


    /// `clients/forget`, `machines/remove`.
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

    /// One row of `clients/connections`: a client connected now.
    struct ClientConnection: Codable, Sendable, Hashable {
        public var client: UUID
        public init(client: UUID) {
            self.client = client
        }
    }

    /// `control/moved`: where the control plane is now, told to a device over the old
    /// bridge link it already trusts. It dials there as itself, with the key it
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

    /// `machines/lendSignIn`.
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

    /// A notice for one device, as the control plane chose it (T097), which it sends through
    /// APNs or Web Push: the headline sealed to `publicKey` for `device`; no headline is a
    /// withdrawal. `waiting` is the count across the hosts at that moment (#1163).
    struct RelayDelivery: Codable, Sendable, Hashable {
        public var needID: NeedID
        public var device: UUID
        public var publicKey: Data?
        public var headline: Headline?
        public var alert: Bool
        public var waiting: Int?
        /// The person's booking's holder asked it (#4268): Time Sensitive.
        public var timely: Bool?
        public init(needID: NeedID, device: UUID, publicKey: Data? = nil, headline: Headline? = nil, alert: Bool = false,
                    waiting: Int? = nil, timely: Bool? = nil) {
            self.needID = needID
            self.device = device
            self.publicKey = publicKey
            self.headline = headline
            self.alert = alert
            self.waiting = waiting
            self.timely = timely
        }
    }
}
