import Foundation

/// People and the machines that belong to them (#994, spec 736 Team T1).
///
/// Each client belongs to a person, and each machine to one user. The person who set up
/// the control plane is the local owner, and an admin. With one person, nothing changes:
/// Settings ▸ People shows them as "You · Local owner · Admin".
public extension DaemonAPI {
    /// A user's role: an admin manages people; a member sees only their own.
    enum UserRole: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
        case admin, member

        public var id: Self { self }

        /// A role a later build added reads as `member`, which can do the least.
        public init(from decoder: any Decoder) throws {
            self = UserRole(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .member
        }

        public var title: String {
            switch self {
            case .admin: "Admin"
            case .member: "Member"
            }
        }
    }

    /// Who a client belongs to, in `control/status`.
    struct ControlPerson: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var role: UserRole
        public var localOwner: Bool?

        public init(id: String, name: String, role: UserRole, localOwner: Bool? = nil) {
            self.id = id
            self.name = name
            self.role = role
            self.localOwner = localOwner
        }

        public var isAdmin: Bool { role == .admin }
    }

    /// One way a person signs in: `local` for the local owner, `code` for an invite code.
    struct SignIn: Codable, Sendable, Hashable {
        public var provider: String
        public var account: String?
        public var email: String?
        public var login: String?
        public var added: Date?

        public init(provider: String, account: String? = nil, email: String? = nil, login: String? = nil,
                    added: Date? = nil) {
            self.provider = provider
            self.account = account
            self.email = email
            self.login = login
            self.added = added
        }
    }

    /// A client in People: its name and kind.
    struct PersonClient: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var name: String
        public var kind: ClientRecord.Kind

        public init(id: UUID, name: String, kind: ClientRecord.Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    /// A machine in People: its name, its state and nothing inside it (FR-019).
    struct PersonMachine: Codable, Sendable, Hashable, Identifiable {
        public var id: MachineRef
        public var name: String
        public var state: String
        public var platform: String?

        public init(id: MachineRef, name: String, state: String, platform: String? = nil) {
            self.id = id
            self.name = name
            self.state = state
            self.platform = platform
        }
    }

    /// One user in `people/list`, with their clients and machines.
    struct PersonRow: Codable, Sendable, Hashable, Identifiable {
        public enum Kind: String, Codable, Sendable, Hashable {
            case person, bot

            /// A kind a later build added reads as `person`.
            public init(from decoder: any Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .person
            }
        }

        public var id: String
        public var name: String
        public var kind: Kind
        public var role: UserRole
        public var localOwner: Bool?
        public var you: Bool?
        public var signIns: [SignIn]
        public var clients: [PersonClient]
        public var machines: [PersonMachine]
        /// A bot's group, caps and spend today, UTC (#1761).
        public var group: String?
        public var caps: SpendCaps?
        public var spentTodayUSD: Double?
        /// What SCIM says of the person, for one SCIM made (#1002): Managed by <provider>.
        public var scim: PersonSCIM?
        /// Made by SCIM and not signed in yet: Waiting for first sign-in.
        public var provisioned: Bool?
        /// Suspended by their org provider (D13).
        public var suspended: PersonSuspended?
        /// The SCIM groups that give the person their role (FR-020): Set by <provider>.
        public var roleFrom: [String]?

        public init(id: String, name: String, kind: Kind = .person, role: UserRole, localOwner: Bool? = nil,
                    you: Bool? = nil, signIns: [SignIn] = [], clients: [PersonClient] = [],
                    machines: [PersonMachine] = [], group: String? = nil, caps: SpendCaps? = nil,
                    spentTodayUSD: Double? = nil, scim: PersonSCIM? = nil, provisioned: Bool? = nil,
                    suspended: PersonSuspended? = nil, roleFrom: [String]? = nil) {
            self.scim = scim
            self.provisioned = provisioned
            self.suspended = suspended
            self.roleFrom = roleFrom
            self.group = group
            self.caps = caps
            self.spentTodayUSD = spentTodayUSD
            self.id = id
            self.name = name
            self.kind = kind
            self.role = role
            self.localOwner = localOwner
            self.you = you
            self.signIns = signIns
            self.clients = clients
            self.machines = machines
        }

        public var isYou: Bool { you == true }
        public var isLocalOwner: Bool { localOwner == true }
        /// The org provider that sets this person's role: people/setRole refuses it.
        public var roleSetBy: String? { roleFrom?.isEmpty == false ? scim?.provider ?? suspended?.provider : nil }
    }

    /// What an org provider's SCIM says of a person (#1002, FR-015). Only what a client shows.
    struct PersonSCIM: Codable, Sendable, Hashable {
        public var provider: String
        public var userName: String
        public var displayName: String?
        public var active: Bool

        public init(provider: String, userName: String, displayName: String? = nil, active: Bool = true) {
            self.provider = provider
            self.userName = userName
            self.displayName = displayName
            self.active = active
        }
    }

    /// Why a person is suspended (#1002, D13): by SCIM, a refused refresh, or an admin; with
    /// the provider and when.
    struct PersonSuspended: Codable, Sendable, Hashable {
        public var by: String
        public var provider: String
        public var at: Date
        public var why: String?

        public init(by: String, provider: String, at: Date, why: String? = nil) {
            self.by = by
            self.provider = provider
            self.at = at
            self.why = why
        }
    }

    /// `people/list`: every user for an admin; for a member, only themselves.
    struct PeopleList: Codable, Sendable, Hashable {
        public var people: [PersonRow]
        public var admin: Bool

        public init(people: [PersonRow], admin: Bool) {
            self.people = people
            self.admin = admin
        }
    }

    /// `people/invite`: the new person's name and role.
    struct PersonInvite: Codable, Sendable, Hashable {
        public var name: String
        public var role: UserRole

        public init(name: String, role: UserRole) {
            self.name = name
            self.role = role
        }
    }

    /// `people/invite`'s answer: the code to send, for one use within 7 days. Its first
    /// client pairs as the new person.
    struct PersonInvited: Codable, Sendable, Hashable {
        public var text: String
        public var expires: Date
        public var name: String
        public var role: UserRole

        public init(text: String, expires: Date, name: String, role: UserRole) {
            self.text = text
            self.expires = expires
            self.name = name
            self.role = role
        }
    }

    /// `people/remove`: the user.
    struct PersonRequest: Codable, Sendable, Hashable {
        public var user: String

        public init(user: String) { self.user = user }
    }

    /// `people/removePreview` (FR-029, #1763): what Remove would take, for the admin to
    /// confirm. Started machines are stopped and deleted through their providers, each with
    /// the work on it that is not pushed; registered machines leave the control plane.
    struct PersonRemovePreview: Codable, Sendable, Hashable {
        public var startedMachines: [StartedMachinePreview]
        public var registeredMachines: [PersonMachine]

        public init(startedMachines: [StartedMachinePreview] = [], registeredMachines: [PersonMachine] = []) {
            self.startedMachines = startedMachines
            self.registeredMachines = registeredMachines
        }
    }

    /// A started machine in `people/removePreview`. `unknown` says why it could not be asked.
    struct StartedMachinePreview: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var name: String
        public var state: String
        public var unpushed: [UnpushedWork]
        public var unknown: String?

        public init(host: MachineRef, name: String, state: String, unpushed: [UnpushedWork] = [], unknown: String? = nil) {
            self.host = host
            self.name = name
            self.state = state
            self.unpushed = unpushed
            self.unknown = unknown
        }
    }

    /// A worktree with work that is not pushed: commits ahead of its upstream, commits on a
    /// branch with no upstream (`unmerged`), or changes not committed.
    struct UnpushedWork: Codable, Sendable, Hashable {
        public var folder: URL
        public var worktree: URL
        public var branch: String?
        public var ahead: Int?
        public var unmerged: Int?
        public var uncommitted: Int?

        public init(folder: URL, worktree: URL, branch: String? = nil, ahead: Int? = nil, unmerged: Int? = nil,
                    uncommitted: Int? = nil) {
            self.folder = folder
            self.worktree = worktree
            self.branch = branch
            self.ahead = ahead
            self.unmerged = unmerged
            self.uncommitted = uncommitted
        }
    }

    /// `people/setRole`. Refused when it would leave no admin.
    struct PersonRoleRequest: Codable, Sendable, Hashable {
        public var user: String
        public var role: UserRole

        public init(user: String, role: UserRole) {
            self.user = user
            self.role = role
        }
    }

    /// `control/peopleChanged`: a person was added, changed or removed.
    struct PeopleChanged: Codable, Sendable, Hashable {
        public var user: String?
        public var removed: Bool?

        public init(user: String? = nil, removed: Bool? = nil) {
            self.user = user
            self.removed = removed
        }
    }

    /// A machine waiting for approval, with the code it shows: `hosts/joinRequests` and
    /// `control/joinRequested`. `for` names whose it is to be; empty when it names no one.
    struct JoinRequest: Codable, Sendable, Hashable, Identifiable {
        public var request: String
        public var name: String
        public var platform: String
        public var code: String
        public var expires: Date
        public var forUser: String
        public var forName: String?

        private enum CodingKeys: String, CodingKey {
            case request, name, platform, code, expires
            case forUser = "for"
            case forName
        }

        public init(request: String, name: String, platform: String, code: String, expires: Date,
                    forUser: String, forName: String? = nil) {
            self.request = request
            self.name = name
            self.platform = platform
            self.code = code
            self.expires = expires
            self.forUser = forUser
            self.forName = forName
        }

        public var id: String { request }
    }

    /// `GET /v1/join/<request>`, as a machine with no code reads it while it waits: still
    /// waiting, or how it ended. Once approved, its host, and the control plane's key and
    /// name, which the machine keeps as a code's would give it.
    struct MachineJoinDecision: Codable, Sendable, Hashable {
        public enum Result: String, Codable, Sendable, Hashable {
            case waiting, approved, denied, expired
        }

        public var result: Result
        public var host: MachineRef?
        public var controlKey: Data?
        public var name: String?

        public init(result: Result, host: MachineRef? = nil, controlKey: Data? = nil, name: String? = nil) {
            self.result = result
            self.host = host
            self.controlKey = controlKey
            self.name = name
        }
    }

    /// `hosts/approveJoin`, `hosts/denyJoin`.
    struct JoinRequestDecide: Codable, Sendable, Hashable {
        public var request: String

        public init(request: String) { self.request = request }
    }

    /// `hosts/approveJoin`'s answer: the machine's new host.
    struct JoinApproved: Codable, Sendable, Hashable {
        public var host: MachineRef

        public init(host: MachineRef) { self.host = host }
    }

    /// `control/joinDecided`: a request ended, approved or not, so every card for it goes.
    struct JoinDecided: Codable, Sendable, Hashable {
        public var request: String
        public var result: String

        public init(request: String, result: String) {
            self.request = request
            self.result = result
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `PeopleList` (#994).
    static let peopleList = "people/list"
    /// `PersonInvite` → `PersonInvited`, an admin's only (#994).
    static let peopleInvite = "people/invite"
    /// `PersonRoleRequest` → `{}`, an admin's only (#994).
    static let peopleSetRole = "people/setRole"
    /// `PersonRequest` → `{}`, an admin's only: their clients are forgotten and their
    /// machines leave the control plane (#994).
    static let peopleRemove = "people/remove"
    /// `PersonRequest` → `PersonRemovePreview`, an admin's only: the person's started
    /// machines with their work that is not pushed, and their registered machines (#1763).
    static let peopleRemovePreview = "people/removePreview"
    /// `Empty` → `[JoinRequest]`: the machines waiting for this person's approval; for an
    /// admin, also those that name no person (#994).
    static let hostsJoinRequests = "hosts/joinRequests"
    /// `JoinRequestDecide` → `JoinApproved` (#994).
    static let hostsApproveJoin = "hosts/approveJoin"
    /// `JoinRequestDecide` → `{}` (#994).
    static let hostsDenyJoin = "hosts/denyJoin"
}

public extension DaemonAPI.Notification {
    /// `JoinRequest`: a machine asks to join (#994).
    static let controlJoinRequested = "control/joinRequested"
    /// `JoinDecided`: a request ended (#994).
    static let controlJoinDecided = "control/joinDecided"
    /// `PeopleChanged`: load People again (#994).
    static let controlPeopleChanged = "control/peopleChanged"
}

/// The machines waiting for approval, as a client keeps them: one card each, newest
/// last, and none past its end (#994).
public struct JoinRequestQueue: Sendable, Hashable {
    public private(set) var requests: [DaemonAPI.JoinRequest] = []

    public init(_ requests: [DaemonAPI.JoinRequest] = []) {
        replace(with: requests)
    }

    /// What `hosts/joinRequests` said, in place of what was kept.
    public mutating func replace(with listed: [DaemonAPI.JoinRequest]) {
        requests = []
        for request in listed { add(request) }
    }

    /// `control/joinRequested`: a new card, or the same one again in place.
    public mutating func add(_ request: DaemonAPI.JoinRequest) {
        if let index = requests.firstIndex(where: { $0.request == request.request }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    /// `control/joinDecided`, or an answer from here: the card goes.
    public mutating func remove(_ request: String) {
        requests.removeAll { $0.request == request }
    }

    /// The cards to show at `now`: a request past its end is not.
    public func open(at now: Date = Date()) -> [DaemonAPI.JoinRequest] {
        requests.filter { $0.expires > now }
    }
}

/// The words Settings ▸ People and the approval card are shown in, the same on the Mac and
/// the Remote (the web page's are in `Web/src/model/people.ts`).
public enum PeopleWords {
    /// "You · Local owner · Admin": who the person is to this client, then their role.
    public static func badges(_ person: DaemonAPI.PersonRow) -> String {
        var parts: [String] = []
        if person.isYou { parts.append("You") }
        if person.isLocalOwner { parts.append("Local owner") }
        if person.kind == .bot { parts.append("Bot") }
        parts.append(person.role.title)
        return parts.joined(separator: " · ")
    }

    /// The org provider lines under a person (#1002, FR-028), with `name` giving a provider's
    /// name by its id: Managed by, Waiting for first sign-in, Suspended by.
    public static func orgLines(_ person: DaemonAPI.PersonRow, name: (String) -> String) -> [String] {
        var lines: [String] = []
        if let scim = person.scim { lines.append(managedBy(name(scim.provider))) }
        if person.provisioned == true { lines.append(waitingFirstSignIn) }
        if let suspended = person.suspended { lines.append(suspendedBy(name(suspended.provider))) }
        return lines
    }

    public static func managedBy(_ provider: String) -> String { "Managed by \(provider)" }
    public static let waitingFirstSignIn = "Waiting for first sign-in"
    public static let editInConsole = "Edit in Console"

    /// Console ▸ People on the web page, for Edit in Console (D17), where Console ▸ Policy is.
    public static func consoleURL(_ status: DaemonAPI.ControlStatus?) -> URL? {
        guard let policy = OrgPolicyWords.consoleURL(status),
              var parts = URLComponents(url: policy, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = "/console/people"
        return parts.url
    }
    /// Console ▸ Sign-In on the web page, for the providers' Edit in Console (D17).
    public static func signInConsoleURL(_ status: DaemonAPI.ControlStatus?) -> URL? {
        guard let people = consoleURL(status), var parts = URLComponents(url: people, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = "/console/signIn"
        return parts.url
    }
    public static let orgProvidersTitle = "Your organisation’s sign-in"
    /// Under the providers, read only on the Mac and the Remote (D17).
    public static func orgProvidersFoot(admin: Bool) -> String {
        admin ? "People see these on the sign-in screen, in this order. Change them, their domains and SCIM in Console ▸ Sign-In on the web page."
            : "People see these on the sign-in screen, in this order. An admin changes them in Console ▸ Sign-In on the web page."
    }
    public static func suspendedBy(_ provider: String) -> String { "Suspended by \(provider)" }
    /// A SCIM group's line: where it comes from.
    public static func fromProvider(_ provider: String) -> String { "From \(provider)" }
    /// On a role or a group that the provider controls (FR-020, FR-028).
    public static func setBy(_ provider: String) -> String { "Set by \(provider)" }

    /// "box-1 (online), studio (offline)", or nil with none.
    public static func machines(_ person: DaemonAPI.PersonRow) -> String? {
        guard !person.machines.isEmpty else { return nil }
        return person.machines.map { "\($0.name) (\(state($0.state)))" }.joined(separator: ", ")
    }

    /// "MacBook Pro, iPhone", or nil with none.
    public static func clients(_ person: DaemonAPI.PersonRow) -> String? {
        guard !person.clients.isEmpty else { return nil }
        return person.clients.map(\.name).joined(separator: ", ")
    }

    /// A machine's state in words.
    public static func state(_ state: String) -> String {
        switch state {
        case "online": "online"
        case "offline": "offline"
        case "connecting": "connecting"
        case "needsUpdate": "needs an update"
        case "failed": "failed"
        case "stopped": "stopped"
        case "starting": "starting"
        case "stopping": "stopping"
        default: state
        }
    }

    /// Whether an admin may remove this person from here: not themselves, not the local
    /// owner. The control plane refuses those too, and says why.
    public static func canRemove(_ person: DaemonAPI.PersonRow) -> Bool {
        !person.isYou && !person.isLocalOwner
    }

    /// Said while Remove asks the person's machines what work on them is not pushed.
    public static func asking(_ person: DaemonAPI.PersonRow) -> String {
        "Asking \(person.name)’s machines what work on them is not pushed…"
    }

    /// Remove…'s check failed (#2193): `why` is a sentence. Remove stays off until it works.
    public static func checkFailed(_ person: DaemonAPI.PersonRow, why: String) -> String {
        "Could not check what \(person.name)’s machines would lose. \(why) Removing \(person.name) stops and deletes "
            + "the machines \(person.name) started, with any work on them not pushed, so Remove stays off until the check works."
    }

    public static func removeTitle(_ person: DaemonAPI.PersonRow) -> String {
        "Remove \(person.name)?"
    }

    /// What goes with them: their clients are forgotten, their started machines are deleted
    /// with the work on them that is not pushed, and their other machines leave. Without a
    /// preview (a control plane from before #1763), every machine only leaves.
    public static func removeMessage(_ person: DaemonAPI.PersonRow, preview: DaemonAPI.PersonRemovePreview? = nil) -> String {
        removeLines(person, preview: preview).joined(separator: " ")
    }

    /// The same, a line each (#2077): for Remove…'s sheet, a machine to a line.
    public static func removeLines(_ person: DaemonAPI.PersonRow, preview: DaemonAPI.PersonRemovePreview? = nil) -> [String] {
        var lines = ["\(person.name) can no longer reach the control plane."]
        if let clients = clients(person) {
            lines.append("These clients are forgotten: \(clients).")
        }
        if let preview {
            if !preview.startedMachines.isEmpty {
                lines.append("These machines are stopped and deleted: \(preview.startedMachines.map(\.name).joined(separator: ", ")).")
            }
            for machine in preview.startedMachines {
                if let unknown = machine.unknown {
                    lines.append(unknown)
                } else if !machine.unpushed.isEmpty {
                    let work = machine.unpushed.map(unpushedWords).joined(separator: "; ")
                    lines.append("On \(machine.name), this work is not pushed and is lost: \(work).")
                }
            }
            if !preview.registeredMachines.isEmpty {
                lines.append("These machines leave the control plane: \(preview.registeredMachines.map(\.name).joined(separator: ", ")).")
            }
        } else if !person.machines.isEmpty {
            lines.append("These machines leave the control plane: \(person.machines.map(\.name).joined(separator: ", ")).")
        }
        if person.clients.isEmpty, person.machines.isEmpty {
            lines.append("They have no clients and no machines.")
        }
        return lines
    }

    /// "agents/fix (2 commits not pushed, changes not committed)": a worktree by its branch,
    /// or its folder's name when it has none.
    public static func unpushedWords(_ work: DaemonAPI.UnpushedWork) -> String {
        let name = work.branch ?? work.worktree.lastPathComponent
        var what: [String] = []
        if let ahead = work.ahead, ahead > 0 {
            what.append("\(ahead) \(ahead == 1 ? "commit" : "commits") not pushed")
        } else if work.ahead == nil, let unmerged = work.unmerged, unmerged > 0 {
            what.append("\(unmerged) \(unmerged == 1 ? "commit" : "commits") never pushed")
        }
        if let uncommitted = work.uncommitted, uncommitted > 0 {
            what.append("changes not committed")
        }
        return what.isEmpty ? name : "\(name) (\(what.joined(separator: ", ")))"
    }

    /// Under the invite code: when it stops working, and what to do with it.
    public static func inviteFoot(_ invited: DaemonAPI.PersonInvited, calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.calendar = calendar
        style.locale = locale
        style.timeZone = calendar.timeZone
        let until = invited.expires.formatted(style)
        return "Works once, until \(until). Send it to \(invited.name); they paste it where a code is asked for."
    }

    /// The card's first line: "studio wants to join as you", "… as Sam", or "… It names
    /// no person."
    public static func joinTitle(_ request: DaemonAPI.JoinRequest, you: String?) -> String {
        "\(request.name) \(joinWants(request, you: you))"
    }

    /// The card's first line after the machine's name, which the card draws in bold.
    public static func joinWants(_ request: DaemonAPI.JoinRequest, you: String?) -> String {
        if request.forUser.isEmpty { return "wants to join. It names no person." }
        if let you, request.forUser == you { return "wants to join as you" }
        let name = request.forName.flatMap { $0.isEmpty ? nil : $0 } ?? request.forUser
        return "wants to join as \(name)"
    }

    /// "Check that the machine shows 4F7-2KQ."
    public static func joinCode(_ request: DaemonAPI.JoinRequest) -> String {
        "Check that the machine shows \(request.code)."
    }

    /// "Linux machine", from the platform it said.
    public static func platform(_ platform: String) -> String {
        switch platform.lowercased() {
        case "darwin", "macos", "mac": "Mac"
        case "linux": "Linux machine"
        case "windows": "Windows machine"
        case "": "Machine"
        default: platform
        }
    }

    /// A refusal from the control plane, in its own words; an older control plane that
    /// does not know people says so.
    public static func refusal(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            return error.code == JSONRPCError.methodNotFound
                ? "This control plane does not know people yet. Update it to add people."
                : error.message
        }
        return "The control plane can’t be reached."
    }

    /// Under the person's own row, with `control/status`'s `joinCommand`.
    public static let joinCommandTitle = "Add a machine without a code"
    public static let joinCommandFoot = "Run it on the machine. It shows a code; approve it here."

    /// Rotate Control Key… (#997, spec 736 FR-043): an admin's, with a confirmation.
    public static let rotateTitle = "Rotate the control key?"
    public static let rotateMessage = "Every client and machine connects again and takes the new key, with no new pairing. One that does not connect in the next 30 days has to pair again."
    public static let rotateFoot = "Rotate the control plane’s key if you think someone copied it."
    public static let rotated = "The control key was rotated. Each client and machine takes the new key when it connects again."

    /// The pane's foot: who sees what.
    public static func foot(admin: Bool) -> String {
        admin
            ? "Each client and each machine belongs to one person. An admin adds and removes people; a member sees only their own clients and machines."
            : "You see your own clients and machines. An admin adds and removes people."
    }
}
