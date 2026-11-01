import Foundation

/// Policy layers (#2957): the rules an organisation, a person ("You") or a folder may set, the
/// resolver's effective result, and the person's own signed layer. The types are hand-written
/// against `Packages/Wire/daemon.schema.json` (`WireSchemaTests`); `policylayers.Resolve` in Go
/// is the one place the layers are actually combined (R12: clients draw, the machine decides).
public extension DaemonAPI {
    /// Money and tokens a layer caps per agent and per UTC day (data-model.md "PolicyRules").
    /// Unlike `PolicyBudgets`, no `allowUnmetered` or `raises`: only the organisation layer has
    /// those (FR-003).
    struct PolicyRuleBudgets: Codable, Sendable, Hashable {
        public var perAgent: Cost?
        public var daily: Cost?
        public var perAgentTokens: Int?
        public var dailyTokens: Int?

        public init(perAgent: Cost? = nil, daily: Cost? = nil, perAgentTokens: Int? = nil, dailyTokens: Int? = nil) {
            self.perAgent = perAgent
            self.daily = daily
            self.perAgentTokens = perAgentTokens
            self.dailyTokens = dailyTokens
        }
    }

    /// How many approved workflows may be turned on in each folder (data-model.md "PolicyRules").
    /// Unset means 20.
    struct PolicyWorkflows: Codable, Sendable, Hashable {
        public var mostOn: Int?

        public init(mostOn: Int? = nil) {
            self.mostOn = mostOn
        }
    }

    /// How many notices a burst allows, and how long to wait after one (data-model.md
    /// "PolicyRules"). Unset means 3 and 10 minutes.
    struct PolicyNoticeLimits: Codable, Sendable, Hashable {
        public var burst: Int?
        public var waitMinutes: Int?

        public init(burst: Int? = nil, waitMinutes: Int? = nil) {
            self.burst = burst
            self.waitMinutes = waitMinutes
        }
    }

    /// The rules a layer sets (#2957, data-model.md "PolicyRules"): the same shape on the
    /// organisation, your and a folder's layer (FR-002). Every field is optional: absent sets
    /// nothing.
    struct PolicyRules: Codable, Sendable, Hashable {
        public var permissionMode: PermissionLevel?
        public var permissionRequests: ClientPermissionMode?
        public var sandbox: SandboxChoice?
        public var budgets: PolicyRuleBudgets?
        public var helpers: PolicyHelpers?
        public var workflows: PolicyWorkflows?
        public var noticeLimits: PolicyNoticeLimits?
        public var archiveMyChats: Bool?
        public var runtimes: [String: PolicyRuntimeRule]?
        public var marketplaces: PolicyMarketplaces?
        public var environment: PolicyEnvironment?

        public init(permissionMode: PermissionLevel? = nil, permissionRequests: ClientPermissionMode? = nil,
                    sandbox: SandboxChoice? = nil, budgets: PolicyRuleBudgets? = nil, helpers: PolicyHelpers? = nil,
                    workflows: PolicyWorkflows? = nil, noticeLimits: PolicyNoticeLimits? = nil, archiveMyChats: Bool? = nil,
                    runtimes: [String: PolicyRuntimeRule]? = nil, marketplaces: PolicyMarketplaces? = nil,
                    environment: PolicyEnvironment? = nil) {
            self.permissionMode = permissionMode
            self.permissionRequests = permissionRequests
            self.sandbox = sandbox
            self.budgets = budgets
            self.helpers = helpers
            self.workflows = workflows
            self.noticeLimits = noticeLimits
            self.archiveMyChats = archiveMyChats
            self.runtimes = runtimes
            self.marketplaces = marketplaces
            self.environment = environment
        }
    }

    /// Which layer sets or decides a rule (#2957, data-model.md "PolicyLayerRef"): the
    /// organisation, the person ("You"), or a folder.
    struct PolicyLayerRef: Codable, Sendable, Hashable {
        /// `organisation`, `you` or `folder`.
        public var kind: String
        /// The organisation's name, "You", or the folder's name.
        public var name: String
        /// The folder's path, when kind is folder.
        public var folder: String?

        public init(kind: String, name: String, folder: String? = nil) {
            self.kind = kind
            self.name = name
            self.folder = folder
        }
    }

    /// One folder that sets its own rules, for the Agents ▸ Policy banner (#2957).
    struct PolicyFolderWithRules: Codable, Sendable, Hashable {
        public var folder: String
        public var name: String
        public var count: Int

        public init(folder: String, name: String, count: Int) {
            self.folder = folder
            self.name = name
            self.count = count
        }
    }

    /// A machine of the person's that does not say `host.policy-layers/1` (Edge Cases, "A
    /// machine of an older version").
    struct PolicyBehindMachine: Codable, Sendable, Hashable {
        public var host: String
        public var name: String

        public init(host: String, name: String) {
            self.host = host
            self.name = name
        }
    }

    /// One layer's value of a rule, for Where this comes from (#2957, data-model.md
    /// "EffectiveLayerValue"). `kept` is "Kept, not used": the layer sets a value and a layer
    /// above caps it (FR-006).
    struct EffectiveLayerValue: Codable, Sendable, Hashable {
        public var layer: PolicyLayerRef
        public var value: JSONValue?
        /// "Not set" when the layer does not set this rule.
        public var words: String
        public var kept: Bool

