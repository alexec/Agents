import Foundation

// MARK: - The wire (#4586)

public extension DaemonAPI {
    /// `work/features` (#4586): the features of every folder on this machine, or of one folder's
    /// repo, as `forge/features`.
    struct WorkFeaturesRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var board: String?

        public init(folder: String? = nil, board: String? = nil) {
            self.folder = folder
            self.board = board
        }
    }

    /// The Features page's one read (specs/4328-work-look/features-delivery.md): each feature with
    /// its open epics and its loose open issues, so an open feature's epics draw at once.
    struct WorkFeatures: Codable, Sendable, Hashable {
        public var features: [WorkFeature]
        public var approvals: [String]?
        public var errors: [ForgeListError]?

        public init(features: [WorkFeature] = [], approvals: [String]? = nil, errors: [ForgeListError]? = nil) {
            self.features = features
            self.approvals = approvals
            self.errors = errors
        }
    }

    /// A feature as `forge/features` says it, its open epics, and its open issues with no epic.
    struct WorkFeature: Codable, Sendable, Hashable {
        public var feature: ForgeFeature
        public var epics: [WorkFeatureEpic]
        public var loose: [WorkTimelineChild]

        public init(feature: ForgeFeature, epics: [WorkFeatureEpic] = [], loose: [WorkTimelineChild] = []) {
            self.feature = feature
            self.epics = epics
            self.loose = loose
        }
    }

    /// An open epic: `step` is the first step with an open child, of `steps`; `blockedOutside` that
    /// step's open blockers outside the plan; `forecast` as `work/timeline` gives it; `children` absent
    /// when its plan could not be read.
    struct WorkFeatureEpic: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var step: Int?
        public var steps: Int
        public var blockedOutside: [LineageNode]?
        public var forecast: WorkTimelineForecast?
        public var children: [WorkTimelineChild]?

        public init(item: ForgeItem, step: Int? = nil, steps: Int = 0, blockedOutside: [LineageNode]? = nil,
                    forecast: WorkTimelineForecast? = nil, children: [WorkTimelineChild]? = nil) {
            self.item = item
            self.step = step
            self.steps = steps
            self.blockedOutside = blockedOutside
            self.forecast = forecast
            self.children = children
        }
    }
}

public extension DaemonAPI.Method {
    /// `WorkFeaturesRequest` → `WorkFeatures` (#4586).
    static let workFeatures = "work/features"
}
