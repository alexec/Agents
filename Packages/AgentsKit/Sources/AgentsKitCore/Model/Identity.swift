import Foundation

/// Sign-in with Google, Apple and GitHub (#995, spec 736 T2). A client with no code signs in
/// on an `s:` connection and pairs as the person the sign-in names; a person adds an outside
/// sign-in from a client they already have. A GitHub sign-in on a new client waits for
/// Approve on another of the person's clients, which shows the same code.
public extension DaemonAPI {
    /// One sign-in provider: `on` is the admin's switch; `available` is false when the build
    /// has no client id for it, with `why`. `clientID` is what a client signs in with.
    struct SignInProvider: Codable, Sendable, Hashable, Identifiable {
        public var provider: String
        public var on: Bool
        public var available: Bool
        public var clientID: String?
        public var why: String?

        public init(provider: String, on: Bool, available: Bool, clientID: String? = nil, why: String? = nil) {
            self.provider = provider
            self.on = on
            self.available = available
            self.clientID = clientID
            self.why = why
        }

        public var id: String { provider }
    }

    /// `signIn/providers`, `signIn/configure`: the providers, the challenge a nonce is made
    /// from on this connection (base64url), and for admins the allowed domains and
    /// organisations.
    struct SignInProviders: Codable, Sendable, Hashable {
        public var providers: [SignInProvider]
        public var challenge: String?
        public var domains: [String]?
        public var organisations: [String]?
        /// The org providers turned on, first on every sign-in screen (#1002, FR-026).
        public var orgProviders: [SignInOrgProvider]?
        /// A claimed domain sends people to its org provider: offer Use an Email (FR-011).
        public var discover: Bool?

        public init(providers: [SignInProvider], challenge: String? = nil, domains: [String]? = nil,
                    organisations: [String]? = nil, orgProviders: [SignInOrgProvider]? = nil, discover: Bool? = nil) {
            self.providers = providers
            self.challenge = challenge
            self.domains = domains
            self.organisations = organisations
            self.orgProviders = orgProviders
            self.discover = discover
        }

        /// The providers a person can sign in with now.
        public var turnedOn: [SignInProvider] { providers.filter(\.on) }

        /// The org providers, in their order.
        public var orgs: [SignInOrgProvider] { (orgProviders ?? []).sorted { ($0.order, $0.name) < ($1.order, $1.name) } }

        /// Any way to sign in at all: an org provider or a built-in one.
        public var anyOn: Bool { !orgs.isEmpty || !turnedOn.isEmpty }

        /// Only what a sign-in screen shows: the providers on, and the org providers.
        public var forScreen: SignInProviders {
            var out = self
            out.providers = turnedOn
            return out
        }

        /// An org provider's name by its id; the id when it is not on.
        public func name(of provider: String) -> String {
            orgs.first { $0.id == provider }?.name ?? SignInProviderName.title(provider)
        }
    }

    /// An org provider on a sign-in screen (#1002, FR-003): its id, name and order.
    struct SignInOrgProvider: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var order: Int

