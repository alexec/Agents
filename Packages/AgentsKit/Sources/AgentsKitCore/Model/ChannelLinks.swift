import Foundation

/// Channel links (#1762, spec 736 US7, FR-037): a channel identity (a Slack user, an email
/// address) acts as a person only once that person approves the link on one of their
/// signed-in clients. A message from an identity that is not linked starts nothing, and
/// asks its person; one that names no person goes to the admins, who send it on.
public extension DaemonAPI {
    /// A channel identity linked to a person: `links/list`.
    struct ChannelLink: Codable, Sendable, Hashable, Identifiable {
        public var channel: String
        public var identity: String
        public var name: String?
        public var user: String
        public var userName: String?
        public var approvedBy: String
        public var approvedAt: Date

        public init(channel: String, identity: String, name: String? = nil, user: String, userName: String? = nil,
                    approvedBy: String, approvedAt: Date) {
            self.channel = channel
            self.identity = identity
            self.name = name
            self.user = user
            self.userName = userName
            self.approvedBy = approvedBy
            self.approvedAt = approvedAt
        }

        public var id: String { channel + "\n" + identity }
    }

    /// A channel identity waiting to be linked: `links/requests` and
    /// `control/linkRequested`. `forUser` is the person asked; nil when it goes to the
    /// admins, who send it on.
    struct ChannelLinkRequest: Codable, Sendable, Hashable, Identifiable {
        public var request: String
        public var channel: String
        public var identity: String
        public var name: String?
        public var email: String?
        public var forUser: String?
        public var forName: String?
        public var expires: Date

        private enum CodingKeys: String, CodingKey {
            case request, channel, identity, name, email, expires
            case forUser = "for"
            case forName
        }

        public init(request: String, channel: String, identity: String, name: String? = nil, email: String? = nil,
                    forUser: String? = nil, forName: String? = nil, expires: Date) {
            self.request = request
            self.channel = channel
            self.identity = identity
            self.name = name
            self.email = email
            self.forUser = forUser
            self.forName = forName
            self.expires = expires
        }

        public var id: String { request }
    }

    /// `links/approve`, `links/deny`. An admin approving a request that names no person
    /// names one in `forUser`, and the request goes to them.
    struct ChannelLinkDecide: Codable, Sendable, Hashable {
        public var request: String
        public var forUser: String?

        private enum CodingKeys: String, CodingKey {
            case request
            case forUser = "for"
        }

        public init(request: String, forUser: String? = nil) {
            self.request = request
            self.forUser = forUser
        }
    }

    /// `control/linkDecided`: a request ended, or went to another person, so its card goes.
    struct ChannelLinkDecided: Codable, Sendable, Hashable {
        public var request: String
        public var result: String

        public init(request: String, result: String) {
            self.request = request
            self.result = result
        }
    }

    /// `links/remove`.
    struct ChannelLinkRemove: Codable, Sendable, Hashable {
        public var channel: String
        public var identity: String

        public init(channel: String, identity: String) {
            self.channel = channel
            self.identity = identity
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `[ChannelLink]`: the caller's links; an admin's, everyone's (#1762).
    static let linksList = "links/list"
    /// `Empty` → `[ChannelLinkRequest]`: the requests this person decides (#1762).
    static let linksRequests = "links/requests"
    /// `ChannelLinkDecide` → `{}` (#1762).
    static let linksApprove = "links/approve"
    /// `ChannelLinkDecide` → `{}` (#1762).
    static let linksDeny = "links/deny"
    /// `ChannelLinkRemove` → `{}`: one's own, or an admin's of anyone (#1762).
    static let linksRemove = "links/remove"
}

public extension DaemonAPI.Notification {
    /// `ChannelLinkRequest`: a channel identity asks to be linked (#1762).
    static let controlLinkRequested = "control/linkRequested"
    /// `ChannelLinkDecided`: a request ended or was sent on (#1762).
    static let controlLinkDecided = "control/linkDecided"
    /// `Empty`: load the links again (#1762).
    static let controlLinksChanged = "control/linksChanged"
}

/// The link requests waiting, as a client keeps them: one card each, newest last, and
/// none past its end (#1762).
public struct ChannelLinkRequestQueue: Sendable, Hashable {
    public private(set) var requests: [DaemonAPI.ChannelLinkRequest] = []

