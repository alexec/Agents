import Foundation

// Assessing a runtime (#47) on the wire, in a file of its own so the lanes beside it do
// not collide in DaemonAPI.swift.

public extension DaemonAPI.Method {
    /// Start an agent on a runtime with the assessment brief, in a project.
    static let runtimesAssess = "runtimes/assess"
    /// Score an assessing agent from the daemon's own record, now.
    static let runtimesAssessment = "runtimes/assessment"
}

public extension DaemonAPI {
    /// `runtimes/assess`: which runtime, and which project the assessment works in.
    struct AssessRuntimeRequest: Codable, Sendable, Hashable {
        public var runtimeID: String
        public var folder: URL
        /// A model to assess on: one of the runtime's values, or `default` for its own
        /// default. Nil for the cheapest it offers.
        public var model: String?

        public init(runtimeID: String, folder: URL, model: String? = nil) {
            self.runtimeID = runtimeID
            self.folder = folder
            self.model = model
        }
    }

    /// The agent started, the model it was started on (nil for the runtime's default),
    /// and where its report will be.
    struct AssessRuntimeResult: Codable, Sendable, Hashable {
        public var agentID: UUID
        public var model: String?
        public var reportPath: String

        public init(agentID: UUID, model: String?, reportPath: String) {
            self.agentID = agentID
            self.model = model
            self.reportPath = reportPath
        }
    }
}
