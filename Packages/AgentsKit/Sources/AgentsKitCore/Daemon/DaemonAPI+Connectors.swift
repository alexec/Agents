import Foundation

/// The person's connections to tools (#1335), and each project's Connectors set-up (#1336).
///
/// A connection is the person's: one GitHub sign-in on a host covers every project there. The
/// host does the device flow and keeps the tokens; a client shows the code and the links, and
/// waits. A project's set-up is the project's: its repository, four slots that each prove
/// themselves with one real read, and the github events it turned on.
extension DaemonAPI.Method {
    public static let connectionsList = "connections/list"
    /// Starts a sign-in, or answers with the one already waiting, so two clients show one code.
    public static let connectionsSignIn = "connections/sign-in"
    /// A long poll: answers when the sign-in ends, or after 25 seconds with it still waiting.
    public static let connectionsSignInWait = "connections/sign-in/wait"
    public static let connectionsSignInCancel = "connections/sign-in/cancel"
    public static let connectionsDisconnect = "connections/disconnect"
    public static let connectorsSetup = "connectors/setup"
    public static let connectorsSetupSkip = "connectors/setup/skip"
}

extension DaemonAPI {
    public enum ConnectionProvider: String, Codable, Sendable, Hashable {
        case github
    }

    public enum ConnectionState: String, Codable, Sendable, Hashable {
        /// The host has a token and renews it.
        case connected
        /// The provider refused the renewal: the person signs in again.
        case signInAgain
    }

    /// The person's sign-in to one provider, as the host keeps it. Never its tokens.
    public struct Connection: Codable, Sendable, Hashable {
        public var provider: ConnectionProvider
        public var login: String?
        public var state: ConnectionState
        public var connectedAt: Date
        /// Where the person installs the provider's App on more repositories.
        public var installURL: String?

        public init(provider: ConnectionProvider, login: String? = nil, state: ConnectionState = .connected,
                    connectedAt: Date, installURL: String? = nil) {
            self.provider = provider; self.login = login; self.state = state
            self.connectedAt = connectedAt; self.installURL = installURL
        }
    }

    public struct ConnectionsList: Codable, Sendable, Hashable {
        public var connections: [Connection]
        public init(connections: [Connection]) { self.connections = connections }
    }

    public struct ConnectionProviderRequest: Codable, Sendable, Hashable {
        public var provider: ConnectionProvider
        public init(provider: ConnectionProvider) { self.provider = provider }
    }

    public struct ConnectionSignInFlowRequest: Codable, Sendable, Hashable {
        public var flowID: UUID
        public init(flowID: UUID) { self.flowID = flowID }
    }

    public enum ConnectionSignInStatus: String, Codable, Sendable, Hashable {
        case waiting, connected, expired, denied, cancelled, failed
    }

    /// A device-flow sign-in under way on the host.
    public struct ConnectionSignIn: Codable, Sendable, Hashable {
        public var flowID: UUID
        public var provider: ConnectionProvider
        public var status: ConnectionSignInStatus
        /// The code the person types on the provider's page, such as WDJB-MJHT.
        public var userCode: String
        public var verificationURL: String
        public var installURL: String?
        public var expiresAt: Date
        public var connection: Connection?
        /// Why it failed, in words.
        public var message: String?

        public init(flowID: UUID, provider: ConnectionProvider, status: ConnectionSignInStatus, userCode: String,
                    verificationURL: String, installURL: String? = nil, expiresAt: Date,
                    connection: Connection? = nil, message: String? = nil) {
            self.flowID = flowID; self.provider = provider; self.status = status; self.userCode = userCode
            self.verificationURL = verificationURL; self.installURL = installURL; self.expiresAt = expiresAt
            self.connection = connection; self.message = message
        }
    }

    public struct ConnectionDisconnectAnswer: Codable, Sendable, Hashable {
        public var error: String?
        public init(error: String? = nil) { self.error = error }
    }

    /// One slot of a project's set-up, in the page's order.
    public enum ConnectorSlotKind: String, Codable, Sendable, Hashable, CaseIterable {
        case tasks, codeReview, ci, workspace
    }