    public init(_ requests: [DaemonAPI.ChannelLinkRequest] = []) {
        replace(with: requests)
    }

    /// What `links/requests` said, in place of what was kept.
    public mutating func replace(with listed: [DaemonAPI.ChannelLinkRequest]) {
        requests = []
        for request in listed { add(request) }
    }

    /// `control/linkRequested`: a new card, or the same one again in place.
    public mutating func add(_ request: DaemonAPI.ChannelLinkRequest) {
        if let index = requests.firstIndex(where: { $0.request == request.request }) {
            requests[index] = request
        } else {
            requests.append(request)
        }
    }

    /// `control/linkDecided`, or an answer from here: the card goes.
    public mutating func remove(_ request: String) {
        requests.removeAll { $0.request == request }
    }

    /// The cards to show at `now`: a request past its end is not.
    public func open(at now: Date = Date()) -> [DaemonAPI.ChannelLinkRequest] {
        requests.filter { $0.expires > now }
    }
}

/// The words of the link card and Control plane ▸ Channels, the same on the Mac and the
/// Remote; the web page's are `Web/src/model/channelLinks.ts` (#1762).
public enum ChannelLinkWords {
    public static let title = "Channels"

    /// A channel's name as people say it: Slack, Discord; an unknown one as it is sent.
    public static func channel(_ channel: String) -> String {
        switch channel {
        case "slack": "Slack"
        case "discord": "Discord"
        case "teams": "Teams"
        case "whatsapp": "WhatsApp"
        case "email": "Email"
        default: channel.prefix(1).uppercased() + channel.dropFirst()
        }
    }

    /// "Slack user @sam", or "the email address sam@example.com".
    public static func who(channel: String, identity: String, name: String?) -> String {
        if channel == "email" { return "the email address \(identity)" }
        let shown = name.flatMap { $0.isEmpty ? nil : $0 } ?? identity
        return "\(Self.channel(channel)) user \(shown)"
    }

    /// The card's question: "Link Slack user @sam to you?"; for an admin with a request that
    /// names nobody, "Slack user @sam is not linked to anyone."
    public static func ask(_ request: DaemonAPI.ChannelLinkRequest) -> String {
        let who = who(channel: request.channel, identity: request.identity, name: request.name)
        guard request.forUser != nil else {
            return "\(who.prefix(1).uppercased() + who.dropFirst()) is not linked to anyone."
        }
        return "Link \(who) to you?"
    }

    /// The card's second line: the identity, when the name hid it, and the email the
    /// channel gave.
    public static func detail(_ request: DaemonAPI.ChannelLinkRequest) -> String? {
        var parts: [String] = []
        if request.channel != "email", let name = request.name, !name.isEmpty, name != request.identity {
            parts.append(request.identity)
        }
        if request.channel != "email", let email = request.email, !email.isEmpty { parts.append(email) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Under the buttons: what they do.
    public static func explanation(_ request: DaemonAPI.ChannelLinkRequest) -> String {
        request.forUser == nil
            ? "Send asks that person to approve it. Only they can link it to themselves."
            : "Approve lets its messages start work as you. Deny ignores it for a day."
    }

    /// A link's line in Control plane ▸ Channels: "Slack user @sam".
    public static func linkTitle(_ link: DaemonAPI.ChannelLink) -> String {
        let who = who(channel: link.channel, identity: link.identity, name: link.name)
        return who.prefix(1).uppercased() + who.dropFirst()
    }

    /// "T1/U42 · linked to Sam": whose it is, for an admin who sees everyone's.
    public static func linkDetail(_ link: DaemonAPI.ChannelLink, you: String?) -> String {
        var parts: [String] = []
        if link.channel != "email", let name = link.name, !name.isEmpty, name != link.identity { parts.append(link.identity) }
        parts.append(link.user == you ? "linked to you" : "linked to \(link.userName.flatMap { $0.isEmpty ? nil : $0 } ?? link.user)")
        return parts.joined(separator: " · ")
    }

    public static func removeTitle(_ link: DaemonAPI.ChannelLink) -> String {
        "Unlink \(who(channel: link.channel, identity: link.identity, name: link.name))?"
    }

    public static let removeMessage = "Its messages start nothing until it is linked again."

    public static let none = "No channel identity is linked."

    public static let foot = "A message from Slack, email or another channel starts work only once its person links it here. Email also needs a DKIM pass for its address."
}