        public init(layer: PolicyLayerRef, value: JSONValue? = nil, words: String, kept: Bool = false) {
            self.layer = layer
            self.value = value
            self.words = words
            self.kept = kept
        }
    }

    /// The effective value of one rule, with every layer that sets it (#2957, data-model.md
    /// "EffectiveRule").
    struct EffectiveRule: Codable, Sendable, Hashable {
        /// `permissionMode`, `budgets.daily`, `helpers.mostRunning`, and so on.
        public var rule: String
        public var value: JSONValue?
        public var words: String
        /// Absent when no layer sets this rule: today's default applies.
        public var decides: PolicyLayerRef?
        /// Every layer from the top down, for Where this comes from.
        public var layers: [EffectiveLayerValue]
        /// The tightest value of the layers above the one being edited; a menu dims what is looser.
        public var cap: JSONValue?
        /// For example "Acme: at most Approve for me".
        public var capLine: String?

        public init(rule: String, value: JSONValue? = nil, words: String, decides: PolicyLayerRef? = nil,
                    layers: [EffectiveLayerValue] = [], cap: JSONValue? = nil, capLine: String? = nil) {
            self.rule = rule
            self.value = value
            self.words = words
            self.decides = decides
            self.layers = layers
            self.cap = cap
            self.capLine = capLine
        }
    }

    /// What a folder's agents may do, after every layer (#2957, data-model.md "EffectivePolicy").
    /// Made by `policylayers.Resolve`; never stored.
    struct EffectivePolicy: Codable, Sendable, Hashable {
        public var folder: String?
        public var rules: [EffectiveRule]
        public var organisation: String?
        public var foldersWithRules: [PolicyFolderWithRules]
        /// The person's machines that do not say `host.policy-layers/1`.
        public var behind: [PolicyBehindMachine]

        public init(folder: String? = nil, rules: [EffectiveRule] = [], organisation: String? = nil,
                    foldersWithRules: [PolicyFolderWithRules] = [], behind: [PolicyBehindMachine] = []) {
            self.folder = folder
            self.rules = rules
            self.organisation = organisation
            self.foldersWithRules = foldersWithRules
            self.behind = behind
        }
    }

    /// `policy/effective` (#2957): the rules for an agent in a folder, or, with no folder,
    /// outside any folder layer.
    struct PolicyEffectiveRequest: Codable, Sendable, Hashable {
        public var folder: String?

        public init(folder: String? = nil) {
            self.folder = folder
        }
    }

    /// `policy/folder` (#2957): a folder's own layer, from `.agents/policy.json`.
    struct PolicyFolderRequest: Codable, Sendable, Hashable {
        public var folder: String

        public init(folder: String) {
            self.folder = folder
        }
    }

    /// `policy/folder`'s result (#2957, data-model.md "A folder's layer"): the approved copy,
    /// and a waiting change when one is pending.
    struct PolicyFolderState: Codable, Sendable, Hashable {
        public var rules: PolicyRules
        public var pending: GuardedChange?
        /// Why the file on disk cannot be read as a layer, when that is why a change is pending.
        public var invalid: String?

        public init(rules: PolicyRules, pending: GuardedChange? = nil, invalid: String? = nil) {
            self.rules = rules
            self.pending = pending
            self.invalid = invalid
        }
    }

    /// `policy/setFolder` (#2957): writes `.agents/policy.json` in a stable order and approves
    /// it. A value looser than the person's own effective value is kept, and the result shows
    /// it capped.
    struct SetFolderPolicyRequest: Codable, Sendable, Hashable {
        public var folder: String
        public var rules: PolicyRules

        public init(folder: String, rules: PolicyRules) {
            self.folder = folder
            self.rules = rules
        }
    }

    /// `policy/applyYours`'s result (#2957): the revision now applied here.
    struct PolicyApplyYoursResult: Codable, Sendable, Hashable {
        public var revision: Int

        public init(revision: Int) {
            self.revision = revision
        }
    }
}

public extension DaemonAPI.Method {
    /// `PolicyEffectiveRequest` → `EffectivePolicy` (#2957).
    static let policyEffective = "policy/effective"
    /// `Empty` → `YourPolicyState` (#2957).
    static let policyYours = "policy/yours"
    /// `SetYourPolicyRequest` → `YourPolicy` (#2957).
    static let policySetYours = "policy/setYours"
    /// `PolicyFolderRequest` → `PolicyFolderState` (#2957).
    static let policyFolder = "policy/folder"
    /// `SetFolderPolicyRequest` → `PolicyRules` (#2957).
    static let policySetFolder = "policy/setFolder"
    /// `SignedYourPolicy` → `PolicyApplyYoursResult` (#2957, the Mac window's direct link only).
    static let policyApplyYours = "policy/applyYours"
}

public extension DaemonAPI.Notification {
    /// `PolicyEffectiveRequest` (#2957): a layer changed; clients call `policy/effective` again.
    static let policyEffectiveChanged = "policy/effectiveChanged"
}