        public init(id: String, name: String, order: Int = 0) {
            self.id = id
            self.name = name
            self.order = order
        }
    }

    /// `signIn/orgStart` (#1002, D2): start an org provider's flow for this connection, to
    /// pair (an `s:` connection) or to add the sign-in to the caller (a paired client).
    struct SignInOrgStart: Codable, Sendable, Hashable {
        public enum Purpose: String, Codable, Sendable { case pair, addToMe }
        public enum Return: String, Codable, Sendable { case app, web }

        public var provider: String
        public var purpose: Purpose
        public var returnTo: Return
        public var loginHint: String?

        public init(provider: String, purpose: Purpose, returnTo: Return = .app, loginHint: String? = nil) {
            self.provider = provider
            self.purpose = purpose
            self.returnTo = returnTo
            self.loginHint = loginHint
        }
    }

    /// `signIn/orgStart`'s answer: the address to open in the browser.
    struct SignInOrgStarted: Codable, Sendable, Hashable {
        public var url: String

        public init(url: String) { self.url = url }
    }

    /// `signIn/ticket` (#1002, D3): the ticket the callback gave, on the connection that
    /// started the flow. To pair, the client's name and kind too.
    struct SignInTicket: Codable, Sendable, Hashable {
        public var ticket: String
        public var name: String?
        public var kind: ClientRecord.Kind?

        public init(ticket: String, name: String? = nil, kind: ClientRecord.Kind? = nil) {
            self.ticket = ticket
            self.name = name
            self.kind = kind
        }
    }

    /// `signIn/ticket`'s answer: the client paired, or the sign-in added.
    struct SignInTicketResult: Codable, Sendable, Hashable {
        public var client: UUID?
        public var signIn: SignIn?

        public init(client: UUID? = nil, signIn: SignIn? = nil) {
            self.client = client
            self.signIn = signIn
        }
    }

    /// `signIn/discover` (#1002, FR-011): the email a person typed.
    struct SignInDiscover: Codable, Sendable, Hashable {
        public var email: String

        public init(email: String) { self.email = email }
    }

    /// `signIn/discover`'s answer: the org provider that the email's domain sends people to.
    struct SignInDiscovered: Codable, Sendable, Hashable {
        public var provider: String?
        public var name: String?

        public init(provider: String? = nil, name: String? = nil) {
            self.provider = provider
            self.name = name
        }
    }

    /// `control/cutOff` (#1002, D13): to every client of a suspended person, just before the
    /// control plane closes them.
    struct ControlCutOff: Codable, Sendable, Hashable {
        public var why: String
        public var provider: String?

        public init(why: String, provider: String? = nil) {
            self.why = why
            self.provider = provider
        }
    }

    /// `signIn/configure`, for admins: what is left out stays as it was.
    struct SignInConfigure: Codable, Sendable, Hashable {
        public var provider: String
        public var on: Bool?
        public var domains: [String]?
        public var organisations: [String]?

        public init(provider: String, on: Bool? = nil, domains: [String]? = nil, organisations: [String]? = nil) {
            self.provider = provider
            self.on = on
            self.domains = domains
            self.organisations = organisations
        }
    }

    /// `signIn/pair`, on an `s:` connection: the client's name and kind, and its provider's
    /// token, which the control plane checks and forgets.
    struct SignInPair: Codable, Sendable, Hashable {
        public var provider: String
        public var token: String
        public var name: String
        public var kind: ClientRecord.Kind

        public init(provider: String, token: String, name: String, kind: ClientRecord.Kind) {
            self.provider = provider
            self.token = token
            self.name = name
            self.kind = kind
        }
    }

    /// `control/signInWaiting`: a GitHub sign-in waits for Approve, with the code to compare.
    struct SignInWaiting: Codable, Sendable, Hashable {
        public var code: String
        public var expires: Date

        public init(code: String, expires: Date) {
            self.code = code
            self.expires = expires
        }
    }

    /// `signIn/addToMe`: an ID token made with `signIn/providers`' challenge, or a GitHub
    /// user token.
    struct SignInAdd: Codable, Sendable, Hashable {
        public var provider: String
        public var token: String

        public init(provider: String, token: String) {
            self.provider = provider
            self.token = token
        }
    }

    /// `signIn/removeFromMe`.
    struct SignInRemove: Codable, Sendable, Hashable {
        public var provider: String
        public var account: String

        public init(provider: String, account: String) {
            self.provider = provider
            self.account = account
        }
    }

    /// A new client that signed in with GitHub, waiting for this person's Approve:
    /// `signIn/requests` and `control/signInRequested`.
    struct SignInRequest: Codable, Sendable, Hashable, Identifiable {
        public var request: String
        public var name: String
        public var kind: ClientRecord.Kind
        public var provider: String
        public var login: String?
        public var code: String
        public var expires: Date

        public init(request: String, name: String, kind: ClientRecord.Kind, provider: String, login: String? = nil,
                    code: String, expires: Date) {
            self.request = request
            self.name = name
            self.kind = kind
            self.provider = provider
            self.login = login
            self.code = code
            self.expires = expires
        }

        public var id: String { request }

        /// A browser that asked by an account (#2097): the person types the code it shows,
        /// and the request carries none (FR-014a).
        public var needsCode: Bool { provider == "browser" }
    }

    /// `signIn/approve`, `signIn/deny`. `code` is what the person typed for a browser (#2097).
    struct SignInDecide: Codable, Sendable, Hashable {
        public var request: String
        public var code: String?

        public init(request: String, code: String? = nil) {
            self.request = request
            self.code = code
        }
    }

    /// `control/signInDecided`: approved, denied or expired, so its card goes.
    struct SignInDecided: Codable, Sendable, Hashable {
        public var request: String
        public var result: String

        public init(request: String, result: String) {
            self.request = request
            self.result = result
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `SignInProviders` (#995).
    static let signInProviders = "signIn/providers"
    /// `SignInPair` → `Admitted`, on an `s:` connection only (#995).
    static let signInPair = "signIn/pair"
    /// `SignInAdd` → `SignIn` (#995).
    static let signInAddToMe = "signIn/addToMe"
    /// `SignInRemove` → `{}` (#995).
    static let signInRemoveFromMe = "signIn/removeFromMe"
    /// `SignInConfigure` → `SignInProviders`, for admins (#995).
    static let signInConfigure = "signIn/configure"
    /// `Empty` → `[SignInRequest]` (#995).
    static let signInRequests = "signIn/requests"
    /// `SignInDecide` → `{}` (#995).
    static let signInApprove = "signIn/approve"
    /// `SignInDecide` → `{}` (#995).
    static let signInDeny = "signIn/deny"
    /// `SignInAsk` → `Admitted`, on an `s:` connection only: a browser by approval (#2097).
    static let signInAsk = "signIn/ask"
    /// `SignInOrgStart` → `SignInOrgStarted` (#1002).
    static let signInOrgStart = "signIn/orgStart"
    /// `SignInTicket` → `SignInTicketResult` (#1002).
    static let signInTicket = "signIn/ticket"
    /// `SignInDiscover` → `SignInDiscovered` (#1002).
    static let signInDiscover = "signIn/discover"
}

public extension DaemonAPI.Notification {
    /// `SignInRequest`: a GitHub sign-in waits for this person's Approve (#995).
    static let controlSignInRequested = "control/signInRequested"
    /// `SignInDecided`: a waiting sign-in ended (#995).
    static let controlSignInDecided = "control/signInDecided"
    /// `SignInWaiting`, on an `s:` connection (#995).
    static let controlSignInWaiting = "control/signInWaiting"
    /// `ControlCutOff`: this client's person was suspended; the connection closes next (#1002).
    static let controlCutOff = "control/cutOff"
}

/// The sign-in providers as the screen names them.
public enum SignInProviderName {
    public static func title(_ provider: String) -> String {
        switch provider {
        case "google": "Google"
        case "apple": "Apple"
        case "github": "GitHub"
        case "local": "This control plane"
        case "code": "Invite code"
        case "browser": "Browser"
        default: provider
        }
    }

    /// The providers a person adds or takes off: never the local owner's or a code.
    public static func isOutside(_ provider: String) -> Bool {
        ["google", "apple", "github"].contains(provider)
    }
}

/// The GitHub sign-ins waiting for this person, as a client keeps them: one card each,
/// newest last, and none past its end (#995).
public struct SignInRequestQueue: Sendable, Hashable {
    public private(set) var requests: [DaemonAPI.SignInRequest] = []

    public init(_ requests: [DaemonAPI.SignInRequest] = []) {
        replace(with: requests)
    }

    /// What `signIn/requests` said, in place of what was kept.
    public mutating func replace(with listed: [DaemonAPI.SignInRequest]) {
        requests = []
        for request in listed { add(request) }
    }

    /// `control/signInRequested`: a new card, or the same one again in place.
    public mutating func add(_ request: DaemonAPI.SignInRequest) {
        if let index = requests.firstIndex(where: { $0.request == request.request }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    /// `control/signInDecided`, or an answer from here: the card goes.
    public mutating func remove(_ request: String) {
        requests.removeAll { $0.request == request }
    }

    /// The cards to show at `now`.
    public func open(at now: Date = Date()) -> [DaemonAPI.SignInRequest] {
        requests.filter { $0.expires > now }
    }
}

/// What the clients say about sign-in (#995), the same on the Mac and the Remote; the web
/// page's are in `Web/src/model/signIn.ts`.
public enum SignInWords {
    public static let paneTitle = "Sign-in Providers"
    public static let paneFoot = "People sign in with these to pair a window or a phone with no code. "
        + "A person not known joins only through an allowed Google Workspace domain; "
        + "everyone else is invited first, and adds their sign-in under \(signInsPlace)."
    /// Where a person adds a sign-in: the group and pane every client lists it under (#2157,
    /// #2256). Change it with the group.
    public static let signInsPlace = "Control plane ▸ \(signInsTitle)"
    /// The admin's pane, apart from a person's own Sign-ins (#2080).
    public static let paneSymbol = "key.horizontal"
    public static let signInsTitle = "Sign-ins"
    public static let signInsFoot = "Sign in with one of these on another Mac, iPhone or iPad to pair it with no code. "
        + "A GitHub sign-in waits for Approve here."
    public static let domainsTitle = "Allowed Google Workspace domains"
    public static let domainsFoot = "Anyone with a Workspace account on one of these joins as a member with no invite."
    public static let organisationsTitle = "Allowed GitHub organisations"
    public static let organisationsFoot = "A GitHub sign-in must be in one of these. "
        + "It does not let anyone join with no invite."
    public static let noneOn = "No sign-in provider is turned on for this control plane. Use a pairing code."

    /// After the client's name: "Sam’s iPhone wants to sign in as you."
    public static let wants = "wants to sign in as you."

    /// The card's second line: "GitHub · sam".
    public static func account(_ request: DaemonAPI.SignInRequest) -> String {
        [SignInProviderName.title(request.provider), request.login].compactMap { $0 }.joined(separator: " · ")
    }

    public static func title(_ request: DaemonAPI.SignInRequest) -> String {
        "\(request.name) \(wants) \(account(request))"
    }

    public static func code(_ request: DaemonAPI.SignInRequest) -> String {
        "Check that it shows \(request.code.map(String.init).joined(separator: " "))."
    }

    /// A browser's card (#2097): the code is on the browser's screen only.
    public static let typeCode = "Type the code that the browser shows."
    public static let codePlaceholder = "Code"

    /// The pairing screens (#2097): sign-in first, the code behind this.
    public static let useCode = "Use a Code Instead…"
    public static let useSignIn = "Sign In Instead…"

    /// One sign-in as Account lists it: "GitHub · sam", "Google · sam@example.com".
    public static func row(_ signIn: DaemonAPI.SignIn) -> String {
        let detail = signIn.email ?? signIn.login ?? (SignInProviderName.isOutside(signIn.provider) ? signIn.account : nil)
        return [SignInProviderName.title(signIn.provider), detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// The button that signs in with a provider.
    public static func button(_ provider: String) -> String { "Sign in with \(SignInProviderName.title(provider))" }

    public static func removeTitle(_ signIn: DaemonAPI.SignIn) -> String { "Remove \(row(signIn))?" }
    public static let removeMessage = "You can no longer pair a client with this sign-in. Your clients stay paired."

    /// While a GitHub sign-in waits for another client.
    public static func waiting(_ code: String) -> String {
        "On one of your other clients, approve this sign-in. It shows \(code)."
    }

    // MARK: Org providers (#1002, slice 3)

    /// An org provider's button, first on every sign-in screen (FR-026).
    public static func orgButton(_ name: String) -> String { "Sign in with \(name)" }
    /// Opens the email field when a claimed domain sends people to its provider (FR-011).
    public static let useEmail = "Use an Email"
    public static let emailPlaceholder = "you@example.com"
    public static let noOrgForEmail = "No organisation sends people with that email here. Sign in another way, or use a code."
    /// The callback scheme the control plane sends the Mac and the Remote back on (FR-027).
    public static let callbackScheme = "agents"

    /// The only page a client of a suspended person shows (FR-029).
    public static let suspendedLine = "Your organisation's sign-in turned your access off."
    public static func suspendedFoot(_ device: String) -> String {
        "Ask your IT team to turn it on again. This \(device) stays paired, and connects again when they do."
    }
    /// A built-in sign-in at a domain that requires its org provider (FR-012, FR-029).
    public static func required(_ name: String) -> String { "Your organisation asks you to sign in with \(name)." }

    public static let orgSignInRequired = -32077
    public static let personSuspended = -32078
    public static let managedByProvider = -32079

    /// The org provider a refusal asks for: `orgSignInRequired` with `{provider, name}`.
    public static func requiredProvider(_ error: any Error) -> DaemonAPI.SignInOrgProvider? {
        guard let rpc = error as? JSONRPCError, rpc.code == orgSignInRequired,
              let provider = rpc.data?["provider"]?.stringValue else { return nil }
        return DaemonAPI.SignInOrgProvider(id: provider, name: rpc.data?["name"]?.stringValue ?? provider)
    }

    /// True for `personSuspended`.
    public static func isSuspended(_ error: any Error) -> Bool {
        (error as? JSONRPCError)?.code == personSuspended
    }

    /// What the control plane sent the browser back with: the ticket, or why there is none.
    public enum Callback: Equatable, Sendable {
        case ticket(String)
        case failed(String)
    }

    /// Reads `agents://oidc#ticket=…`, or `#error=…&message=…` (contracts/identity-api.md).
    public static func callback(_ url: URL) -> Callback {
        var parts = URLComponents()
        parts.percentEncodedQuery = url.fragment
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if let ticket = value("ticket") { return .ticket(ticket) }
        if let message = value("message") { return .failed(message) }
        if value("error") == "access_denied" { return .failed("The sign-in was cancelled.") }
        if let error = value("error") { return .failed("The sign-in did not finish (\(error)).") }
        return .failed("The sign-in came back with no answer. Try again.")
    }
}
