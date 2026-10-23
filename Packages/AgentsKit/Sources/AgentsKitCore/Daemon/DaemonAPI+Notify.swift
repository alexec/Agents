import Foundation

/// Notify me (#2034, specs/2034-notify-me): the project's servers with events that tell the
/// person, which are on, and a notice opened. On the host that has the project.
public extension DaemonAPI.Method {
    static let notifyList = "notify/list"
    static let notifySet = "notify/set"
    static let noticeOpen = "notice/open"
}

public extension DaemonAPI {
    struct NotifyEvent: Codable, Sendable, Hashable, Identifiable {
        public var event: String
        public var title: String
        public var on: Bool
        public var id: String { event }
        public init(event: String, title: String, on: Bool) {
            self.event = event; self.title = title; self.on = on
        }
    }

    struct NotifyServer: Codable, Sendable, Hashable, Identifiable {
        public var server: String
        public var title: String
        public var events: [NotifyEvent]
        public var id: String { server }
        public init(server: String, title: String, events: [NotifyEvent]) {
            self.server = server; self.title = title; self.events = events
        }
    }

    struct NotifyList: Codable, Sendable, Hashable {
        public var folder: String
        public var servers: [NotifyServer]
        public init(folder: String, servers: [NotifyServer]) {
            self.folder = folder; self.servers = servers
        }
    }

    struct NotifyListRequest: Codable, Sendable, Hashable {
        public var folder: String
        public init(folder: String) { self.folder = folder }
    }

    struct NotifySetRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var server: String
        public var event: String
        public var on: Bool
        public init(folder: String, server: String, event: String, on: Bool) {
            self.folder = folder; self.server = server; self.event = event; self.on = on
        }
    }

    struct NoticeOpenRequest: Codable, Sendable, Hashable {
        public var id: String
        public init(id: String) { self.id = id }
    }
}

/// Notify me's words, on the Mac, the Remote and the web page (`notifyMe.ts`).
public enum NotifyMeWords {
    public static let heading = "Notify me"
    public static let note = "A notification when these happen, on the device you are using. Your choices are yours, not the project's."
    public static let none = "No server here can notify you yet. Connect GitHub, GitLab or Linear to choose."
}
