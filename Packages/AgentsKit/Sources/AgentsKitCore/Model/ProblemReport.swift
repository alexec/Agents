import Foundation

/// Report a Problem (#3718): the host makes the person's words, the versions and, when
/// asked, its recent log lines into a GitHub new-issue link, with the tokens and the home
/// folders cut out. Nothing is sent: the client shows the body, then opens the link, so the
/// issue is posted from the person's own account.
public extension DaemonAPI {
    /// `reports/problem`'s params.
    struct ProblemReportRequest: Codable, Sendable, Hashable {
        public var happened: String
        public var expected: String
        /// The client and its version, such as "Mac window 0.17.0".
        public var client: String
        public var clientOS: String
        /// The open session's runtime, when there is one.
        public var runtime: String?
        /// Add the host's recent daemon.log lines.
        public var withLog: Bool

        public init(happened: String, expected: String, client: String, clientOS: String,
                    runtime: String? = nil, withLog: Bool) {
            self.happened = happened
            self.expected = expected
            self.client = client
            self.clientOS = clientOS
            self.runtime = runtime
            self.withLog = withLog
        }
    }

    /// `reports/problem`'s answer: the issue to show, and the page that opens it filled in.
    struct ProblemReport: Codable, Sendable, Hashable {
        public var title: String
        public var body: String
        public var url: String

        public init(title: String, body: String, url: String) {
            self.title = title
            self.body = body
            self.url = url
        }
    }
}
