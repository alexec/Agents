import Foundation

/// Why a server's event trigger is not hearing anything (#383), and since when.
///
/// `message` is a whole sentence in the app's voice, made where it happened, so the Mac,
/// the Remote and the web page each show it as it is rather than wording the code three
/// times.
public struct MCPTriggerFailure: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        /// No server this project can use offers the event.
        case serverNotFound
        /// The server names the event against the rules: not `noun.verbed`, or about
        /// one of the app's own subjects.
        case badEventName
        case waitingForApproval
        case secretMissing
        case needsSignIn
        case unreachable
        /// The server does not declare the events capability.
        case noEvents
        case eventNotOffered
        /// The event is offered only by push or webhook.
        case noPollMode
        case badArguments
        case refused
        case serverError
    }

    public var code: Code
    public var message: String
    public var since: Date

    public init(code: Code, message: String, since: Date) {
        self.code = code
        self.message = message
        self.since = since
    }
}