    public enum ConnectorSlotState: String, Codable, Sendable, Hashable {
        /// It comes with a connection that is not there yet.
        case notConnected
        /// Connected, but not read yet (a stored reading).
        case notRead
        /// Its one read worked: a tick.
        case read
        /// The read did not reach the provider.
        case failed
        /// The provider refused the read: the person grants it on the provider's site.
        case refused
        /// The project has no GitHub remote.
        case noRemote
        /// Skipped: it counts as done.
        case skipped

        /// Done: it read, or the person skipped it.
        public var isDone: Bool { self == .read || self == .skipped }
    }

    /// The one real thing a slot read.
    public struct ConnectorProof: Codable, Sendable, Hashable {
        public var number: Int?
        /// Its title, or the run's workflow and branch, such as "CI on main".
        public var title: String
        /// A run's outcome in a word: passed, failed, running, cancelled.
        public var outcome: String?
        public var url: String?
        public var at: Date?

        public init(number: Int? = nil, title: String, outcome: String? = nil, url: String? = nil, at: Date? = nil) {
            self.number = number; self.title = title; self.outcome = outcome; self.url = url; self.at = at
        }
    }

    public struct ConnectorSlot: Codable, Sendable, Hashable, Identifiable {
        public var slot: ConnectorSlotKind
        /// What fills it, in words: GitHub Issues, This Mac.
        public var choice: String
        public var state: ConnectorSlotState
        public var proof: ConnectorProof?
        public var readAt: Date?
        public var message: String?

        public var id: ConnectorSlotKind { slot }

        public init(slot: ConnectorSlotKind, choice: String, state: ConnectorSlotState, proof: ConnectorProof? = nil,
                    readAt: Date? = nil, message: String? = nil) {
            self.slot = slot; self.choice = choice; self.state = state; self.proof = proof
            self.readAt = readAt; self.message = message
        }
    }

    public enum ConnectorEventsState: String, Codable, Sendable, Hashable {
        case on, off, taken, failed
    }

    public struct ConnectorWorkflow: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// The github events the set-up turned on, and the workflows that start on one of them.
    public struct ConnectorEvents: Codable, Sendable, Hashable {
        public var state: ConnectorEventsState
        public var names: [String]
        public var server: String?
        public var workflows: [ConnectorWorkflow]
        public var message: String?

        public init(state: ConnectorEventsState, names: [String] = [], server: String? = nil,
                    workflows: [ConnectorWorkflow] = [], message: String? = nil) {
            self.state = state; self.names = names; self.server = server; self.workflows = workflows; self.message = message
        }
    }

    /// A project's Connectors set-up (#1336).
    public struct ConnectorSetup: Codable, Sendable, Hashable {
        public var folder: String
        /// owner/name, from the project's git remote. Nil with no GitHub remote.
        public var repository: String?
        public var connection: Connection?
        /// Whether the Agents App is installed on the repository; nil when not known.
        public var installed: Bool?
        public var installURL: String?
        /// How many repositories the connection sees through the App.
        public var repositories: Int?
        public var slots: [ConnectorSlot]
        public var events: ConnectorEvents
        /// Slots that read or were skipped, of the four.
        public var done: Int

        public init(folder: String, repository: String? = nil, connection: Connection? = nil, installed: Bool? = nil,
                    installURL: String? = nil, repositories: Int? = nil, slots: [ConnectorSlot],
                    events: ConnectorEvents, done: Int) {
            self.folder = folder; self.repository = repository; self.connection = connection; self.installed = installed
            self.installURL = installURL; self.repositories = repositories; self.slots = slots; self.events = events
            self.done = done
        }

        public func slot(_ kind: ConnectorSlotKind) -> ConnectorSlot? { slots.first { $0.slot == kind } }
    }

    public enum ConnectorSetupReading: String, Codable, Sendable, Hashable {
        /// No call to the provider: only what was read before.
        case stored
        /// A read at most five minutes old is used again.
        case cached
        /// Read now (Try Again).
        case fresh
    }

    public struct ConnectorSetupRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var reading: ConnectorSetupReading?
        public init(folder: String, reading: ConnectorSetupReading? = nil) { self.folder = folder; self.reading = reading }
    }

    public struct ConnectorSkipRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var slot: ConnectorSlotKind
        public var skipped: Bool
        public init(folder: String, slot: ConnectorSlotKind, skipped: Bool) {
            self.folder = folder; self.slot = slot; self.skipped = skipped
        }
    }
}
