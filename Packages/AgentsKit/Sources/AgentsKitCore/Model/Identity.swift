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

        public init(providers: [SignInProvider], challenge: String? = nil, domains: [String]? = nil,
                    organisations: [String]? = nil) {
            self.providers = providers
            self.challenge = challenge
            self.domains = domains
            self.organisations = organisations
        }

        /// The providers a person can sign in with now.
        public var turnedOn: [SignInProvider] { providers.filter(\.on) }
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
    }

    /// `signIn/approve`, `signIn/deny`.
    struct SignInDecide: Codable, Sendable, Hashable {
        public var request: String

        public init(request: String) { self.request = request }
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
}

public extension DaemonAPI.Notification {
    /// `SignInRequest`: a GitHub sign-in waits for this person's Approve (#995).
    static let controlSignInRequested = "control/signInRequested"
    /// `SignInDecided`: a waiting sign-in ended (#995).
    static let controlSignInDecided = "control/signInDecided"
    /// `SignInWaiting`, on an `s:` connection (#995).
    static let controlSignInWaiting = "control/signInWaiting"
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
