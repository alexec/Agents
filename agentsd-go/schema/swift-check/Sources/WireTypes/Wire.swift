// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//
//   let wire = try Wire(json)

import Foundation

// MARK: - Wire
public struct Wire: Codable {
    public let agent: WAgent?
    public let listRequest: WListRequest?
    public let optionsResponse: WOptionsResponse?
    public let permissionRequest: WPermissionRequest?
    public let projectSummary: WProjectSummary?
    public let promptRequest: WPromptRequest?
    public let runtimeStatus: WRuntimeStatus?
    public let startRequest: WStartRequest?
    public let transcriptEntry: WTranscriptEntry?
    public let transcriptPage: WTranscriptPage?
    public let turnsPage: WTurnsPage?

    public init(agent: WAgent?, listRequest: WListRequest?, optionsResponse: WOptionsResponse?, permissionRequest: WPermissionRequest?, projectSummary: WProjectSummary?, promptRequest: WPromptRequest?, runtimeStatus: WRuntimeStatus?, startRequest: WStartRequest?, transcriptEntry: WTranscriptEntry?, transcriptPage: WTranscriptPage?, turnsPage: WTurnsPage?) {
        self.agent = agent
        self.listRequest = listRequest
        self.optionsResponse = optionsResponse
        self.permissionRequest = permissionRequest
        self.projectSummary = projectSummary
        self.promptRequest = promptRequest
        self.runtimeStatus = runtimeStatus
        self.startRequest = startRequest
        self.transcriptEntry = transcriptEntry
        self.transcriptPage = transcriptPage
        self.turnsPage = turnsPage
    }
}

// MARK: Wire convenience initializers and mutators

public extension Wire {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Wire.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agent: WAgent?? = nil,
        listRequest: WListRequest?? = nil,
        optionsResponse: WOptionsResponse?? = nil,
        permissionRequest: WPermissionRequest?? = nil,
        projectSummary: WProjectSummary?? = nil,
        promptRequest: WPromptRequest?? = nil,
        runtimeStatus: WRuntimeStatus?? = nil,
        startRequest: WStartRequest?? = nil,
        transcriptEntry: WTranscriptEntry?? = nil,
        transcriptPage: WTranscriptPage?? = nil,
        turnsPage: WTurnsPage?? = nil
    ) -> Wire {
        return Wire(
            agent: agent ?? self.agent,
            listRequest: listRequest ?? self.listRequest,
            optionsResponse: optionsResponse ?? self.optionsResponse,
            permissionRequest: permissionRequest ?? self.permissionRequest,
            projectSummary: projectSummary ?? self.projectSummary,
            promptRequest: promptRequest ?? self.promptRequest,
            runtimeStatus: runtimeStatus ?? self.runtimeStatus,
            startRequest: startRequest ?? self.startRequest,
            transcriptEntry: transcriptEntry ?? self.transcriptEntry,
            transcriptPage: transcriptPage ?? self.transcriptPage,
            turnsPage: turnsPage ?? self.turnsPage
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAgent
public struct WAgent: Codable {
    public let additionalDirectories: [String]?
    public let advertisedOptions: [WConfigOption]
    public let afterTurn: WAfterTurn?
    public let archivedAt: Double?
    public let archivedReason: WAgentArchivedReason?
    public let archiveRequest: WArchiveRequest?
    public let availableCommands: [WSlashCommand]
    public let background: [WBackgroundItem]?
    public let chainDepth: Double?
    public let costCeiling: WCost?
    public let costToDate: [String: Double]?
    public let createdAt: Double
    public let cwd: String
    public let effectiveSandbox: WEffectiveSandbox?
    public let endedReason: WEndedReason?
    public let eventWait: WEventWait?
    public let id: String
    public let isUnread: Bool?
    public let labels: [WSessionLabel]?
    public let lastActivityAt: Double
    public let lastTurnUsage: WTurnUsage?
    public let listsLeftOut: Bool?
    public let madeInRoot: String?
    public let mcpServers: [WMCPServer]?
    public let missingFolder: WMissingFolder?
    public let outcomeAsked: Bool?
    public let pendingMove: WPendingMove?
    public let pendingSandboxFailure: WSandboxFailureRecord?
    public let persona: String?
    public let plans: [WPlan]?
    public let purpose: WAgentPurpose?
    public let queuedPrompts: [WQueuedPrompt]?
    public let queuedStart: WQueuedStart?
    public let report: WorkReport?
    public let reportSeenAt, restartPickUps: Double?
    public let runtimeID: String
    public let runtimeSessionID, runtimeTitle: String?
    public let sandboxOverride: WSandboxChoice?
    public let startedByAgent, startedByRun: String?
    public let startedByWorkflow: String?
    public let startingPoint: WStartingPoint?
    public let startOptions: WStartOptions
    public let startRequestID: String?
    public let state: WAgentState
    public let suggestedPrompts: [WSuggestedPrompt]?
    public let title: String?
    public let titleIsPersons: Bool?
    public let tokenCeiling, tokensToDate: Double?
    public let usage: WUsage?
    public let worktree: WAgentWorktree?

    public init(additionalDirectories: [String]?, advertisedOptions: [WConfigOption], afterTurn: WAfterTurn?, archivedAt: Double?, archivedReason: WAgentArchivedReason?, archiveRequest: WArchiveRequest?, availableCommands: [WSlashCommand], background: [WBackgroundItem]?, chainDepth: Double?, costCeiling: WCost?, costToDate: [String: Double]?, createdAt: Double, cwd: String, effectiveSandbox: WEffectiveSandbox?, endedReason: WEndedReason?, eventWait: WEventWait?, id: String, isUnread: Bool?, labels: [WSessionLabel]?, lastActivityAt: Double, lastTurnUsage: WTurnUsage?, listsLeftOut: Bool?, madeInRoot: String?, mcpServers: [WMCPServer]?, missingFolder: WMissingFolder?, outcomeAsked: Bool?, pendingMove: WPendingMove?, pendingSandboxFailure: WSandboxFailureRecord?, persona: String?, plans: [WPlan]?, purpose: WAgentPurpose?, queuedPrompts: [WQueuedPrompt]?, queuedStart: WQueuedStart?, report: WorkReport?, reportSeenAt: Double?, restartPickUps: Double?, runtimeID: String, runtimeSessionID: String?, runtimeTitle: String?, sandboxOverride: WSandboxChoice?, startedByAgent: String?, startedByRun: String?, startedByWorkflow: String?, startingPoint: WStartingPoint?, startOptions: WStartOptions, startRequestID: String?, state: WAgentState, suggestedPrompts: [WSuggestedPrompt]?, title: String?, titleIsPersons: Bool?, tokenCeiling: Double?, tokensToDate: Double?, usage: WUsage?, worktree: WAgentWorktree?) {
        self.additionalDirectories = additionalDirectories
        self.advertisedOptions = advertisedOptions
        self.afterTurn = afterTurn
        self.archivedAt = archivedAt
        self.archivedReason = archivedReason
        self.archiveRequest = archiveRequest
        self.availableCommands = availableCommands
        self.background = background
        self.chainDepth = chainDepth
        self.costCeiling = costCeiling
        self.costToDate = costToDate
        self.createdAt = createdAt
        self.cwd = cwd
        self.effectiveSandbox = effectiveSandbox
        self.endedReason = endedReason
        self.eventWait = eventWait
        self.id = id
        self.isUnread = isUnread
        self.labels = labels
        self.lastActivityAt = lastActivityAt
        self.lastTurnUsage = lastTurnUsage
        self.listsLeftOut = listsLeftOut
        self.madeInRoot = madeInRoot
        self.mcpServers = mcpServers
        self.missingFolder = missingFolder
        self.outcomeAsked = outcomeAsked
        self.pendingMove = pendingMove
        self.pendingSandboxFailure = pendingSandboxFailure
        self.persona = persona
        self.plans = plans
        self.purpose = purpose
        self.queuedPrompts = queuedPrompts
        self.queuedStart = queuedStart
        self.report = report
        self.reportSeenAt = reportSeenAt
        self.restartPickUps = restartPickUps
        self.runtimeID = runtimeID
        self.runtimeSessionID = runtimeSessionID
        self.runtimeTitle = runtimeTitle
        self.sandboxOverride = sandboxOverride
        self.startedByAgent = startedByAgent
        self.startedByRun = startedByRun
        self.startedByWorkflow = startedByWorkflow
        self.startingPoint = startingPoint
        self.startOptions = startOptions
        self.startRequestID = startRequestID
        self.state = state
        self.suggestedPrompts = suggestedPrompts
        self.title = title
        self.titleIsPersons = titleIsPersons
        self.tokenCeiling = tokenCeiling
        self.tokensToDate = tokensToDate
        self.usage = usage
        self.worktree = worktree
    }
}

// MARK: WAgent convenience initializers and mutators

public extension WAgent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAgent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        additionalDirectories: [String]?? = nil,
        advertisedOptions: [WConfigOption]? = nil,
        afterTurn: WAfterTurn?? = nil,
        archivedAt: Double?? = nil,
        archivedReason: WAgentArchivedReason?? = nil,
        archiveRequest: WArchiveRequest?? = nil,
        availableCommands: [WSlashCommand]? = nil,
        background: [WBackgroundItem]?? = nil,
        chainDepth: Double?? = nil,
        costCeiling: WCost?? = nil,
        costToDate: [String: Double]?? = nil,
        createdAt: Double? = nil,
        cwd: String? = nil,
        effectiveSandbox: WEffectiveSandbox?? = nil,
        endedReason: WEndedReason?? = nil,
        eventWait: WEventWait?? = nil,
        id: String? = nil,
        isUnread: Bool?? = nil,
        labels: [WSessionLabel]?? = nil,
        lastActivityAt: Double? = nil,
        lastTurnUsage: WTurnUsage?? = nil,
        listsLeftOut: Bool?? = nil,
        madeInRoot: String?? = nil,
        mcpServers: [WMCPServer]?? = nil,
        missingFolder: WMissingFolder?? = nil,
        outcomeAsked: Bool?? = nil,
        pendingMove: WPendingMove?? = nil,
        pendingSandboxFailure: WSandboxFailureRecord?? = nil,
        persona: String?? = nil,
        plans: [WPlan]?? = nil,
        purpose: WAgentPurpose?? = nil,
        queuedPrompts: [WQueuedPrompt]?? = nil,
        queuedStart: WQueuedStart?? = nil,
        report: WorkReport?? = nil,
        reportSeenAt: Double?? = nil,
        restartPickUps: Double?? = nil,
        runtimeID: String? = nil,
        runtimeSessionID: String?? = nil,
        runtimeTitle: String?? = nil,
        sandboxOverride: WSandboxChoice?? = nil,
        startedByAgent: String?? = nil,
        startedByRun: String?? = nil,
        startedByWorkflow: String?? = nil,
        startingPoint: WStartingPoint?? = nil,
        startOptions: WStartOptions? = nil,
        startRequestID: String?? = nil,
        state: WAgentState? = nil,
        suggestedPrompts: [WSuggestedPrompt]?? = nil,
        title: String?? = nil,
        titleIsPersons: Bool?? = nil,
        tokenCeiling: Double?? = nil,
        tokensToDate: Double?? = nil,
        usage: WUsage?? = nil,
        worktree: WAgentWorktree?? = nil
    ) -> WAgent {
        return WAgent(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            advertisedOptions: advertisedOptions ?? self.advertisedOptions,
            afterTurn: afterTurn ?? self.afterTurn,
            archivedAt: archivedAt ?? self.archivedAt,
            archivedReason: archivedReason ?? self.archivedReason,
            archiveRequest: archiveRequest ?? self.archiveRequest,
            availableCommands: availableCommands ?? self.availableCommands,
            background: background ?? self.background,
            chainDepth: chainDepth ?? self.chainDepth,
            costCeiling: costCeiling ?? self.costCeiling,
            costToDate: costToDate ?? self.costToDate,
            createdAt: createdAt ?? self.createdAt,
            cwd: cwd ?? self.cwd,
            effectiveSandbox: effectiveSandbox ?? self.effectiveSandbox,
            endedReason: endedReason ?? self.endedReason,
            eventWait: eventWait ?? self.eventWait,
            id: id ?? self.id,
            isUnread: isUnread ?? self.isUnread,
            labels: labels ?? self.labels,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt,
            lastTurnUsage: lastTurnUsage ?? self.lastTurnUsage,
            listsLeftOut: listsLeftOut ?? self.listsLeftOut,
            madeInRoot: madeInRoot ?? self.madeInRoot,
            mcpServers: mcpServers ?? self.mcpServers,
            missingFolder: missingFolder ?? self.missingFolder,
            outcomeAsked: outcomeAsked ?? self.outcomeAsked,
            pendingMove: pendingMove ?? self.pendingMove,
            pendingSandboxFailure: pendingSandboxFailure ?? self.pendingSandboxFailure,
            persona: persona ?? self.persona,
            plans: plans ?? self.plans,
            purpose: purpose ?? self.purpose,
            queuedPrompts: queuedPrompts ?? self.queuedPrompts,
            queuedStart: queuedStart ?? self.queuedStart,
            report: report ?? self.report,
            reportSeenAt: reportSeenAt ?? self.reportSeenAt,
            restartPickUps: restartPickUps ?? self.restartPickUps,
            runtimeID: runtimeID ?? self.runtimeID,
            runtimeSessionID: runtimeSessionID ?? self.runtimeSessionID,
            runtimeTitle: runtimeTitle ?? self.runtimeTitle,
            sandboxOverride: sandboxOverride ?? self.sandboxOverride,
            startedByAgent: startedByAgent ?? self.startedByAgent,
            startedByRun: startedByRun ?? self.startedByRun,
            startedByWorkflow: startedByWorkflow ?? self.startedByWorkflow,
            startingPoint: startingPoint ?? self.startingPoint,
            startOptions: startOptions ?? self.startOptions,
            startRequestID: startRequestID ?? self.startRequestID,
            state: state ?? self.state,
            suggestedPrompts: suggestedPrompts ?? self.suggestedPrompts,
            title: title ?? self.title,
            titleIsPersons: titleIsPersons ?? self.titleIsPersons,
            tokenCeiling: tokenCeiling ?? self.tokenCeiling,
            tokensToDate: tokensToDate ?? self.tokensToDate,
            usage: usage ?? self.usage,
            worktree: worktree ?? self.worktree
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// ConfigOption (Model/Options.swift), as its encode(to:) writes it: `type` is the kind's
/// wire name, and `options` is a flat list for one unnamed group, else the groups.
// MARK: - WConfigOption
public struct WConfigOption: Codable {
    public let category: String?
    public let currentValue: JSONAny?
    public let description: String?
    public let id, name: String
    public let options: [WConfigChoice]?
    /// "select", "boolean", or a kind this build doesn't know, carried as itself.
    public let type: String

    public init(category: String?, currentValue: JSONAny?, description: String?, id: String, name: String, options: [WConfigChoice]?, type: String) {
        self.category = category
        self.currentValue = currentValue
        self.description = description
        self.id = id
        self.name = name
        self.options = options
        self.type = type
    }
}

// MARK: WConfigOption convenience initializers and mutators

public extension WConfigOption {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WConfigOption.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        category: String?? = nil,
        currentValue: JSONAny?? = nil,
        description: String?? = nil,
        id: String? = nil,
        name: String? = nil,
        options: [WConfigChoice]?? = nil,
        type: String? = nil
    ) -> WConfigOption {
        return WConfigOption(
            category: category ?? self.category,
            currentValue: currentValue ?? self.currentValue,
            description: description ?? self.description,
            id: id ?? self.id,
            name: name ?? self.name,
            options: options ?? self.options,
            type: type ?? self.type
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WConfigChoice
public struct WConfigChoice: Codable {
    public let description, name: String?
    public let value: JSONAny?
    public let group: String?
    public let options: [WPurpleConfigChoice]?

    public init(description: String?, name: String?, value: JSONAny?, group: String?, options: [WPurpleConfigChoice]?) {
        self.description = description
        self.name = name
        self.value = value
        self.group = group
        self.options = options
    }
}

// MARK: WConfigChoice convenience initializers and mutators

public extension WConfigChoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WConfigChoice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        name: String?? = nil,
        value: JSONAny?? = nil,
        group: String?? = nil,
        options: [WPurpleConfigChoice]?? = nil
    ) -> WConfigChoice {
        return WConfigChoice(
            description: description ?? self.description,
            name: name ?? self.name,
            value: value ?? self.value,
            group: group ?? self.group,
            options: options ?? self.options
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPurpleConfigChoice
public struct WPurpleConfigChoice: Codable {
    public let description: String?
    public let name: String
    public let value: JSONAny

    public init(description: String?, name: String, value: JSONAny) {
        self.description = description
        self.name = name
        self.value = value
    }
}

// MARK: WPurpleConfigChoice convenience initializers and mutators

public extension WPurpleConfigChoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPurpleConfigChoice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        name: String? = nil,
        value: JSONAny? = nil
    ) -> WPurpleConfigChoice {
        return WPurpleConfigChoice(
            description: description ?? self.description,
            name: name ?? self.name,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WAfterTurn: String, Codable {
    case archive = "archive"
    case requestArchive = "request_archive"
}

// MARK: - WArchiveRequest
public struct WArchiveRequest: Codable {
    public let whenTurnEnds: WhenTurnEnds?
    public let requested: WRequested?

    public init(whenTurnEnds: WhenTurnEnds?, requested: WRequested?) {
        self.whenTurnEnds = whenTurnEnds
        self.requested = requested
    }
}

// MARK: WArchiveRequest convenience initializers and mutators

public extension WArchiveRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WArchiveRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        whenTurnEnds: WhenTurnEnds?? = nil,
        requested: WRequested?? = nil
    ) -> WArchiveRequest {
        return WArchiveRequest(
            whenTurnEnds: whenTurnEnds ?? self.whenTurnEnds,
            requested: requested ?? self.requested
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRequested
public struct WRequested: Codable {
    public let at: Double

    public init(at: Double) {
        self.at = at
    }
}

// MARK: WRequested convenience initializers and mutators

public extension WRequested {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRequested.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil
    ) -> WRequested {
        return WRequested(
            at: at ?? self.at
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WhenTurnEnds
public struct WhenTurnEnds: Codable {
    public let since: Double

    public init(since: Double) {
        self.since = since
    }
}

// MARK: WhenTurnEnds convenience initializers and mutators

public extension WhenTurnEnds {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WhenTurnEnds.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        since: Double? = nil
    ) -> WhenTurnEnds {
        return WhenTurnEnds(
            since: since ?? self.since
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WAgentArchivedReason: String, Codable {
    case byAgent = "byAgent"
    case byUser = "byUser"
}

// MARK: - WSlashCommand
public struct WSlashCommand: Codable {
    public let description, inputHint: String?
    public let name: String

    public init(description: String?, inputHint: String?, name: String) {
        self.description = description
        self.inputHint = inputHint
        self.name = name
    }
}

// MARK: WSlashCommand convenience initializers and mutators

public extension WSlashCommand {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSlashCommand.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        inputHint: String?? = nil,
        name: String? = nil
    ) -> WSlashCommand {
        return WSlashCommand(
            description: description ?? self.description,
            inputHint: inputHint ?? self.inputHint,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WBackgroundItem
public struct WBackgroundItem: Codable {
    public let canStop: Bool
    public let command, detail: String?
    public let endedAt: Double?
    public let id: String
    public let isStopping: Bool
    public let kind: WBackgroundItemKind
    public let lastToolName: String?
    public let name: String
    public let outputFilePath, parentID: String?
    public let startedAt: Double
    public let state: WBackgroundItemState
    public let summary, taskType, toolCallID: String?

    public init(canStop: Bool, command: String?, detail: String?, endedAt: Double?, id: String, isStopping: Bool, kind: WBackgroundItemKind, lastToolName: String?, name: String, outputFilePath: String?, parentID: String?, startedAt: Double, state: WBackgroundItemState, summary: String?, taskType: String?, toolCallID: String?) {
        self.canStop = canStop
        self.command = command
        self.detail = detail
        self.endedAt = endedAt
        self.id = id
        self.isStopping = isStopping
        self.kind = kind
        self.lastToolName = lastToolName
        self.name = name
        self.outputFilePath = outputFilePath
        self.parentID = parentID
        self.startedAt = startedAt
        self.state = state
        self.summary = summary
        self.taskType = taskType
        self.toolCallID = toolCallID
    }
}

// MARK: WBackgroundItem convenience initializers and mutators

public extension WBackgroundItem {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WBackgroundItem.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        canStop: Bool? = nil,
        command: String?? = nil,
        detail: String?? = nil,
        endedAt: Double?? = nil,
        id: String? = nil,
        isStopping: Bool? = nil,
        kind: WBackgroundItemKind? = nil,
        lastToolName: String?? = nil,
        name: String? = nil,
        outputFilePath: String?? = nil,
        parentID: String?? = nil,
        startedAt: Double? = nil,
        state: WBackgroundItemState? = nil,
        summary: String?? = nil,
        taskType: String?? = nil,
        toolCallID: String?? = nil
    ) -> WBackgroundItem {
        return WBackgroundItem(
            canStop: canStop ?? self.canStop,
            command: command ?? self.command,
            detail: detail ?? self.detail,
            endedAt: endedAt ?? self.endedAt,
            id: id ?? self.id,
            isStopping: isStopping ?? self.isStopping,
            kind: kind ?? self.kind,
            lastToolName: lastToolName ?? self.lastToolName,
            name: name ?? self.name,
            outputFilePath: outputFilePath ?? self.outputFilePath,
            parentID: parentID ?? self.parentID,
            startedAt: startedAt ?? self.startedAt,
            state: state ?? self.state,
            summary: summary ?? self.summary,
            taskType: taskType ?? self.taskType,
            toolCallID: toolCallID ?? self.toolCallID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WBackgroundItemKind: String, Codable {
    case subagent = "subagent"
    case task = "task"
}

public enum WBackgroundItemState: String, Codable {
    case completed = "completed"
    case disconnected = "disconnected"
    case failed = "failed"
    case paused = "paused"
    case running = "running"
    case stopped = "stopped"
}

// MARK: - WCost
public struct WCost: Codable {
    public let amount: Double
    public let currency: String

    public init(amount: Double, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

// MARK: WCost convenience initializers and mutators

public extension WCost {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCost.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        amount: Double? = nil,
        currency: String? = nil
    ) -> WCost {
        return WCost(
            amount: amount ?? self.amount,
            currency: currency ?? self.currency
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WEffectiveSandbox
public struct WEffectiveSandbox: Codable {
    public let reason: String?
    public let requested: WSandboxChoice
    public let state: WSandboxState

    public init(reason: String?, requested: WSandboxChoice, state: WSandboxState) {
        self.reason = reason
        self.requested = requested
        self.state = state
    }
}

// MARK: WEffectiveSandbox convenience initializers and mutators

public extension WEffectiveSandbox {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WEffectiveSandbox.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reason: String?? = nil,
        requested: WSandboxChoice? = nil,
        state: WSandboxState? = nil
    ) -> WEffectiveSandbox {
        return WEffectiveSandbox(
            reason: reason ?? self.reason,
            requested: requested ?? self.requested,
            state: state ?? self.state
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WSandboxChoice: String, Codable {
    case off = "off"
    case on = "on"
    case runtime = "runtime"
}

public enum WSandboxState: String, Codable {
    case none = "none"
    case off = "off"
    case on = "on"
    case runtimeControlled = "runtimeControlled"
}

public enum WEndedReason: String, Codable {
    case allowanceSpent = "allowanceSpent"
    case cancelled = "cancelled"
    case costLimit = "costLimit"
    case daemonGone = "daemonGone"
    case endTurn = "endTurn"
    case imported = "imported"
    case maxTokens = "maxTokens"
    case maxTurnRequests = "maxTurnRequests"
    case processDied = "processDied"
    case rateLimited = "rateLimited"
    case refusal = "refusal"
    case runtimeError = "runtimeError"
    case sandboxFailed = "sandboxFailed"
    case signInRefused = "signInRefused"
    case stoppedByAgent = "stoppedByAgent"
    case unrecognised = "unrecognised"
}

// MARK: - WEventWait
public struct WEventWait: Codable {
    public let deadline: Double?
    public let ending: WEventWaitEnding?
    public let from: Double
    public let id: String
    public let patterns: [WEventPattern]
    public let resumePromptID: String?
    public let serverEvents: [WaitServerEvent]?
    public let since: Double

    public init(deadline: Double?, ending: WEventWaitEnding?, from: Double, id: String, patterns: [WEventPattern], resumePromptID: String?, serverEvents: [WaitServerEvent]?, since: Double) {
        self.deadline = deadline
        self.ending = ending
        self.from = from
        self.id = id
        self.patterns = patterns
        self.resumePromptID = resumePromptID
        self.serverEvents = serverEvents
        self.since = since
    }
}

// MARK: WEventWait convenience initializers and mutators

public extension WEventWait {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WEventWait.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        deadline: Double?? = nil,
        ending: WEventWaitEnding?? = nil,
        from: Double? = nil,
        id: String? = nil,
        patterns: [WEventPattern]? = nil,
        resumePromptID: String?? = nil,
        serverEvents: [WaitServerEvent]?? = nil,
        since: Double? = nil
    ) -> WEventWait {
        return WEventWait(
            deadline: deadline ?? self.deadline,
            ending: ending ?? self.ending,
            from: from ?? self.from,
            id: id ?? self.id,
            patterns: patterns ?? self.patterns,
            resumePromptID: resumePromptID ?? self.resumePromptID,
            serverEvents: serverEvents ?? self.serverEvents,
            since: since ?? self.since
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WEventWaitEnding
public struct WEventWaitEnding: Codable {
    public let matched: WMatched?
    public let timedOut: [String: JSONAny]?
    public let cancelled: WCancelled?
    public let couldNotWake: WCouldNotWake?

    public init(matched: WMatched?, timedOut: [String: JSONAny]?, cancelled: WCancelled?, couldNotWake: WCouldNotWake?) {
        self.matched = matched
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.couldNotWake = couldNotWake
    }
}

// MARK: WEventWaitEnding convenience initializers and mutators

public extension WEventWaitEnding {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WEventWaitEnding.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        matched: WMatched?? = nil,
        timedOut: [String: JSONAny]?? = nil,
        cancelled: WCancelled?? = nil,
        couldNotWake: WCouldNotWake?? = nil
    ) -> WEventWaitEnding {
        return WEventWaitEnding(
            matched: matched ?? self.matched,
            timedOut: timedOut ?? self.timedOut,
            cancelled: cancelled ?? self.cancelled,
            couldNotWake: couldNotWake ?? self.couldNotWake
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WCancelled
public struct WCancelled: Codable {
    public let by: WEventWaitEndingCanceller

    public init(by: WEventWaitEndingCanceller) {
        self.by = by
    }
}

// MARK: WCancelled convenience initializers and mutators

public extension WCancelled {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCancelled.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        by: WEventWaitEndingCanceller? = nil
    ) -> WCancelled {
        return WCancelled(
            by: by ?? self.by
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WEventWaitEndingCanceller: String, Codable {
    case agent = "agent"
    case archiveRequested = "archiveRequested"
    case archived = "archived"
    case person = "person"
    case prompt = "prompt"
    case stopped = "stopped"
}

// MARK: - WCouldNotWake
public struct WCouldNotWake: Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: WCouldNotWake convenience initializers and mutators

public extension WCouldNotWake {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCouldNotWake.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reason: String? = nil
    ) -> WCouldNotWake {
        return WCouldNotWake(
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMatched
public struct WMatched: Codable {
    public let extraMatches, position: Double

    public init(extraMatches: Double, position: Double) {
        self.extraMatches = extraMatches
        self.position = position
    }
}

// MARK: WMatched convenience initializers and mutators

public extension WMatched {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMatched.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        extraMatches: Double? = nil,
        position: Double? = nil
    ) -> WMatched {
        return WMatched(
            extraMatches: extraMatches ?? self.extraMatches,
            position: position ?? self.position
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// EventPattern (Model/EventPattern.swift), as its encode(to:) writes it (073): `filters`
/// holds every filter as one string, a list joined by `|` so an older build reads it as a
/// value that never matches, and `anyOf` holds the lists whole. Read `anyOf` over `filters`.
// MARK: - WEventPattern
public struct WEventPattern: Codable {
    public let anyOf: [String: [String]]?
    public let filters: [String: String]
    public let name: String

    public init(anyOf: [String: [String]]?, filters: [String: String], name: String) {
        self.anyOf = anyOf
        self.filters = filters
        self.name = name
    }
}

// MARK: WEventPattern convenience initializers and mutators

public extension WEventPattern {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WEventPattern.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        anyOf: [String: [String]]?? = nil,
        filters: [String: String]? = nil,
        name: String? = nil
    ) -> WEventPattern {
        return WEventPattern(
            anyOf: anyOf ?? self.anyOf,
            filters: filters ?? self.filters,
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WaitServerEvent
public struct WaitServerEvent: Codable {
    public let servers: [String]
    public let trigger: WMCPEventTrigger

    public init(servers: [String], trigger: WMCPEventTrigger) {
        self.servers = servers
        self.trigger = trigger
    }
}

// MARK: WaitServerEvent convenience initializers and mutators

public extension WaitServerEvent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WaitServerEvent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        servers: [String]? = nil,
        trigger: WMCPEventTrigger? = nil
    ) -> WaitServerEvent {
        return WaitServerEvent(
            servers: servers ?? self.servers,
            trigger: trigger ?? self.trigger
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMCPEventTrigger
public struct WMCPEventTrigger: Codable {
    public let arguments: [String: JSONAny]
    public let event: String
    public let servers: [String]?

    public init(arguments: [String: JSONAny], event: String, servers: [String]?) {
        self.arguments = arguments
        self.event = event
        self.servers = servers
    }
}

// MARK: WMCPEventTrigger convenience initializers and mutators

public extension WMCPEventTrigger {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMCPEventTrigger.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        arguments: [String: JSONAny]? = nil,
        event: String? = nil,
        servers: [String]?? = nil
    ) -> WMCPEventTrigger {
        return WMCPEventTrigger(
            arguments: arguments ?? self.arguments,
            event: event ?? self.event,
            servers: servers ?? self.servers
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSessionLabel
public struct WSessionLabel: Codable {
    public let addedAt: Double
    public let owner: WSessionLabelOwner
    public let value: String

    public init(addedAt: Double, owner: WSessionLabelOwner, value: String) {
        self.addedAt = addedAt
        self.owner = owner
        self.value = value
    }
}

// MARK: WSessionLabel convenience initializers and mutators

public extension WSessionLabel {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSessionLabel.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        addedAt: Double? = nil,
        owner: WSessionLabelOwner? = nil,
        value: String? = nil
    ) -> WSessionLabel {
        return WSessionLabel(
            addedAt: addedAt ?? self.addedAt,
            owner: owner ?? self.owner,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WSessionLabelOwner: String, Codable {
    case agent = "agent"
    case person = "person"
}

// MARK: - WTurnUsage
public struct WTurnUsage: Codable {
    public let cachedReadTokens, cachedWriteTokens: Double?
    public let cost: WCost?
    public let inputTokens, outputTokens: Double
    public let thoughtTokens: Double?
    public let totalTokens: Double

    public init(cachedReadTokens: Double?, cachedWriteTokens: Double?, cost: WCost?, inputTokens: Double, outputTokens: Double, thoughtTokens: Double?, totalTokens: Double) {
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.cost = cost
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.totalTokens = totalTokens
    }
}

// MARK: WTurnUsage convenience initializers and mutators

public extension WTurnUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTurnUsage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        cachedReadTokens: Double?? = nil,
        cachedWriteTokens: Double?? = nil,
        cost: WCost?? = nil,
        inputTokens: Double? = nil,
        outputTokens: Double? = nil,
        thoughtTokens: Double?? = nil,
        totalTokens: Double? = nil
    ) -> WTurnUsage {
        return WTurnUsage(
            cachedReadTokens: cachedReadTokens ?? self.cachedReadTokens,
            cachedWriteTokens: cachedWriteTokens ?? self.cachedWriteTokens,
            cost: cost ?? self.cost,
            inputTokens: inputTokens ?? self.inputTokens,
            outputTokens: outputTokens ?? self.outputTokens,
            thoughtTokens: thoughtTokens ?? self.thoughtTokens,
            totalTokens: totalTokens ?? self.totalTokens
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMCPServer
public struct WMCPServer: Codable {
    public let name: String
    public let transport: WMCPServerTransport

    public init(name: String, transport: WMCPServerTransport) {
        self.name = name
        self.transport = transport
    }
}

// MARK: WMCPServer convenience initializers and mutators

public extension WMCPServer {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMCPServer.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        name: String? = nil,
        transport: WMCPServerTransport? = nil
    ) -> WMCPServer {
        return WMCPServer(
            name: name ?? self.name,
            transport: transport ?? self.transport
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMCPServerTransport
public struct WMCPServerTransport: Codable {
    public let stdio: WStdio?
    public let http: WHTTP?
    public let sse: WSSE?

    public init(stdio: WStdio?, http: WHTTP?, sse: WSSE?) {
        self.stdio = stdio
        self.http = http
        self.sse = sse
    }
}

// MARK: WMCPServerTransport convenience initializers and mutators

public extension WMCPServerTransport {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMCPServerTransport.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        stdio: WStdio?? = nil,
        http: WHTTP?? = nil,
        sse: WSSE?? = nil
    ) -> WMCPServerTransport {
        return WMCPServerTransport(
            stdio: stdio ?? self.stdio,
            http: http ?? self.http,
            sse: sse ?? self.sse
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WHTTP
public struct WHTTP: Codable {
    public let headers: [String: String]
    public let url: String

    public init(headers: [String: String], url: String) {
        self.headers = headers
        self.url = url
    }
}

// MARK: WHTTP convenience initializers and mutators

public extension WHTTP {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WHTTP.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        headers: [String: String]? = nil,
        url: String? = nil
    ) -> WHTTP {
        return WHTTP(
            headers: headers ?? self.headers,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSSE
public struct WSSE: Codable {
    public let headers: [String: String]
    public let url: String

    public init(headers: [String: String], url: String) {
        self.headers = headers
        self.url = url
    }
}

// MARK: WSSE convenience initializers and mutators

public extension WSSE {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSSE.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        headers: [String: String]? = nil,
        url: String? = nil
    ) -> WSSE {
        return WSSE(
            headers: headers ?? self.headers,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WStdio
public struct WStdio: Codable {
    public let args: [String]
    public let command: String
    public let env: [String: String]

    public init(args: [String], command: String, env: [String: String]) {
        self.args = args
        self.command = command
        self.env = env
    }
}

// MARK: WStdio convenience initializers and mutators

public extension WStdio {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStdio.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        args: [String]? = nil,
        command: String? = nil,
        env: [String: String]? = nil
    ) -> WStdio {
        return WStdio(
            args: args ?? self.args,
            command: command ?? self.command,
            env: env ?? self.env
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMissingFolder
public struct WMissingFolder: Codable {
    public let branchKept: Bool

    public init(branchKept: Bool) {
        self.branchKept = branchKept
    }
}

// MARK: WMissingFolder convenience initializers and mutators

public extension WMissingFolder {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMissingFolder.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        branchKept: Bool? = nil
    ) -> WMissingFolder {
        return WMissingFolder(
            branchKept: branchKept ?? self.branchKept
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPendingMove
public struct WPendingMove: Codable {
    public let askedAt: Double
    public let askedBy: WSessionLabelOwner
    public let discardChanges, removeLeft: Bool
    public let target: WMoveTarget

    public init(askedAt: Double, askedBy: WSessionLabelOwner, discardChanges: Bool, removeLeft: Bool, target: WMoveTarget) {
        self.askedAt = askedAt
        self.askedBy = askedBy
        self.discardChanges = discardChanges
        self.removeLeft = removeLeft
        self.target = target
    }
}

// MARK: WPendingMove convenience initializers and mutators

public extension WPendingMove {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPendingMove.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        askedAt: Double? = nil,
        askedBy: WSessionLabelOwner? = nil,
        discardChanges: Bool? = nil,
        removeLeft: Bool? = nil,
        target: WMoveTarget? = nil
    ) -> WPendingMove {
        return WPendingMove(
            askedAt: askedAt ?? self.askedAt,
            askedBy: askedBy ?? self.askedBy,
            discardChanges: discardChanges ?? self.discardChanges,
            removeLeft: removeLeft ?? self.removeLeft,
            target: target ?? self.target
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMoveTarget
public struct WMoveTarget: Codable {
    public let newWorktree: WNewWorktree?
    public let existing: WMoveTargetExisting?
    public let projectFolder: [String: JSONAny]?

    public init(newWorktree: WNewWorktree?, existing: WMoveTargetExisting?, projectFolder: [String: JSONAny]?) {
        self.newWorktree = newWorktree
        self.existing = existing
        self.projectFolder = projectFolder
    }
}

// MARK: WMoveTarget convenience initializers and mutators

public extension WMoveTarget {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMoveTarget.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        newWorktree: WNewWorktree?? = nil,
        existing: WMoveTargetExisting?? = nil,
        projectFolder: [String: JSONAny]?? = nil
    ) -> WMoveTarget {
        return WMoveTarget(
            newWorktree: newWorktree ?? self.newWorktree,
            existing: existing ?? self.existing,
            projectFolder: projectFolder ?? self.projectFolder
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMoveTargetExisting
public struct WMoveTargetExisting: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WMoveTargetExisting convenience initializers and mutators

public extension WMoveTargetExisting {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMoveTargetExisting.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WMoveTargetExisting {
        return WMoveTargetExisting(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNewWorktree
public struct WNewWorktree: Codable {
    public let name: String?

    public init(name: String?) {
        self.name = name
    }
}

// MARK: WNewWorktree convenience initializers and mutators

public extension WNewWorktree {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNewWorktree.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        name: String?? = nil
    ) -> WNewWorktree {
        return WNewWorktree(
            name: name ?? self.name
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSandboxFailureRecord
public struct WSandboxFailureRecord: Codable {
    public let completedToolCalls: Double
    public let detail: String
    public let hang, recoveryOffered: Bool
    public let runtimeID: String

    public init(completedToolCalls: Double, detail: String, hang: Bool, recoveryOffered: Bool, runtimeID: String) {
        self.completedToolCalls = completedToolCalls
        self.detail = detail
        self.hang = hang
        self.recoveryOffered = recoveryOffered
        self.runtimeID = runtimeID
    }
}

// MARK: WSandboxFailureRecord convenience initializers and mutators

public extension WSandboxFailureRecord {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSandboxFailureRecord.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        completedToolCalls: Double? = nil,
        detail: String? = nil,
        hang: Bool? = nil,
        recoveryOffered: Bool? = nil,
        runtimeID: String? = nil
    ) -> WSandboxFailureRecord {
        return WSandboxFailureRecord(
            completedToolCalls: completedToolCalls ?? self.completedToolCalls,
            detail: detail ?? self.detail,
            hang: hang ?? self.hang,
            recoveryOffered: recoveryOffered ?? self.recoveryOffered,
            runtimeID: runtimeID ?? self.runtimeID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPlan
public struct WPlan: Codable {
    public let at: Double
    public let entries: [WPlanEntry]
    public let planID: String?
    public let state: WPlanState

    public init(at: Double, entries: [WPlanEntry], planID: String?, state: WPlanState) {
        self.at = at
        self.entries = entries
        self.planID = planID
        self.state = state
    }
}

// MARK: WPlan convenience initializers and mutators

public extension WPlan {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPlan.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil,
        entries: [WPlanEntry]? = nil,
        planID: String?? = nil,
        state: WPlanState? = nil
    ) -> WPlan {
        return WPlan(
            at: at ?? self.at,
            entries: entries ?? self.entries,
            planID: planID ?? self.planID,
            state: state ?? self.state
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPlanEntry
public struct WPlanEntry: Codable {
    public let content: String
    public let priority: WPlanEntryPriority
    public let status: WPlanEntryStatus

    public init(content: String, priority: WPlanEntryPriority, status: WPlanEntryStatus) {
        self.content = content
        self.priority = priority
        self.status = status
    }
}

// MARK: WPlanEntry convenience initializers and mutators

public extension WPlanEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPlanEntry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        content: String? = nil,
        priority: WPlanEntryPriority? = nil,
        status: WPlanEntryStatus? = nil
    ) -> WPlanEntry {
        return WPlanEntry(
            content: content ?? self.content,
            priority: priority ?? self.priority,
            status: status ?? self.status
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WPlanEntryPriority: String, Codable {
    case high = "high"
    case low = "low"
    case medium = "medium"
}

public enum WPlanEntryStatus: String, Codable {
    case completed = "completed"
    case inProgress = "in_progress"
    case pending = "pending"
}

public enum WPlanState: String, Codable {
    case current = "current"
    case withdrawn = "withdrawn"
}

// MARK: - WAgentPurpose
public struct WAgentPurpose: Codable {
    public let providerDraft: WProviderDraft

    public init(providerDraft: WProviderDraft) {
        self.providerDraft = providerDraft
    }
}

// MARK: WAgentPurpose convenience initializers and mutators

public extension WAgentPurpose {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAgentPurpose.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        providerDraft: WProviderDraft? = nil
    ) -> WAgentPurpose {
        return WAgentPurpose(
            providerDraft: providerDraft ?? self.providerDraft
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WProviderDraft
public struct WProviderDraft: Codable {
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: WProviderDraft convenience initializers and mutators

public extension WProviderDraft {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WProviderDraft.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: String? = nil
    ) -> WProviderDraft {
        return WProviderDraft(
            id: id ?? self.id
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WQueuedPrompt
public struct WQueuedPrompt: Codable {
    public let attachments: [WAttachment]
    public let from: WPromptOrigin
    public let hops: Double?
    public let id: String
    public let preface: String?
    public let queuedAt: Double
    public let sender: WMessageSender?
    public let text: String

    public init(attachments: [WAttachment], from: WPromptOrigin, hops: Double?, id: String, preface: String?, queuedAt: Double, sender: WMessageSender?, text: String) {
        self.attachments = attachments
        self.from = from
        self.hops = hops
        self.id = id
        self.preface = preface
        self.queuedAt = queuedAt
        self.sender = sender
        self.text = text
    }
}

// MARK: WQueuedPrompt convenience initializers and mutators

public extension WQueuedPrompt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WQueuedPrompt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        attachments: [WAttachment]? = nil,
        from: WPromptOrigin? = nil,
        hops: Double?? = nil,
        id: String? = nil,
        preface: String?? = nil,
        queuedAt: Double? = nil,
        sender: WMessageSender?? = nil,
        text: String? = nil
    ) -> WQueuedPrompt {
        return WQueuedPrompt(
            attachments: attachments ?? self.attachments,
            from: from ?? self.from,
            hops: hops ?? self.hops,
            id: id ?? self.id,
            preface: preface ?? self.preface,
            queuedAt: queuedAt ?? self.queuedAt,
            sender: sender ?? self.sender,
            text: text ?? self.text
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAttachment
public struct WAttachment: Codable {
    public let block: WContentBlock
    public let byteCount: Double?
    public let displayName: String
    public let id: String

    public init(block: WContentBlock, byteCount: Double?, displayName: String, id: String) {
        self.block = block
        self.byteCount = byteCount
        self.displayName = displayName
        self.id = id
    }
}

// MARK: WAttachment convenience initializers and mutators

public extension WAttachment {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAttachment.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        block: WContentBlock? = nil,
        byteCount: Double?? = nil,
        displayName: String? = nil,
        id: String? = nil
    ) -> WAttachment {
        return WAttachment(
            block: block ?? self.block,
            byteCount: byteCount ?? self.byteCount,
            displayName: displayName ?? self.displayName,
            id: id ?? self.id
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// ContentBlock (ACP/ContentBlock.swift): the protocol's own block shapes, as sent. A block
/// of a kind this build doesn't know is written back as it came, so any other `type` may
/// arrive.
// MARK: - WContentBlock
public struct WContentBlock: Codable {
    public let text: String?
    public let type: WContentBlockType
    public let data, mimeType, uri: String?
    public let annotations: WContentBlockAnnotations?
    public let name: String?
    public let size: Double?
    public let resource: WResource?

    public init(text: String?, type: WContentBlockType, data: String?, mimeType: String?, uri: String?, annotations: WContentBlockAnnotations?, name: String?, size: Double?, resource: WResource?) {
        self.text = text
        self.type = type
        self.data = data
        self.mimeType = mimeType
        self.uri = uri
        self.annotations = annotations
        self.name = name
        self.size = size
        self.resource = resource
    }
}

// MARK: WContentBlock convenience initializers and mutators

public extension WContentBlock {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WContentBlock.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        text: String?? = nil,
        type: WContentBlockType? = nil,
        data: String?? = nil,
        mimeType: String?? = nil,
        uri: String?? = nil,
        annotations: WContentBlockAnnotations?? = nil,
        name: String?? = nil,
        size: Double?? = nil,
        resource: WResource?? = nil
    ) -> WContentBlock {
        return WContentBlock(
            text: text ?? self.text,
            type: type ?? self.type,
            data: data ?? self.data,
            mimeType: mimeType ?? self.mimeType,
            uri: uri ?? self.uri,
            annotations: annotations ?? self.annotations,
            name: name ?? self.name,
            size: size ?? self.size,
            resource: resource ?? self.resource
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WContentBlockAnnotations
public struct WContentBlockAnnotations: Codable {
    public let audience: [String]?
    public let priority: Double?

    public init(audience: [String]?, priority: Double?) {
        self.audience = audience
        self.priority = priority
    }
}

// MARK: WContentBlockAnnotations convenience initializers and mutators

public extension WContentBlockAnnotations {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WContentBlockAnnotations.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        audience: [String]?? = nil,
        priority: Double?? = nil
    ) -> WContentBlockAnnotations {
        return WContentBlockAnnotations(
            audience: audience ?? self.audience,
            priority: priority ?? self.priority
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WResource
public struct WResource: Codable {
    public let blob, mimeType, text: String?
    public let uri: String

    public init(blob: String?, mimeType: String?, text: String?, uri: String) {
        self.blob = blob
        self.mimeType = mimeType
        self.text = text
        self.uri = uri
    }
}

// MARK: WResource convenience initializers and mutators

public extension WResource {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WResource.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        blob: String?? = nil,
        mimeType: String?? = nil,
        text: String?? = nil,
        uri: String? = nil
    ) -> WResource {
        return WResource(
            blob: blob ?? self.blob,
            mimeType: mimeType ?? self.mimeType,
            text: text ?? self.text,
            uri: uri ?? self.uri
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WContentBlockType: String, Codable {
    case audio = "audio"
    case image = "image"
    case resource = "resource"
    case resourceLink = "resource_link"
    case text = "text"
}

public enum WPromptOrigin: String, Codable {
    case agent = "agent"
    case app = "app"
    case person = "person"
}

// MARK: - WMessageSender
public struct WMessageSender: Codable {
    public let agentID: String
    public let title: String

    public init(agentID: String, title: String) {
        self.agentID = agentID
        self.title = title
    }
}

// MARK: WMessageSender convenience initializers and mutators

public extension WMessageSender {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMessageSender.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        title: String? = nil
    ) -> WMessageSender {
        return WMessageSender(
            agentID: agentID ?? self.agentID,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WQueuedStart
public struct WQueuedStart: Codable {
    public let labels: [String]
    public let model, permissionMode, runtimeID: String?
    public let worktree: WorktreeChoice?

    public init(labels: [String], model: String?, permissionMode: String?, runtimeID: String?, worktree: WorktreeChoice?) {
        self.labels = labels
        self.model = model
        self.permissionMode = permissionMode
        self.runtimeID = runtimeID
        self.worktree = worktree
    }
}

// MARK: WQueuedStart convenience initializers and mutators

public extension WQueuedStart {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WQueuedStart.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        labels: [String]? = nil,
        model: String?? = nil,
        permissionMode: String?? = nil,
        runtimeID: String?? = nil,
        worktree: WorktreeChoice?? = nil
    ) -> WQueuedStart {
        return WQueuedStart(
            labels: labels ?? self.labels,
            model: model ?? self.model,
            permissionMode: permissionMode ?? self.permissionMode,
            runtimeID: runtimeID ?? self.runtimeID,
            worktree: worktree ?? self.worktree
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WorktreeChoice
public struct WorktreeChoice: Codable {
    public let new: [String: JSONAny]?
    public let existing: WorktreeChoiceExisting?
    public let named: WNamed?
    public let branch: WBranch?

    public init(new: [String: JSONAny]?, existing: WorktreeChoiceExisting?, named: WNamed?, branch: WBranch?) {
        self.new = new
        self.existing = existing
        self.named = named
        self.branch = branch
    }
}

// MARK: WorktreeChoice convenience initializers and mutators

public extension WorktreeChoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorktreeChoice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        new: [String: JSONAny]?? = nil,
        existing: WorktreeChoiceExisting?? = nil,
        named: WNamed?? = nil,
        branch: WBranch?? = nil
    ) -> WorktreeChoice {
        return WorktreeChoice(
            new: new ?? self.new,
            existing: existing ?? self.existing,
            named: named ?? self.named,
            branch: branch ?? self.branch
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WBranch
public struct WBranch: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WBranch convenience initializers and mutators

public extension WBranch {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WBranch.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WBranch {
        return WBranch(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WorktreeChoiceExisting
public struct WorktreeChoiceExisting: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WorktreeChoiceExisting convenience initializers and mutators

public extension WorktreeChoiceExisting {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorktreeChoiceExisting.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WorktreeChoiceExisting {
        return WorktreeChoiceExisting(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNamed
public struct WNamed: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WNamed convenience initializers and mutators

public extension WNamed {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNamed.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WNamed {
        return WNamed(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WorkReport
public struct WorkReport: Codable {
    public let at: Double
    public let block: WBlock?
    public let message: String
    public let outcome: WorkOutcome

    public init(at: Double, block: WBlock?, message: String, outcome: WorkOutcome) {
        self.at = at
        self.block = block
        self.message = message
        self.outcome = outcome
    }
}

// MARK: WorkReport convenience initializers and mutators

public extension WorkReport {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkReport.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil,
        block: WBlock?? = nil,
        message: String? = nil,
        outcome: WorkOutcome? = nil
    ) -> WorkReport {
        return WorkReport(
            at: at ?? self.at,
            block: block ?? self.block,
            message: message ?? self.message,
            outcome: outcome ?? self.outcome
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WBlock
public struct WBlock: Codable {
    public let checkAgainAt, clearedAt: Double?
    public let clearedBy: WBlockClearing?
    public let waits: [Wait]
    public let wakeOn: WBlockWakeOn?

    public init(checkAgainAt: Double?, clearedAt: Double?, clearedBy: WBlockClearing?, waits: [Wait], wakeOn: WBlockWakeOn?) {
        self.checkAgainAt = checkAgainAt
        self.clearedAt = clearedAt
        self.clearedBy = clearedBy
        self.waits = waits
        self.wakeOn = wakeOn
    }
}

// MARK: WBlock convenience initializers and mutators

public extension WBlock {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WBlock.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        checkAgainAt: Double?? = nil,
        clearedAt: Double?? = nil,
        clearedBy: WBlockClearing?? = nil,
        waits: [Wait]? = nil,
        wakeOn: WBlockWakeOn?? = nil
    ) -> WBlock {
        return WBlock(
            checkAgainAt: checkAgainAt ?? self.checkAgainAt,
            clearedAt: clearedAt ?? self.clearedAt,
            clearedBy: clearedBy ?? self.clearedBy,
            waits: waits ?? self.waits,
            wakeOn: wakeOn ?? self.wakeOn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WBlockClearing: String, Codable {
    case dropped = "dropped"
    case time = "time"
    case waits = "waits"
}

// MARK: - Wait
public struct Wait: Codable {
    public let agentID: String
    public let ending: WaitEnding?
    public let nameAtReport: String

    public init(agentID: String, ending: WaitEnding?, nameAtReport: String) {
        self.agentID = agentID
        self.ending = ending
        self.nameAtReport = nameAtReport
    }
}

// MARK: Wait convenience initializers and mutators

public extension Wait {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(Wait.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        ending: WaitEnding?? = nil,
        nameAtReport: String? = nil
    ) -> Wait {
        return Wait(
            agentID: agentID ?? self.agentID,
            ending: ending ?? self.ending,
            nameAtReport: nameAtReport ?? self.nameAtReport
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WaitEnding
public struct WaitEnding: Codable {
    public let at: Double
    public let how: WaitEndingHow

    public init(at: Double, how: WaitEndingHow) {
        self.at = at
        self.how = how
    }
}

// MARK: WaitEnding convenience initializers and mutators

public extension WaitEnding {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WaitEnding.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil,
        how: WaitEndingHow? = nil
    ) -> WaitEnding {
        return WaitEnding(
            at: at ?? self.at,
            how: how ?? self.how
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WaitEndingHow
public struct WaitEndingHow: Codable {
    public let finished: WFinished?
    public let stopped: WStopped?
    public let archived, gone: [String: JSONAny]?

    public init(finished: WFinished?, stopped: WStopped?, archived: [String: JSONAny]?, gone: [String: JSONAny]?) {
        self.finished = finished
        self.stopped = stopped
        self.archived = archived
        self.gone = gone
    }
}

// MARK: WaitEndingHow convenience initializers and mutators

public extension WaitEndingHow {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WaitEndingHow.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        finished: WFinished?? = nil,
        stopped: WStopped?? = nil,
        archived: [String: JSONAny]?? = nil,
        gone: [String: JSONAny]?? = nil
    ) -> WaitEndingHow {
        return WaitEndingHow(
            finished: finished ?? self.finished,
            stopped: stopped ?? self.stopped,
            archived: archived ?? self.archived,
            gone: gone ?? self.gone
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WFinished
public struct WFinished: Codable {
    public let message: String?
    public let outcome: WorkOutcome?

    public init(message: String?, outcome: WorkOutcome?) {
        self.message = message
        self.outcome = outcome
    }
}

// MARK: WFinished convenience initializers and mutators

public extension WFinished {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WFinished.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        message: String?? = nil,
        outcome: WorkOutcome?? = nil
    ) -> WFinished {
        return WFinished(
            message: message ?? self.message,
            outcome: outcome ?? self.outcome
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WorkOutcome: String, Codable {
    case blocked = "blocked"
    case done = "done"
    case needsAnswer = "needs_answer"
    case nothingToDo = "nothing_to_do"
    case partlyDone = "partly_done"
    case stuck = "stuck"
}

// MARK: - WStopped
public struct WStopped: Codable {
    public let the0: WEndedReason?

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WEndedReason?) {
        self.the0 = the0
    }
}

// MARK: WStopped convenience initializers and mutators

public extension WStopped {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStopped.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WEndedReason?? = nil
    ) -> WStopped {
        return WStopped(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WBlockWakeOn: String, Codable {
    case all = "all"
    case any = "any"
}

// MARK: - WStartOptions
public struct WStartOptions: Codable {
    public let extraArguments: [String]
    public let values: [String: JSONAny]

    public init(extraArguments: [String], values: [String: JSONAny]) {
        self.extraArguments = extraArguments
        self.values = values
    }
}

// MARK: WStartOptions convenience initializers and mutators

public extension WStartOptions {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStartOptions.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        extraArguments: [String]? = nil,
        values: [String: JSONAny]? = nil
    ) -> WStartOptions {
        return WStartOptions(
            extraArguments: extraArguments ?? self.extraArguments,
            values: values ?? self.values
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WStartingPoint
public struct WStartingPoint: Codable {
    public let commit, repository: String

    public init(commit: String, repository: String) {
        self.commit = commit
        self.repository = repository
    }
}

// MARK: WStartingPoint convenience initializers and mutators

public extension WStartingPoint {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStartingPoint.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        commit: String? = nil,
        repository: String? = nil
    ) -> WStartingPoint {
        return WStartingPoint(
            commit: commit ?? self.commit,
            repository: repository ?? self.repository
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WAgentState: String, Codable {
    case archived = "archived"
    case finished = "finished"
    case queued = "queued"
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
    case waitingOnUser = "waitingOnUser"
}

// MARK: - WSuggestedPrompt
public struct WSuggestedPrompt: Codable {
    public let id: String
    public let label, prompt: String

    public init(id: String, label: String, prompt: String) {
        self.id = id
        self.label = label
        self.prompt = prompt
    }
}

// MARK: WSuggestedPrompt convenience initializers and mutators

public extension WSuggestedPrompt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSuggestedPrompt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: String? = nil,
        label: String? = nil,
        prompt: String? = nil
    ) -> WSuggestedPrompt {
        return WSuggestedPrompt(
            id: id ?? self.id,
            label: label ?? self.label,
            prompt: prompt ?? self.prompt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WUsage
public struct WUsage: Codable {
    public let at: Double
    public let cost: WCost?
    public let size, used: Double

    public init(at: Double, cost: WCost?, size: Double, used: Double) {
        self.at = at
        self.cost = cost
        self.size = size
        self.used = used
    }
}

// MARK: WUsage convenience initializers and mutators

public extension WUsage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WUsage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil,
        cost: WCost?? = nil,
        size: Double? = nil,
        used: Double? = nil
    ) -> WUsage {
        return WUsage(
            at: at ?? self.at,
            cost: cost ?? self.cost,
            size: size ?? self.size,
            used: used ?? self.used
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAgentWorktree
public struct WAgentWorktree: Codable {
    public let base, branch: String?
    public let madeByApp: Bool
    public let name, project, root: String

    public init(base: String?, branch: String?, madeByApp: Bool, name: String, project: String, root: String) {
        self.base = base
        self.branch = branch
        self.madeByApp = madeByApp
        self.name = name
        self.project = project
        self.root = root
    }
}

// MARK: WAgentWorktree convenience initializers and mutators

public extension WAgentWorktree {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAgentWorktree.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        base: String?? = nil,
        branch: String?? = nil,
        madeByApp: Bool? = nil,
        name: String? = nil,
        project: String? = nil,
        root: String? = nil
    ) -> WAgentWorktree {
        return WAgentWorktree(
            base: base ?? self.base,
            branch: branch ?? self.branch,
            madeByApp: madeByApp ?? self.madeByApp,
            name: name ?? self.name,
            project: project ?? self.project,
            root: root ?? self.root
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WListRequest
public struct WListRequest: Codable {
    public let after: WListCursor?
    public let agentID: String?
    public let archivedCommands, archivedOnly: Bool
    public let folder: String?
    public let includeArchived, lean: Bool
    public let limit: Double?
    public let query, startedByWorkflow: String?

    public init(after: WListCursor?, agentID: String?, archivedCommands: Bool, archivedOnly: Bool, folder: String?, includeArchived: Bool, lean: Bool, limit: Double?, query: String?, startedByWorkflow: String?) {
        self.after = after
        self.agentID = agentID
        self.archivedCommands = archivedCommands
        self.archivedOnly = archivedOnly
        self.folder = folder
        self.includeArchived = includeArchived
        self.lean = lean
        self.limit = limit
        self.query = query
        self.startedByWorkflow = startedByWorkflow
    }
}

// MARK: WListRequest convenience initializers and mutators

public extension WListRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WListRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        after: WListCursor?? = nil,
        agentID: String?? = nil,
        archivedCommands: Bool? = nil,
        archivedOnly: Bool? = nil,
        folder: String?? = nil,
        includeArchived: Bool? = nil,
        lean: Bool? = nil,
        limit: Double?? = nil,
        query: String?? = nil,
        startedByWorkflow: String?? = nil
    ) -> WListRequest {
        return WListRequest(
            after: after ?? self.after,
            agentID: agentID ?? self.agentID,
            archivedCommands: archivedCommands ?? self.archivedCommands,
            archivedOnly: archivedOnly ?? self.archivedOnly,
            folder: folder ?? self.folder,
            includeArchived: includeArchived ?? self.includeArchived,
            lean: lean ?? self.lean,
            limit: limit ?? self.limit,
            query: query ?? self.query,
            startedByWorkflow: startedByWorkflow ?? self.startedByWorkflow
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WListCursor
public struct WListCursor: Codable {
    public let id: String
    public let lastActivityAt: Double

    public init(id: String, lastActivityAt: Double) {
        self.id = id
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: WListCursor convenience initializers and mutators

public extension WListCursor {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WListCursor.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: String? = nil,
        lastActivityAt: Double? = nil
    ) -> WListCursor {
        return WListCursor(
            id: id ?? self.id,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WOptionsResponse
public struct WOptionsResponse: Codable {
    public let commands: [WSlashCommand]
    public let draftID: String
    public let options: [WConfigOption]

    public init(commands: [WSlashCommand], draftID: String, options: [WConfigOption]) {
        self.commands = commands
        self.draftID = draftID
        self.options = options
    }
}

// MARK: WOptionsResponse convenience initializers and mutators

public extension WOptionsResponse {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WOptionsResponse.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        commands: [WSlashCommand]? = nil,
        draftID: String? = nil,
        options: [WConfigOption]? = nil
    ) -> WOptionsResponse {
        return WOptionsResponse(
            commands: commands ?? self.commands,
            draftID: draftID ?? self.draftID,
            options: options ?? self.options
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPermissionRequest
public struct WPermissionRequest: Codable {
    public let agentID: String
    public let askedAt: Double
    public let id: String
    public let options: [WPermissionOption]
    public let subagent: String?
    public let toolCall: WToolCall

    public init(agentID: String, askedAt: Double, id: String, options: [WPermissionOption], subagent: String?, toolCall: WToolCall) {
        self.agentID = agentID
        self.askedAt = askedAt
        self.id = id
        self.options = options
        self.subagent = subagent
        self.toolCall = toolCall
    }
}

// MARK: WPermissionRequest convenience initializers and mutators

public extension WPermissionRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPermissionRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        askedAt: Double? = nil,
        id: String? = nil,
        options: [WPermissionOption]? = nil,
        subagent: String?? = nil,
        toolCall: WToolCall? = nil
    ) -> WPermissionRequest {
        return WPermissionRequest(
            agentID: agentID ?? self.agentID,
            askedAt: askedAt ?? self.askedAt,
            id: id ?? self.id,
            options: options ?? self.options,
            subagent: subagent ?? self.subagent,
            toolCall: toolCall ?? self.toolCall
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPermissionOption
public struct WPermissionOption: Codable {
    public let kind: WPermissionOptionKind
    public let name, optionID: String

    public init(kind: WPermissionOptionKind, name: String, optionID: String) {
        self.kind = kind
        self.name = name
        self.optionID = optionID
    }
}

// MARK: WPermissionOption convenience initializers and mutators

public extension WPermissionOption {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPermissionOption.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        kind: WPermissionOptionKind? = nil,
        name: String? = nil,
        optionID: String? = nil
    ) -> WPermissionOption {
        return WPermissionOption(
            kind: kind ?? self.kind,
            name: name ?? self.name,
            optionID: optionID ?? self.optionID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WPermissionOptionKind: String, Codable {
    case allowAlways = "allow_always"
    case allowOnce = "allow_once"
    case rejectAlways = "reject_always"
    case rejectOnce = "reject_once"
    case unknown = "unknown"
}

// MARK: - WToolCall
public struct WToolCall: Codable {
    public let content: [WToolCallContent]
    public let kind: String?
    public let locations: [WToolCallLocation]
    public let name: String?
    public let raw, rawInput, rawOutput: JSONAny?
    public let status: String?
    public let title: String
    public let toolCallID: String?

    public init(content: [WToolCallContent], kind: String?, locations: [WToolCallLocation], name: String?, raw: JSONAny?, rawInput: JSONAny?, rawOutput: JSONAny?, status: String?, title: String, toolCallID: String?) {
        self.content = content
        self.kind = kind
        self.locations = locations
        self.name = name
        self.raw = raw
        self.rawInput = rawInput
        self.rawOutput = rawOutput
        self.status = status
        self.title = title
        self.toolCallID = toolCallID
    }
}

// MARK: WToolCall convenience initializers and mutators

public extension WToolCall {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WToolCall.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        content: [WToolCallContent]? = nil,
        kind: String?? = nil,
        locations: [WToolCallLocation]? = nil,
        name: String?? = nil,
        raw: JSONAny?? = nil,
        rawInput: JSONAny?? = nil,
        rawOutput: JSONAny?? = nil,
        status: String?? = nil,
        title: String? = nil,
        toolCallID: String?? = nil
    ) -> WToolCall {
        return WToolCall(
            content: content ?? self.content,
            kind: kind ?? self.kind,
            locations: locations ?? self.locations,
            name: name ?? self.name,
            raw: raw ?? self.raw,
            rawInput: rawInput ?? self.rawInput,
            rawOutput: rawOutput ?? self.rawOutput,
            status: status ?? self.status,
            title: title ?? self.title,
            toolCallID: toolCallID ?? self.toolCallID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

/// ToolCallContent (ACP/ToolCallContent.swift): the protocol's shapes, as sent. Anything
/// else is written back as it came, so another `type` may arrive.
// MARK: - WToolCallContent
public struct WToolCallContent: Codable {
    public let content: WContentBlock?
    public let type: WToolCallContentType
    public let newText, oldText, path, terminalId: String?

    public init(content: WContentBlock?, type: WToolCallContentType, newText: String?, oldText: String?, path: String?, terminalId: String?) {
        self.content = content
        self.type = type
        self.newText = newText
        self.oldText = oldText
        self.path = path
        self.terminalId = terminalId
    }
}

// MARK: WToolCallContent convenience initializers and mutators

public extension WToolCallContent {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WToolCallContent.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        content: WContentBlock?? = nil,
        type: WToolCallContentType? = nil,
        newText: String?? = nil,
        oldText: String?? = nil,
        path: String?? = nil,
        terminalId: String?? = nil
    ) -> WToolCallContent {
        return WToolCallContent(
            content: content ?? self.content,
            type: type ?? self.type,
            newText: newText ?? self.newText,
            oldText: oldText ?? self.oldText,
            path: path ?? self.path,
            terminalId: terminalId ?? self.terminalId
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WToolCallContentType: String, Codable {
    case content = "content"
    case diff = "diff"
    case terminal = "terminal"
}

// MARK: - WToolCallLocation
public struct WToolCallLocation: Codable {
    public let line: Double?
    public let path: String

    public init(line: Double?, path: String) {
        self.line = line
        self.path = path
    }
}

// MARK: WToolCallLocation convenience initializers and mutators

public extension WToolCallLocation {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WToolCallLocation.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        line: Double?? = nil,
        path: String? = nil
    ) -> WToolCallLocation {
        return WToolCallLocation(
            line: line ?? self.line,
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WProjectSummary
public struct WProjectSummary: Codable {
    public let approvals: [WApproval]?
    public let costToDate: [String: Double]
    public let counts: WCounts
    public let exists: Bool
    public let guardedChanges: [WGuardedChange]?
    public let isChat: Bool?
    public let lastActivityAt: Double
    public let name: String
    public let project: WProject
    public let retiredCount, unmeasuredAgents: Double

    public init(approvals: [WApproval]?, costToDate: [String: Double], counts: WCounts, exists: Bool, guardedChanges: [WGuardedChange]?, isChat: Bool?, lastActivityAt: Double, name: String, project: WProject, retiredCount: Double, unmeasuredAgents: Double) {
        self.approvals = approvals
        self.costToDate = costToDate
        self.counts = counts
        self.exists = exists
        self.guardedChanges = guardedChanges
        self.isChat = isChat
        self.lastActivityAt = lastActivityAt
        self.name = name
        self.project = project
        self.retiredCount = retiredCount
        self.unmeasuredAgents = unmeasuredAgents
    }
}

// MARK: WProjectSummary convenience initializers and mutators

public extension WProjectSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WProjectSummary.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        approvals: [WApproval]?? = nil,
        costToDate: [String: Double]? = nil,
        counts: WCounts? = nil,
        exists: Bool? = nil,
        guardedChanges: [WGuardedChange]?? = nil,
        isChat: Bool?? = nil,
        lastActivityAt: Double? = nil,
        name: String? = nil,
        project: WProject? = nil,
        retiredCount: Double? = nil,
        unmeasuredAgents: Double? = nil
    ) -> WProjectSummary {
        return WProjectSummary(
            approvals: approvals ?? self.approvals,
            costToDate: costToDate ?? self.costToDate,
            counts: counts ?? self.counts,
            exists: exists ?? self.exists,
            guardedChanges: guardedChanges ?? self.guardedChanges,
            isChat: isChat ?? self.isChat,
            lastActivityAt: lastActivityAt ?? self.lastActivityAt,
            name: name ?? self.name,
            project: project ?? self.project,
            retiredCount: retiredCount ?? self.retiredCount,
            unmeasuredAgents: unmeasuredAgents ?? self.unmeasuredAgents
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WApproval
public struct WApproval: Codable {
    public let actions: [WApprovalAction]
    public let agentID: String?
    public let digest: String?
    public let key: String
    public let kind: WApprovalKind
    public let line: String
    public let since: Double?
    public let title: String

    public init(actions: [WApprovalAction], agentID: String?, digest: String?, key: String, kind: WApprovalKind, line: String, since: Double?, title: String) {
        self.actions = actions
        self.agentID = agentID
        self.digest = digest
        self.key = key
        self.kind = kind
        self.line = line
        self.since = since
        self.title = title
    }
}

// MARK: WApproval convenience initializers and mutators

public extension WApproval {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WApproval.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        actions: [WApprovalAction]? = nil,
        agentID: String?? = nil,
        digest: String?? = nil,
        key: String? = nil,
        kind: WApprovalKind? = nil,
        line: String? = nil,
        since: Double?? = nil,
        title: String? = nil
    ) -> WApproval {
        return WApproval(
            actions: actions ?? self.actions,
            agentID: agentID ?? self.agentID,
            digest: digest ?? self.digest,
            key: key ?? self.key,
            kind: kind ?? self.kind,
            line: line ?? self.line,
            since: since ?? self.since,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WApprovalAction: String, Codable {
    case approve = "approve"
    case deny = "deny"
    case dismiss = "dismiss"
    case requestChanges = "requestChanges"
}

public enum WApprovalKind: String, Codable {
    case archive = "archive"
    case file = "file"
    case mcpServer = "mcpServer"
    case plugin = "plugin"
    case workflow = "workflow"
    case workflowFailed = "workflowFailed"
}

// MARK: - WCounts
public struct WCounts: Codable {
    public let archived, blocked, finished, needsAttention: Double?
    public let running, stopped, waiting: Double?

    public init(archived: Double?, blocked: Double?, finished: Double?, needsAttention: Double?, running: Double?, stopped: Double?, waiting: Double?) {
        self.archived = archived
        self.blocked = blocked
        self.finished = finished
        self.needsAttention = needsAttention
        self.running = running
        self.stopped = stopped
        self.waiting = waiting
    }
}

// MARK: WCounts convenience initializers and mutators

public extension WCounts {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCounts.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        archived: Double?? = nil,
        blocked: Double?? = nil,
        finished: Double?? = nil,
        needsAttention: Double?? = nil,
        running: Double?? = nil,
        stopped: Double?? = nil,
        waiting: Double?? = nil
    ) -> WCounts {
        return WCounts(
            archived: archived ?? self.archived,
            blocked: blocked ?? self.blocked,
            finished: finished ?? self.finished,
            needsAttention: needsAttention ?? self.needsAttention,
            running: running ?? self.running,
            stopped: stopped ?? self.stopped,
            waiting: waiting ?? self.waiting
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WGuardedChange
public struct WGuardedChange: Codable {
    public let askedIn: String?
    public let byGit: Bool
    public let changedBy: [String]
    public let changedByIDs: [String]
    public let digest: String?
    public let path: String
    public let since: Double

    public init(askedIn: String?, byGit: Bool, changedBy: [String], changedByIDs: [String], digest: String?, path: String, since: Double) {
        self.askedIn = askedIn
        self.byGit = byGit
        self.changedBy = changedBy
        self.changedByIDs = changedByIDs
        self.digest = digest
        self.path = path
        self.since = since
    }
}

// MARK: WGuardedChange convenience initializers and mutators

public extension WGuardedChange {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WGuardedChange.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        askedIn: String?? = nil,
        byGit: Bool? = nil,
        changedBy: [String]? = nil,
        changedByIDs: [String]? = nil,
        digest: String?? = nil,
        path: String? = nil,
        since: Double? = nil
    ) -> WGuardedChange {
        return WGuardedChange(
            askedIn: askedIn ?? self.askedIn,
            byGit: byGit ?? self.byGit,
            changedBy: changedBy ?? self.changedBy,
            changedByIDs: changedByIDs ?? self.changedByIDs,
            digest: digest ?? self.digest,
            path: path ?? self.path,
            since: since ?? self.since
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WProject
public struct WProject: Codable {
    public let addedAt: Double
    public let archivedAt: Double?
    public let diskSpace: WDiskThresholds?
    public let folder: String
    public let helperLimits: WHelperLimits?
    public let laidOutAt, layoutVersion: Double?
    public let pinned: Bool?

    public init(addedAt: Double, archivedAt: Double?, diskSpace: WDiskThresholds?, folder: String, helperLimits: WHelperLimits?, laidOutAt: Double?, layoutVersion: Double?, pinned: Bool?) {
        self.addedAt = addedAt
        self.archivedAt = archivedAt
        self.diskSpace = diskSpace
        self.folder = folder
        self.helperLimits = helperLimits
        self.laidOutAt = laidOutAt
        self.layoutVersion = layoutVersion
        self.pinned = pinned
    }
}

// MARK: WProject convenience initializers and mutators

public extension WProject {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WProject.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        addedAt: Double? = nil,
        archivedAt: Double?? = nil,
        diskSpace: WDiskThresholds?? = nil,
        folder: String? = nil,
        helperLimits: WHelperLimits?? = nil,
        laidOutAt: Double?? = nil,
        layoutVersion: Double?? = nil,
        pinned: Bool?? = nil
    ) -> WProject {
        return WProject(
            addedAt: addedAt ?? self.addedAt,
            archivedAt: archivedAt ?? self.archivedAt,
            diskSpace: diskSpace ?? self.diskSpace,
            folder: folder ?? self.folder,
            helperLimits: helperLimits ?? self.helperLimits,
            laidOutAt: laidOutAt ?? self.laidOutAt,
            layoutVersion: layoutVersion ?? self.layoutVersion,
            pinned: pinned ?? self.pinned
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WDiskThresholds
public struct WDiskThresholds: Codable {
    public let criticalGB, lowGB, lowPercent: Double?

    public init(criticalGB: Double?, lowGB: Double?, lowPercent: Double?) {
        self.criticalGB = criticalGB
        self.lowGB = lowGB
        self.lowPercent = lowPercent
    }
}

// MARK: WDiskThresholds convenience initializers and mutators

public extension WDiskThresholds {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WDiskThresholds.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        criticalGB: Double?? = nil,
        lowGB: Double?? = nil,
        lowPercent: Double?? = nil
    ) -> WDiskThresholds {
        return WDiskThresholds(
            criticalGB: criticalGB ?? self.criticalGB,
            lowGB: lowGB ?? self.lowGB,
            lowPercent: lowPercent ?? self.lowPercent
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WHelperLimits
public struct WHelperLimits: Codable {
    public let agentsMayArchive: Bool?
    public let notArchived, queued, running: Double?

    public init(agentsMayArchive: Bool?, notArchived: Double?, queued: Double?, running: Double?) {
        self.agentsMayArchive = agentsMayArchive
        self.notArchived = notArchived
        self.queued = queued
        self.running = running
    }
}

// MARK: WHelperLimits convenience initializers and mutators

public extension WHelperLimits {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WHelperLimits.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentsMayArchive: Bool?? = nil,
        notArchived: Double?? = nil,
        queued: Double?? = nil,
        running: Double?? = nil
    ) -> WHelperLimits {
        return WHelperLimits(
            agentsMayArchive: agentsMayArchive ?? self.agentsMayArchive,
            notArchived: notArchived ?? self.notArchived,
            queued: queued ?? self.queued,
            running: running ?? self.running
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPromptRequest
public struct WPromptRequest: Codable {
    public let agentID: String
    public let attachments: [WAttachment]
    public let from: WPromptOrigin
    public let sendID: String?
    public let text: String

    public init(agentID: String, attachments: [WAttachment], from: WPromptOrigin, sendID: String?, text: String) {
        self.agentID = agentID
        self.attachments = attachments
        self.from = from
        self.sendID = sendID
        self.text = text
    }
}

// MARK: WPromptRequest convenience initializers and mutators

public extension WPromptRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPromptRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        attachments: [WAttachment]? = nil,
        from: WPromptOrigin? = nil,
        sendID: String?? = nil,
        text: String? = nil
    ) -> WPromptRequest {
        return WPromptRequest(
            agentID: agentID ?? self.agentID,
            attachments: attachments ?? self.attachments,
            from: from ?? self.from,
            sendID: sendID ?? self.sendID,
            text: text ?? self.text
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRuntimeStatus
public struct WRuntimeStatus: Codable {
    public let availability: WRuntimeAvailability
    public let checkedAt: Double
    public let isOut: Bool?
    public let outdated: Bool
    public let poolNote: String?
    public let runtime: WRuntime

    public init(availability: WRuntimeAvailability, checkedAt: Double, isOut: Bool?, outdated: Bool, poolNote: String?, runtime: WRuntime) {
        self.availability = availability
        self.checkedAt = checkedAt
        self.isOut = isOut
        self.outdated = outdated
        self.poolNote = poolNote
        self.runtime = runtime
    }
}

// MARK: WRuntimeStatus convenience initializers and mutators

public extension WRuntimeStatus {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntimeStatus.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        availability: WRuntimeAvailability? = nil,
        checkedAt: Double? = nil,
        isOut: Bool?? = nil,
        outdated: Bool? = nil,
        poolNote: String?? = nil,
        runtime: WRuntime? = nil
    ) -> WRuntimeStatus {
        return WRuntimeStatus(
            availability: availability ?? self.availability,
            checkedAt: checkedAt ?? self.checkedAt,
            isOut: isOut ?? self.isOut,
            outdated: outdated ?? self.outdated,
            poolNote: poolNote ?? self.poolNote,
            runtime: runtime ?? self.runtime
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRuntimeAvailability
public struct WRuntimeAvailability: Codable {
    public let available: WAvailable?
    public let missing: WMissing?
    public let needsSignIn: WNeedsSignIn?
    public let failed: WRuntimeAvailabilityFailed?
    public let installing: WInstalling?
    public let installFailed: WInstallFailed?

    public init(available: WAvailable?, missing: WMissing?, needsSignIn: WNeedsSignIn?, failed: WRuntimeAvailabilityFailed?, installing: WInstalling?, installFailed: WInstallFailed?) {
        self.available = available
        self.missing = missing
        self.needsSignIn = needsSignIn
        self.failed = failed
        self.installing = installing
        self.installFailed = installFailed
    }
}

// MARK: WRuntimeAvailability convenience initializers and mutators

public extension WRuntimeAvailability {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntimeAvailability.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        available: WAvailable?? = nil,
        missing: WMissing?? = nil,
        needsSignIn: WNeedsSignIn?? = nil,
        failed: WRuntimeAvailabilityFailed?? = nil,
        installing: WInstalling?? = nil,
        installFailed: WInstallFailed?? = nil
    ) -> WRuntimeAvailability {
        return WRuntimeAvailability(
            available: available ?? self.available,
            missing: missing ?? self.missing,
            needsSignIn: needsSignIn ?? self.needsSignIn,
            failed: failed ?? self.failed,
            installing: installing ?? self.installing,
            installFailed: installFailed ?? self.installFailed
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAvailable
public struct WAvailable: Codable {
    public let path: String
    public let supportsResume: Bool

    public init(path: String, supportsResume: Bool) {
        self.path = path
        self.supportsResume = supportsResume
    }
}

// MARK: WAvailable convenience initializers and mutators

public extension WAvailable {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAvailable.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        path: String? = nil,
        supportsResume: Bool? = nil
    ) -> WAvailable {
        return WAvailable(
            path: path ?? self.path,
            supportsResume: supportsResume ?? self.supportsResume
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRuntimeAvailabilityFailed
public struct WRuntimeAvailabilityFailed: Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: WRuntimeAvailabilityFailed convenience initializers and mutators

public extension WRuntimeAvailabilityFailed {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntimeAvailabilityFailed.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reason: String? = nil
    ) -> WRuntimeAvailabilityFailed {
        return WRuntimeAvailabilityFailed(
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WInstallFailed
public struct WInstallFailed: Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: WInstallFailed convenience initializers and mutators

public extension WInstallFailed {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WInstallFailed.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reason: String? = nil
    ) -> WInstallFailed {
        return WInstallFailed(
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WInstalling
public struct WInstalling: Codable {
    public let progress: String?

    public init(progress: String?) {
        self.progress = progress
    }
}

// MARK: WInstalling convenience initializers and mutators

public extension WInstalling {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WInstalling.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        progress: String?? = nil
    ) -> WInstalling {
        return WInstalling(
            progress: progress ?? self.progress
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMissing
public struct WMissing: Codable {
    public let lookedIn: [String]

    public init(lookedIn: [String]) {
        self.lookedIn = lookedIn
    }
}

// MARK: WMissing convenience initializers and mutators

public extension WMissing {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMissing.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        lookedIn: [String]? = nil
    ) -> WMissing {
        return WMissing(
            lookedIn: lookedIn ?? self.lookedIn
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNeedsSignIn
public struct WNeedsSignIn: Codable {
    public let authMethods: [String]
    public let fixCommand: String?

    public init(authMethods: [String], fixCommand: String?) {
        self.authMethods = authMethods
        self.fixCommand = fixCommand
    }
}

// MARK: WNeedsSignIn convenience initializers and mutators

public extension WNeedsSignIn {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNeedsSignIn.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        authMethods: [String]? = nil,
        fixCommand: String?? = nil
    ) -> WNeedsSignIn {
        return WNeedsSignIn(
            authMethods: authMethods ?? self.authMethods,
            fixCommand: fixCommand ?? self.fixCommand
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRuntime
public struct WRuntime: Codable {
    public let arguments: [String]
    public let executable, id: String
    public let install: WRuntimeInstall?
    public let installPage, name: String
    public let usesAppCopyOnly: Bool

    public init(arguments: [String], executable: String, id: String, install: WRuntimeInstall?, installPage: String, name: String, usesAppCopyOnly: Bool) {
        self.arguments = arguments
        self.executable = executable
        self.id = id
        self.install = install
        self.installPage = installPage
        self.name = name
        self.usesAppCopyOnly = usesAppCopyOnly
    }
}

// MARK: WRuntime convenience initializers and mutators

public extension WRuntime {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntime.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        arguments: [String]? = nil,
        executable: String? = nil,
        id: String? = nil,
        install: WRuntimeInstall?? = nil,
        installPage: String? = nil,
        name: String? = nil,
        usesAppCopyOnly: Bool? = nil
    ) -> WRuntime {
        return WRuntime(
            arguments: arguments ?? self.arguments,
            executable: executable ?? self.executable,
            id: id ?? self.id,
            install: install ?? self.install,
            installPage: installPage ?? self.installPage,
            name: name ?? self.name,
            usesAppCopyOnly: usesAppCopyOnly ?? self.usesAppCopyOnly
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRuntimeInstall
public struct WRuntimeInstall: Codable {
    public let toolset: WToolset?
    public let script: WScript?
    public let npmGlobal: WNpmGlobal?

    public init(toolset: WToolset?, script: WScript?, npmGlobal: WNpmGlobal?) {
        self.toolset = toolset
        self.script = script
        self.npmGlobal = npmGlobal
    }
}

// MARK: WRuntimeInstall convenience initializers and mutators

public extension WRuntimeInstall {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntimeInstall.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        toolset: WToolset?? = nil,
        script: WScript?? = nil,
        npmGlobal: WNpmGlobal?? = nil
    ) -> WRuntimeInstall {
        return WRuntimeInstall(
            toolset: toolset ?? self.toolset,
            script: script ?? self.script,
            npmGlobal: npmGlobal ?? self.npmGlobal
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNpmGlobal
public struct WNpmGlobal: Codable {
    public let package: String

    public init(package: String) {
        self.package = package
    }
}

// MARK: WNpmGlobal convenience initializers and mutators

public extension WNpmGlobal {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNpmGlobal.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        package: String? = nil
    ) -> WNpmGlobal {
        return WNpmGlobal(
            package: package ?? self.package
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WScript
public struct WScript: Codable {
    public let shell, url: String

    public init(shell: String, url: String) {
        self.shell = shell
        self.url = url
    }
}

// MARK: WScript convenience initializers and mutators

public extension WScript {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WScript.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        shell: String? = nil,
        url: String? = nil
    ) -> WScript {
        return WScript(
            shell: shell ?? self.shell,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WToolset
public struct WToolset: Codable {
    public let runtimeID: String

    public init(runtimeID: String) {
        self.runtimeID = runtimeID
    }
}

// MARK: WToolset convenience initializers and mutators

public extension WToolset {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WToolset.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        runtimeID: String? = nil
    ) -> WToolset {
        return WToolset(
            runtimeID: runtimeID ?? self.runtimeID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WStartRequest
public struct WStartRequest: Codable {
    public let additionalDirectories: [String]
    public let attachments: [WAttachment]
    public let cwd: String
    public let draftID: String?
    public let labels: [String]
    public let mcpServers: [WMCPServer]
    public let persona: String?
    public let prompt: String
    public let purpose: WAgentPurpose?
    public let requestID: String?
    public let runtimeID: String
    public let sandbox: WSandboxChoice?
    public let startOptions: WStartOptions
    public let worktree: WorktreeChoice?

    public init(additionalDirectories: [String], attachments: [WAttachment], cwd: String, draftID: String?, labels: [String], mcpServers: [WMCPServer], persona: String?, prompt: String, purpose: WAgentPurpose?, requestID: String?, runtimeID: String, sandbox: WSandboxChoice?, startOptions: WStartOptions, worktree: WorktreeChoice?) {
        self.additionalDirectories = additionalDirectories
        self.attachments = attachments
        self.cwd = cwd
        self.draftID = draftID
        self.labels = labels
        self.mcpServers = mcpServers
        self.persona = persona
        self.prompt = prompt
        self.purpose = purpose
        self.requestID = requestID
        self.runtimeID = runtimeID
        self.sandbox = sandbox
        self.startOptions = startOptions
        self.worktree = worktree
    }
}

// MARK: WStartRequest convenience initializers and mutators

public extension WStartRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStartRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        additionalDirectories: [String]? = nil,
        attachments: [WAttachment]? = nil,
        cwd: String? = nil,
        draftID: String?? = nil,
        labels: [String]? = nil,
        mcpServers: [WMCPServer]? = nil,
        persona: String?? = nil,
        prompt: String? = nil,
        purpose: WAgentPurpose?? = nil,
        requestID: String?? = nil,
        runtimeID: String? = nil,
        sandbox: WSandboxChoice?? = nil,
        startOptions: WStartOptions? = nil,
        worktree: WorktreeChoice?? = nil
    ) -> WStartRequest {
        return WStartRequest(
            additionalDirectories: additionalDirectories ?? self.additionalDirectories,
            attachments: attachments ?? self.attachments,
            cwd: cwd ?? self.cwd,
            draftID: draftID ?? self.draftID,
            labels: labels ?? self.labels,
            mcpServers: mcpServers ?? self.mcpServers,
            persona: persona ?? self.persona,
            prompt: prompt ?? self.prompt,
            purpose: purpose ?? self.purpose,
            requestID: requestID ?? self.requestID,
            runtimeID: runtimeID ?? self.runtimeID,
            sandbox: sandbox ?? self.sandbox,
            startOptions: startOptions ?? self.startOptions,
            worktree: worktree ?? self.worktree
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTranscriptEntry
public struct WTranscriptEntry: Codable {
    public let at: Double
    public let id: String
    public let kind: WTranscriptEntryKind
    public let sender: WMessageSender?
    public let subagentID: String?

    public init(at: Double, id: String, kind: WTranscriptEntryKind, sender: WMessageSender?, subagentID: String?) {
        self.at = at
        self.id = id
        self.kind = kind
        self.sender = sender
        self.subagentID = subagentID
    }
}

// MARK: WTranscriptEntry convenience initializers and mutators

public extension WTranscriptEntry {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTranscriptEntry.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        at: Double? = nil,
        id: String? = nil,
        kind: WTranscriptEntryKind? = nil,
        sender: WMessageSender?? = nil,
        subagentID: String?? = nil
    ) -> WTranscriptEntry {
        return WTranscriptEntry(
            at: at ?? self.at,
            id: id ?? self.id,
            kind: kind ?? self.kind,
            sender: sender ?? self.sender,
            subagentID: subagentID ?? self.subagentID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTranscriptEntryKind
public struct WTranscriptEntryKind: Codable {
    public let userMessage: WUserMessage?
    public let agentMessage: WAgentMessage?
    public let agentThought: WAgentThought?
    public let toolCall: WTranscriptEntryKindToolCall?
    public let toolCallUpdate: WToolCallUpdate?
    public let planUpdated: WPlanUpdated?
    public let usageRecorded: WUsageRecorded?
    public let servedRequest: WServedRequest?
    public let elicitationAsked: WElicitationAsked?
    public let elicitationAnswered: WElicitationAnswered?
    public let compaction: WCompaction?
    public let notice: WNotice?
    public let permissionAsked: WPermissionAsked?
    public let permissionAnswered: WPermissionAnswered?
    public let optionChanged: WOptionChanged?
    public let stateChanged: WStateChanged?
    public let background: WBackground?
    public let workReported: WorkReported?
    public let runtimeNote: WRuntimeNote?
    public let poolSwitch: WPoolSwitch?
    public let sandboxFailure: WSandboxFailure?
    public let handoff: WHandoff?
    public let settingsChanged: WSettingsChanged?
    public let appView: WAppView?
    public let fileShown: WFileShown?

    public init(userMessage: WUserMessage?, agentMessage: WAgentMessage?, agentThought: WAgentThought?, toolCall: WTranscriptEntryKindToolCall?, toolCallUpdate: WToolCallUpdate?, planUpdated: WPlanUpdated?, usageRecorded: WUsageRecorded?, servedRequest: WServedRequest?, elicitationAsked: WElicitationAsked?, elicitationAnswered: WElicitationAnswered?, compaction: WCompaction?, notice: WNotice?, permissionAsked: WPermissionAsked?, permissionAnswered: WPermissionAnswered?, optionChanged: WOptionChanged?, stateChanged: WStateChanged?, background: WBackground?, workReported: WorkReported?, runtimeNote: WRuntimeNote?, poolSwitch: WPoolSwitch?, sandboxFailure: WSandboxFailure?, handoff: WHandoff?, settingsChanged: WSettingsChanged?, appView: WAppView?, fileShown: WFileShown?) {
        self.userMessage = userMessage
        self.agentMessage = agentMessage
        self.agentThought = agentThought
        self.toolCall = toolCall
        self.toolCallUpdate = toolCallUpdate
        self.planUpdated = planUpdated
        self.usageRecorded = usageRecorded
        self.servedRequest = servedRequest
        self.elicitationAsked = elicitationAsked
        self.elicitationAnswered = elicitationAnswered
        self.compaction = compaction
        self.notice = notice
        self.permissionAsked = permissionAsked
        self.permissionAnswered = permissionAnswered
        self.optionChanged = optionChanged
        self.stateChanged = stateChanged
        self.background = background
        self.workReported = workReported
        self.runtimeNote = runtimeNote
        self.poolSwitch = poolSwitch
        self.sandboxFailure = sandboxFailure
        self.handoff = handoff
        self.settingsChanged = settingsChanged
        self.appView = appView
        self.fileShown = fileShown
    }
}

// MARK: WTranscriptEntryKind convenience initializers and mutators

public extension WTranscriptEntryKind {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTranscriptEntryKind.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        userMessage: WUserMessage?? = nil,
        agentMessage: WAgentMessage?? = nil,
        agentThought: WAgentThought?? = nil,
        toolCall: WTranscriptEntryKindToolCall?? = nil,
        toolCallUpdate: WToolCallUpdate?? = nil,
        planUpdated: WPlanUpdated?? = nil,
        usageRecorded: WUsageRecorded?? = nil,
        servedRequest: WServedRequest?? = nil,
        elicitationAsked: WElicitationAsked?? = nil,
        elicitationAnswered: WElicitationAnswered?? = nil,
        compaction: WCompaction?? = nil,
        notice: WNotice?? = nil,
        permissionAsked: WPermissionAsked?? = nil,
        permissionAnswered: WPermissionAnswered?? = nil,
        optionChanged: WOptionChanged?? = nil,
        stateChanged: WStateChanged?? = nil,
        background: WBackground?? = nil,
        workReported: WorkReported?? = nil,
        runtimeNote: WRuntimeNote?? = nil,
        poolSwitch: WPoolSwitch?? = nil,
        sandboxFailure: WSandboxFailure?? = nil,
        handoff: WHandoff?? = nil,
        settingsChanged: WSettingsChanged?? = nil,
        appView: WAppView?? = nil,
        fileShown: WFileShown?? = nil
    ) -> WTranscriptEntryKind {
        return WTranscriptEntryKind(
            userMessage: userMessage ?? self.userMessage,
            agentMessage: agentMessage ?? self.agentMessage,
            agentThought: agentThought ?? self.agentThought,
            toolCall: toolCall ?? self.toolCall,
            toolCallUpdate: toolCallUpdate ?? self.toolCallUpdate,
            planUpdated: planUpdated ?? self.planUpdated,
            usageRecorded: usageRecorded ?? self.usageRecorded,
            servedRequest: servedRequest ?? self.servedRequest,
            elicitationAsked: elicitationAsked ?? self.elicitationAsked,
            elicitationAnswered: elicitationAnswered ?? self.elicitationAnswered,
            compaction: compaction ?? self.compaction,
            notice: notice ?? self.notice,
            permissionAsked: permissionAsked ?? self.permissionAsked,
            permissionAnswered: permissionAnswered ?? self.permissionAnswered,
            optionChanged: optionChanged ?? self.optionChanged,
            stateChanged: stateChanged ?? self.stateChanged,
            background: background ?? self.background,
            workReported: workReported ?? self.workReported,
            runtimeNote: runtimeNote ?? self.runtimeNote,
            poolSwitch: poolSwitch ?? self.poolSwitch,
            sandboxFailure: sandboxFailure ?? self.sandboxFailure,
            handoff: handoff ?? self.handoff,
            settingsChanged: settingsChanged ?? self.settingsChanged,
            appView: appView ?? self.appView,
            fileShown: fileShown ?? self.fileShown
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAgentMessage
public struct WAgentMessage: Codable {
    public let blocks: [WContentBlock]?
    public let messageID: String?
    public let text: String

    public init(blocks: [WContentBlock]?, messageID: String?, text: String) {
        self.blocks = blocks
        self.messageID = messageID
        self.text = text
    }
}

// MARK: WAgentMessage convenience initializers and mutators

public extension WAgentMessage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAgentMessage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        blocks: [WContentBlock]?? = nil,
        messageID: String?? = nil,
        text: String? = nil
    ) -> WAgentMessage {
        return WAgentMessage(
            blocks: blocks ?? self.blocks,
            messageID: messageID ?? self.messageID,
            text: text ?? self.text
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAgentThought
public struct WAgentThought: Codable {
    public let messageID: String?
    public let text: String

    public init(messageID: String?, text: String) {
        self.messageID = messageID
        self.text = text
    }
}

// MARK: WAgentThought convenience initializers and mutators

public extension WAgentThought {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAgentThought.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        messageID: String?? = nil,
        text: String? = nil
    ) -> WAgentThought {
        return WAgentThought(
            messageID: messageID ?? self.messageID,
            text: text ?? self.text
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAppView
public struct WAppView: Codable {
    public let the0: WAppViewCall

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WAppViewCall) {
        self.the0 = the0
    }
}

// MARK: WAppView convenience initializers and mutators

public extension WAppView {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAppView.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WAppViewCall? = nil
    ) -> WAppView {
        return WAppView(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAppViewCall
public struct WAppViewCall: Codable {
    public let arguments: JSONAny?
    public let id: String
    public let pinnable: Bool?
    public let reason: String?
    public let resourceUri: String
    public let result: JSONAny?
    public let server: String
    public let state: WAppViewCallState
    public let tool: String

    public init(arguments: JSONAny?, id: String, pinnable: Bool?, reason: String?, resourceUri: String, result: JSONAny?, server: String, state: WAppViewCallState, tool: String) {
        self.arguments = arguments
        self.id = id
        self.pinnable = pinnable
        self.reason = reason
        self.resourceUri = resourceUri
        self.result = result
        self.server = server
        self.state = state
        self.tool = tool
    }
}

// MARK: WAppViewCall convenience initializers and mutators

public extension WAppViewCall {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAppViewCall.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        arguments: JSONAny?? = nil,
        id: String? = nil,
        pinnable: Bool?? = nil,
        reason: String?? = nil,
        resourceUri: String? = nil,
        result: JSONAny?? = nil,
        server: String? = nil,
        state: WAppViewCallState? = nil,
        tool: String? = nil
    ) -> WAppViewCall {
        return WAppViewCall(
            arguments: arguments ?? self.arguments,
            id: id ?? self.id,
            pinnable: pinnable ?? self.pinnable,
            reason: reason ?? self.reason,
            resourceUri: resourceUri ?? self.resourceUri,
            result: result ?? self.result,
            server: server ?? self.server,
            state: state ?? self.state,
            tool: tool ?? self.tool
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WAppViewCallState: String, Codable {
    case cancelled = "cancelled"
    case done = "done"
    case running = "running"
}

// MARK: - WBackground
public struct WBackground: Codable {
    public let the0: WBackgroundItem

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WBackgroundItem) {
        self.the0 = the0
    }
}

// MARK: WBackground convenience initializers and mutators

public extension WBackground {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WBackground.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WBackgroundItem? = nil
    ) -> WBackground {
        return WBackground(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WCompaction
public struct WCompaction: Codable {
    public let error, id: String?
    public let status: String
    public let summary: [WContentBlock]

    public init(error: String?, id: String?, status: String, summary: [WContentBlock]) {
        self.error = error
        self.id = id
        self.status = status
        self.summary = summary
    }
}

// MARK: WCompaction convenience initializers and mutators

public extension WCompaction {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCompaction.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        error: String?? = nil,
        id: String?? = nil,
        status: String? = nil,
        summary: [WContentBlock]? = nil
    ) -> WCompaction {
        return WCompaction(
            error: error ?? self.error,
            id: id ?? self.id,
            status: status ?? self.status,
            summary: summary ?? self.summary
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationAnswered
public struct WElicitationAnswered: Codable {
    public let answers: [WElicitationAnswer]?
    public let id: String
    public let summary: String

    public init(answers: [WElicitationAnswer]?, id: String, summary: String) {
        self.answers = answers
        self.id = id
        self.summary = summary
    }
}

// MARK: WElicitationAnswered convenience initializers and mutators

public extension WElicitationAnswered {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationAnswered.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        answers: [WElicitationAnswer]?? = nil,
        id: String? = nil,
        summary: String? = nil
    ) -> WElicitationAnswered {
        return WElicitationAnswered(
            answers: answers ?? self.answers,
            id: id ?? self.id,
            summary: summary ?? self.summary
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationAnswer
public struct WElicitationAnswer: Codable {
    public let answer, question: String

    public init(answer: String, question: String) {
        self.answer = answer
        self.question = question
    }
}

// MARK: WElicitationAnswer convenience initializers and mutators

public extension WElicitationAnswer {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationAnswer.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        answer: String? = nil,
        question: String? = nil
    ) -> WElicitationAnswer {
        return WElicitationAnswer(
            answer: answer ?? self.answer,
            question: question ?? self.question
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationAsked
public struct WElicitationAsked: Codable {
    public let the0: WElicitationRequest

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WElicitationRequest) {
        self.the0 = the0
    }
}

// MARK: WElicitationAsked convenience initializers and mutators

public extension WElicitationAsked {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationAsked.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WElicitationRequest? = nil
    ) -> WElicitationAsked {
        return WElicitationAsked(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationRequest
public struct WElicitationRequest: Codable {
    public let agentID: String
    public let askedAt: Double
    public let elicitationID: String?
    public let id: String
    public let message: String?
    public let mode: WElicitationRequestMode
    public let scope: WElicitationRequestScope

    public init(agentID: String, askedAt: Double, elicitationID: String?, id: String, message: String?, mode: WElicitationRequestMode, scope: WElicitationRequestScope) {
        self.agentID = agentID
        self.askedAt = askedAt
        self.elicitationID = elicitationID
        self.id = id
        self.message = message
        self.mode = mode
        self.scope = scope
    }
}

// MARK: WElicitationRequest convenience initializers and mutators

public extension WElicitationRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        askedAt: Double? = nil,
        elicitationID: String?? = nil,
        id: String? = nil,
        message: String?? = nil,
        mode: WElicitationRequestMode? = nil,
        scope: WElicitationRequestScope? = nil
    ) -> WElicitationRequest {
        return WElicitationRequest(
            agentID: agentID ?? self.agentID,
            askedAt: askedAt ?? self.askedAt,
            elicitationID: elicitationID ?? self.elicitationID,
            id: id ?? self.id,
            message: message ?? self.message,
            mode: mode ?? self.mode,
            scope: scope ?? self.scope
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationRequestMode
public struct WElicitationRequestMode: Codable {
    public let form: WForm?
    public let url: WURL?

    public init(form: WForm?, url: WURL?) {
        self.form = form
        self.url = url
    }
}

// MARK: WElicitationRequestMode convenience initializers and mutators

public extension WElicitationRequestMode {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationRequestMode.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        form: WForm?? = nil,
        url: WURL?? = nil
    ) -> WElicitationRequestMode {
        return WElicitationRequestMode(
            form: form ?? self.form,
            url: url ?? self.url
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WForm
public struct WForm: Codable {
    public let the0: WElicitationSchema

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WElicitationSchema) {
        self.the0 = the0
    }
}

// MARK: WForm convenience initializers and mutators

public extension WForm {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WForm.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WElicitationSchema? = nil
    ) -> WForm {
        return WForm(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationSchema
public struct WElicitationSchema: Codable {
    public let description: String?
    public let properties: [WElicitationSchemaProperty]
    public let title: String?

    public init(description: String?, properties: [WElicitationSchemaProperty], title: String?) {
        self.description = description
        self.properties = properties
        self.title = title
    }
}

// MARK: WElicitationSchema convenience initializers and mutators

public extension WElicitationSchema {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationSchema.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        properties: [WElicitationSchemaProperty]? = nil,
        title: String?? = nil
    ) -> WElicitationSchema {
        return WElicitationSchema(
            description: description ?? self.description,
            properties: properties ?? self.properties,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationSchemaProperty
public struct WElicitationSchemaProperty: Codable {
    public let defaultValue: JSONAny?
    public let description: String?
    public let isRequired: Bool
    public let kind: WElicitationSchemaPropertyKind
    public let name: String
    public let title: String?

    public init(defaultValue: JSONAny?, description: String?, isRequired: Bool, kind: WElicitationSchemaPropertyKind, name: String, title: String?) {
        self.defaultValue = defaultValue
        self.description = description
        self.isRequired = isRequired
        self.kind = kind
        self.name = name
        self.title = title
    }
}

// MARK: WElicitationSchemaProperty convenience initializers and mutators

public extension WElicitationSchemaProperty {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationSchemaProperty.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        defaultValue: JSONAny?? = nil,
        description: String?? = nil,
        isRequired: Bool? = nil,
        kind: WElicitationSchemaPropertyKind? = nil,
        name: String? = nil,
        title: String?? = nil
    ) -> WElicitationSchemaProperty {
        return WElicitationSchemaProperty(
            defaultValue: defaultValue ?? self.defaultValue,
            description: description ?? self.description,
            isRequired: isRequired ?? self.isRequired,
            kind: kind ?? self.kind,
            name: name ?? self.name,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationSchemaPropertyKind
public struct WElicitationSchemaPropertyKind: Codable {
    public let string: WString?
    public let number: WNumber?
    public let integer: WInteger?
    public let boolean: [String: JSONAny]?
    public let multiSelect: WMultiSelect?

    public init(string: WString?, number: WNumber?, integer: WInteger?, boolean: [String: JSONAny]?, multiSelect: WMultiSelect?) {
        self.string = string
        self.number = number
        self.integer = integer
        self.boolean = boolean
        self.multiSelect = multiSelect
    }
}

// MARK: WElicitationSchemaPropertyKind convenience initializers and mutators

public extension WElicitationSchemaPropertyKind {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationSchemaPropertyKind.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        string: WString?? = nil,
        number: WNumber?? = nil,
        integer: WInteger?? = nil,
        boolean: [String: JSONAny]?? = nil,
        multiSelect: WMultiSelect?? = nil
    ) -> WElicitationSchemaPropertyKind {
        return WElicitationSchemaPropertyKind(
            string: string ?? self.string,
            number: number ?? self.number,
            integer: integer ?? self.integer,
            boolean: boolean ?? self.boolean,
            multiSelect: multiSelect ?? self.multiSelect
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WInteger
public struct WInteger: Codable {
    public let maximum, minimum: Double?

    public init(maximum: Double?, minimum: Double?) {
        self.maximum = maximum
        self.minimum = minimum
    }
}

// MARK: WInteger convenience initializers and mutators

public extension WInteger {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WInteger.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        maximum: Double?? = nil,
        minimum: Double?? = nil
    ) -> WInteger {
        return WInteger(
            maximum: maximum ?? self.maximum,
            minimum: minimum ?? self.minimum
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WMultiSelect
public struct WMultiSelect: Codable {
    public let items: [WElicitationSchemaPropertyChoice]
    public let maxItems, minItems: Double?

    public init(items: [WElicitationSchemaPropertyChoice], maxItems: Double?, minItems: Double?) {
        self.items = items
        self.maxItems = maxItems
        self.minItems = minItems
    }
}

// MARK: WMultiSelect convenience initializers and mutators

public extension WMultiSelect {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WMultiSelect.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        items: [WElicitationSchemaPropertyChoice]? = nil,
        maxItems: Double?? = nil,
        minItems: Double?? = nil
    ) -> WMultiSelect {
        return WMultiSelect(
            items: items ?? self.items,
            maxItems: maxItems ?? self.maxItems,
            minItems: minItems ?? self.minItems
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WElicitationSchemaPropertyChoice
public struct WElicitationSchemaPropertyChoice: Codable {
    public let description: String?
    public let title, value: String

    public init(description: String?, title: String, value: String) {
        self.description = description
        self.title = title
        self.value = value
    }
}

// MARK: WElicitationSchemaPropertyChoice convenience initializers and mutators

public extension WElicitationSchemaPropertyChoice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WElicitationSchemaPropertyChoice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        description: String?? = nil,
        title: String? = nil,
        value: String? = nil
    ) -> WElicitationSchemaPropertyChoice {
        return WElicitationSchemaPropertyChoice(
            description: description ?? self.description,
            title: title ?? self.title,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNumber
public struct WNumber: Codable {
    public let maximum, minimum: Double?

    public init(maximum: Double?, minimum: Double?) {
        self.maximum = maximum
        self.minimum = minimum
    }
}

// MARK: WNumber convenience initializers and mutators

public extension WNumber {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNumber.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        maximum: Double?? = nil,
        minimum: Double?? = nil
    ) -> WNumber {
        return WNumber(
            maximum: maximum ?? self.maximum,
            minimum: minimum ?? self.minimum
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WString
public struct WString: Codable {
    public let choices: [WElicitationSchemaPropertyChoice]?
    public let format: WElicitationSchemaPropertyFormat?
    public let maxLength, minLength: Double?

    public init(choices: [WElicitationSchemaPropertyChoice]?, format: WElicitationSchemaPropertyFormat?, maxLength: Double?, minLength: Double?) {
        self.choices = choices
        self.format = format
        self.maxLength = maxLength
        self.minLength = minLength
    }
}

// MARK: WString convenience initializers and mutators

public extension WString {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WString.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        choices: [WElicitationSchemaPropertyChoice]?? = nil,
        format: WElicitationSchemaPropertyFormat?? = nil,
        maxLength: Double?? = nil,
        minLength: Double?? = nil
    ) -> WString {
        return WString(
            choices: choices ?? self.choices,
            format: format ?? self.format,
            maxLength: maxLength ?? self.maxLength,
            minLength: minLength ?? self.minLength
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WElicitationSchemaPropertyFormat: String, Codable {
    case date = "date"
    case dateTime = "date-time"
    case email = "email"
    case uri = "uri"
}

// MARK: - WURL
public struct WURL: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WURL convenience initializers and mutators

public extension WURL {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WURL.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WURL {
        return WURL(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WElicitationRequestScope: String, Codable {
    case request = "request"
    case session = "session"
}

// MARK: - WFileShown
public struct WFileShown: Codable {
    public let the0: WShownFile

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WShownFile) {
        self.the0 = the0
    }
}

// MARK: WFileShown convenience initializers and mutators

public extension WFileShown {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WFileShown.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WShownFile? = nil
    ) -> WFileShown {
        return WFileShown(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WShownFile
public struct WShownFile: Codable {
    public let chart: WChartHint?
    public let line: Double?
    public let path: String

    public init(chart: WChartHint?, line: Double?, path: String) {
        self.chart = chart
        self.line = line
        self.path = path
    }
}

// MARK: WShownFile convenience initializers and mutators

public extension WShownFile {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WShownFile.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        chart: WChartHint?? = nil,
        line: Double?? = nil,
        path: String? = nil
    ) -> WShownFile {
        return WShownFile(
            chart: chart ?? self.chart,
            line: line ?? self.line,
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WChartHint
public struct WChartHint: Codable {
    public let color: String?
    public let mark: WChartMark
    public let title: String?
    public let x, y: String

    public init(color: String?, mark: WChartMark, title: String?, x: String, y: String) {
        self.color = color
        self.mark = mark
        self.title = title
        self.x = x
        self.y = y
    }
}

// MARK: WChartHint convenience initializers and mutators

public extension WChartHint {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WChartHint.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        color: String?? = nil,
        mark: WChartMark? = nil,
        title: String?? = nil,
        x: String? = nil,
        y: String? = nil
    ) -> WChartHint {
        return WChartHint(
            color: color ?? self.color,
            mark: mark ?? self.mark,
            title: title ?? self.title,
            x: x ?? self.x,
            y: y ?? self.y
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WChartMark: String, Codable {
    case area = "area"
    case bar = "bar"
    case line = "line"
    case point = "point"
}

// MARK: - WHandoff
public struct WHandoff: Codable {
    public let characters: Double
    public let markdown: String

    public init(characters: Double, markdown: String) {
        self.characters = characters
        self.markdown = markdown
    }
}

// MARK: WHandoff convenience initializers and mutators

public extension WHandoff {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WHandoff.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        characters: Double? = nil,
        markdown: String? = nil
    ) -> WHandoff {
        return WHandoff(
            characters: characters ?? self.characters,
            markdown: markdown ?? self.markdown
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WNotice
public struct WNotice: Codable {
    public let the0: WSessionNotice

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WSessionNotice) {
        self.the0 = the0
    }
}

// MARK: WNotice convenience initializers and mutators

public extension WNotice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WNotice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WSessionNotice? = nil
    ) -> WNotice {
        return WNotice(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSessionNotice
public struct WSessionNotice: Codable {
    public let detail: String?
    public let severity, title: String

    public init(detail: String?, severity: String, title: String) {
        self.detail = detail
        self.severity = severity
        self.title = title
    }
}

// MARK: WSessionNotice convenience initializers and mutators

public extension WSessionNotice {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSessionNotice.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        detail: String?? = nil,
        severity: String? = nil,
        title: String? = nil
    ) -> WSessionNotice {
        return WSessionNotice(
            detail: detail ?? self.detail,
            severity: severity ?? self.severity,
            title: title ?? self.title
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WOptionChanged
public struct WOptionChanged: Codable {
    public let id: String
    public let value: JSONAny

    public init(id: String, value: JSONAny) {
        self.id = id
        self.value = value
    }
}

// MARK: WOptionChanged convenience initializers and mutators

public extension WOptionChanged {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WOptionChanged.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        id: String? = nil,
        value: JSONAny? = nil
    ) -> WOptionChanged {
        return WOptionChanged(
            id: id ?? self.id,
            value: value ?? self.value
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPermissionAnswered
public struct WPermissionAnswered: Codable {
    public let optionID: String
    public let optionName: String?

    public init(optionID: String, optionName: String?) {
        self.optionID = optionID
        self.optionName = optionName
    }
}

// MARK: WPermissionAnswered convenience initializers and mutators

public extension WPermissionAnswered {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPermissionAnswered.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        optionID: String? = nil,
        optionName: String?? = nil
    ) -> WPermissionAnswered {
        return WPermissionAnswered(
            optionID: optionID ?? self.optionID,
            optionName: optionName ?? self.optionName
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPermissionAsked
public struct WPermissionAsked: Codable {
    public let the0: WPermissionRequest

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WPermissionRequest) {
        self.the0 = the0
    }
}

// MARK: WPermissionAsked convenience initializers and mutators

public extension WPermissionAsked {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPermissionAsked.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WPermissionRequest? = nil
    ) -> WPermissionAsked {
        return WPermissionAsked(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPlanUpdated
public struct WPlanUpdated: Codable {
    public let the0: WPlan

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WPlan) {
        self.the0 = the0
    }
}

// MARK: WPlanUpdated convenience initializers and mutators

public extension WPlanUpdated {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPlanUpdated.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WPlan? = nil
    ) -> WPlanUpdated {
        return WPlanUpdated(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPoolSwitch
public struct WPoolSwitch: Codable {
    public let the0: WSwitchRecord

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WSwitchRecord) {
        self.the0 = the0
    }
}

// MARK: WPoolSwitch convenience initializers and mutators

public extension WPoolSwitch {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPoolSwitch.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WSwitchRecord? = nil
    ) -> WPoolSwitch {
        return WPoolSwitch(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSwitchRecord
public struct WSwitchRecord: Codable {
    public let agentID: String
    public let at: Double
    public let billing: WPayment
    public let carried: [WCarriedSetting]
    public let dropped: [WDropped]
    public let from: WSwitchRecordSide
    public let fromReturnsAt: Double?
    public let id: String
    public let reason: WSwitchRecordReason
    public let shortened: Double?
    public let to: WSwitchRecordSide

    public init(agentID: String, at: Double, billing: WPayment, carried: [WCarriedSetting], dropped: [WDropped], from: WSwitchRecordSide, fromReturnsAt: Double?, id: String, reason: WSwitchRecordReason, shortened: Double?, to: WSwitchRecordSide) {
        self.agentID = agentID
        self.at = at
        self.billing = billing
        self.carried = carried
        self.dropped = dropped
        self.from = from
        self.fromReturnsAt = fromReturnsAt
        self.id = id
        self.reason = reason
        self.shortened = shortened
        self.to = to
    }
}

// MARK: WSwitchRecord convenience initializers and mutators

public extension WSwitchRecord {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSwitchRecord.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        agentID: String? = nil,
        at: Double? = nil,
        billing: WPayment? = nil,
        carried: [WCarriedSetting]? = nil,
        dropped: [WDropped]? = nil,
        from: WSwitchRecordSide? = nil,
        fromReturnsAt: Double?? = nil,
        id: String? = nil,
        reason: WSwitchRecordReason? = nil,
        shortened: Double?? = nil,
        to: WSwitchRecordSide? = nil
    ) -> WSwitchRecord {
        return WSwitchRecord(
            agentID: agentID ?? self.agentID,
            at: at ?? self.at,
            billing: billing ?? self.billing,
            carried: carried ?? self.carried,
            dropped: dropped ?? self.dropped,
            from: from ?? self.from,
            fromReturnsAt: fromReturnsAt ?? self.fromReturnsAt,
            id: id ?? self.id,
            reason: reason ?? self.reason,
            shortened: shortened ?? self.shortened,
            to: to ?? self.to
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPayment
public struct WPayment: Codable {
    public let allowance: WAllowance?
    public let freeTier: WFreeTier?
    public let freeCredit: WFreeCredit?
    public let prepaid: WPrepaid?

    public init(allowance: WAllowance?, freeTier: WFreeTier?, freeCredit: WFreeCredit?, prepaid: WPrepaid?) {
        self.allowance = allowance
        self.freeTier = freeTier
        self.freeCredit = freeCredit
        self.prepaid = prepaid
    }
}

// MARK: WPayment convenience initializers and mutators

public extension WPayment {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPayment.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        allowance: WAllowance?? = nil,
        freeTier: WFreeTier?? = nil,
        freeCredit: WFreeCredit?? = nil,
        prepaid: WPrepaid?? = nil
    ) -> WPayment {
        return WPayment(
            allowance: allowance ?? self.allowance,
            freeTier: freeTier ?? self.freeTier,
            freeCredit: freeCredit ?? self.freeCredit,
            prepaid: prepaid ?? self.prepaid
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAllowance
public struct WAllowance: Codable {
    public let label: String?

    public init(label: String?) {
        self.label = label
    }
}

// MARK: WAllowance convenience initializers and mutators

public extension WAllowance {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAllowance.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        label: String?? = nil
    ) -> WAllowance {
        return WAllowance(
            label: label ?? self.label
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WFreeCredit
public struct WFreeCredit: Codable {
    public let amount: WCost?
    public let expires: Double?

    public init(amount: WCost?, expires: Double?) {
        self.amount = amount
        self.expires = expires
    }
}

// MARK: WFreeCredit convenience initializers and mutators

public extension WFreeCredit {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WFreeCredit.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        amount: WCost?? = nil,
        expires: Double?? = nil
    ) -> WFreeCredit {
        return WFreeCredit(
            amount: amount ?? self.amount,
            expires: expires ?? self.expires
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WFreeTier
public struct WFreeTier: Codable {
    public let reset: WResetRule

    public init(reset: WResetRule) {
        self.reset = reset
    }
}

// MARK: WFreeTier convenience initializers and mutators

public extension WFreeTier {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WFreeTier.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reset: WResetRule? = nil
    ) -> WFreeTier {
        return WFreeTier(
            reset: reset ?? self.reset
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WResetRule
public struct WResetRule: Codable {
    public let dailyAt: WDailyAt?
    public let unknown: [String: JSONAny]?

    public init(dailyAt: WDailyAt?, unknown: [String: JSONAny]?) {
        self.dailyAt = dailyAt
        self.unknown = unknown
    }
}

// MARK: WResetRule convenience initializers and mutators

public extension WResetRule {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WResetRule.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        dailyAt: WDailyAt?? = nil,
        unknown: [String: JSONAny]?? = nil
    ) -> WResetRule {
        return WResetRule(
            dailyAt: dailyAt ?? self.dailyAt,
            unknown: unknown ?? self.unknown
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WDailyAt
public struct WDailyAt: Codable {
    public let hour: Double
    public let timeZone: String

    public init(hour: Double, timeZone: String) {
        self.hour = hour
        self.timeZone = timeZone
    }
}

// MARK: WDailyAt convenience initializers and mutators

public extension WDailyAt {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WDailyAt.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        hour: Double? = nil,
        timeZone: String? = nil
    ) -> WDailyAt {
        return WDailyAt(
            hour: hour ?? self.hour,
            timeZone: timeZone ?? self.timeZone
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WPrepaid
public struct WPrepaid: Codable {
    public let amount: WCost?
    public let expires: Double?

    public init(amount: WCost?, expires: Double?) {
        self.amount = amount
        self.expires = expires
    }
}

// MARK: WPrepaid convenience initializers and mutators

public extension WPrepaid {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WPrepaid.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        amount: WCost?? = nil,
        expires: Double?? = nil
    ) -> WPrepaid {
        return WPrepaid(
            amount: amount ?? self.amount,
            expires: expires ?? self.expires
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WCarriedSetting
public struct WCarriedSetting: Codable {
    public let from: JSONAny?
    public let name, optionID: String
    public let source: WCarriedSettingSource
    public let to: JSONAny?

    public init(from: JSONAny?, name: String, optionID: String, source: WCarriedSettingSource, to: JSONAny?) {
        self.from = from
        self.name = name
        self.optionID = optionID
        self.source = source
        self.to = to
    }
}

// MARK: WCarriedSetting convenience initializers and mutators

public extension WCarriedSetting {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCarriedSetting.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        from: JSONAny?? = nil,
        name: String? = nil,
        optionID: String? = nil,
        source: WCarriedSettingSource? = nil,
        to: JSONAny?? = nil
    ) -> WCarriedSetting {
        return WCarriedSetting(
            from: from ?? self.from,
            name: name ?? self.name,
            optionID: optionID ?? self.optionID,
            source: source ?? self.source,
            to: to ?? self.to
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WCarriedSettingSource
public struct WCarriedSettingSource: Codable {
    public let level: WLevel?
    public let sameValue, poolEntry, remembered, runtimeDefault: [String: JSONAny]?
    public let strictestMode, closestNoLooser, person: [String: JSONAny]?

    public init(level: WLevel?, sameValue: [String: JSONAny]?, poolEntry: [String: JSONAny]?, remembered: [String: JSONAny]?, runtimeDefault: [String: JSONAny]?, strictestMode: [String: JSONAny]?, closestNoLooser: [String: JSONAny]?, person: [String: JSONAny]?) {
        self.level = level
        self.sameValue = sameValue
        self.poolEntry = poolEntry
        self.remembered = remembered
        self.runtimeDefault = runtimeDefault
        self.strictestMode = strictestMode
        self.closestNoLooser = closestNoLooser
        self.person = person
    }
}

// MARK: WCarriedSettingSource convenience initializers and mutators

public extension WCarriedSettingSource {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WCarriedSettingSource.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        level: WLevel?? = nil,
        sameValue: [String: JSONAny]?? = nil,
        poolEntry: [String: JSONAny]?? = nil,
        remembered: [String: JSONAny]?? = nil,
        runtimeDefault: [String: JSONAny]?? = nil,
        strictestMode: [String: JSONAny]?? = nil,
        closestNoLooser: [String: JSONAny]?? = nil,
        person: [String: JSONAny]?? = nil
    ) -> WCarriedSettingSource {
        return WCarriedSettingSource(
            level: level ?? self.level,
            sameValue: sameValue ?? self.sameValue,
            poolEntry: poolEntry ?? self.poolEntry,
            remembered: remembered ?? self.remembered,
            runtimeDefault: runtimeDefault ?? self.runtimeDefault,
            strictestMode: strictestMode ?? self.strictestMode,
            closestNoLooser: closestNoLooser ?? self.closestNoLooser,
            person: person ?? self.person
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WLevel
public struct WLevel: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WLevel convenience initializers and mutators

public extension WLevel {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WLevel.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WLevel {
        return WLevel(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WDropped
public struct WDropped: Codable {
    public let extraArguments: WExtraArguments?
    public let alwaysAllow: WAlwaysAllow?
    public let queuedSlashCommand: WQueuedSlashCommand?

    public init(extraArguments: WExtraArguments?, alwaysAllow: WAlwaysAllow?, queuedSlashCommand: WQueuedSlashCommand?) {
        self.extraArguments = extraArguments
        self.alwaysAllow = alwaysAllow
        self.queuedSlashCommand = queuedSlashCommand
    }
}

// MARK: WDropped convenience initializers and mutators

public extension WDropped {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WDropped.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        extraArguments: WExtraArguments?? = nil,
        alwaysAllow: WAlwaysAllow?? = nil,
        queuedSlashCommand: WQueuedSlashCommand?? = nil
    ) -> WDropped {
        return WDropped(
            extraArguments: extraArguments ?? self.extraArguments,
            alwaysAllow: alwaysAllow ?? self.alwaysAllow,
            queuedSlashCommand: queuedSlashCommand ?? self.queuedSlashCommand
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WAlwaysAllow
public struct WAlwaysAllow: Codable {
    public let count: Double

    public init(count: Double) {
        self.count = count
    }
}

// MARK: WAlwaysAllow convenience initializers and mutators

public extension WAlwaysAllow {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WAlwaysAllow.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        count: Double? = nil
    ) -> WAlwaysAllow {
        return WAlwaysAllow(
            count: count ?? self.count
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WExtraArguments
public struct WExtraArguments: Codable {
    public let the0: [String]

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: [String]) {
        self.the0 = the0
    }
}

// MARK: WExtraArguments convenience initializers and mutators

public extension WExtraArguments {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WExtraArguments.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: [String]? = nil
    ) -> WExtraArguments {
        return WExtraArguments(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WQueuedSlashCommand
public struct WQueuedSlashCommand: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WQueuedSlashCommand convenience initializers and mutators

public extension WQueuedSlashCommand {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WQueuedSlashCommand.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WQueuedSlashCommand {
        return WQueuedSlashCommand(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSwitchRecordSide
public struct WSwitchRecordSide: Codable {
    public let entryID: String?
    public let mode, model: JSONAny?
    public let runtimeID: String

    public init(entryID: String?, mode: JSONAny?, model: JSONAny?, runtimeID: String) {
        self.entryID = entryID
        self.mode = mode
        self.model = model
        self.runtimeID = runtimeID
    }
}

// MARK: WSwitchRecordSide convenience initializers and mutators

public extension WSwitchRecordSide {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSwitchRecordSide.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        entryID: String?? = nil,
        mode: JSONAny?? = nil,
        model: JSONAny?? = nil,
        runtimeID: String? = nil
    ) -> WSwitchRecordSide {
        return WSwitchRecordSide(
            entryID: entryID ?? self.entryID,
            mode: mode ?? self.mode,
            model: model ?? self.model,
            runtimeID: runtimeID ?? self.runtimeID
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

public enum WSwitchRecordReason: String, Codable {
    case allowanceSpent = "allowanceSpent"
    case byHand = "byHand"
    case creditUsedUp = "creditUsedUp"
    case everyoneOutResumed = "everyoneOutResumed"
    case overage = "overage"
    case rateLimitPersisted = "rateLimitPersisted"
    case runtimeFailed = "runtimeFailed"
}

// MARK: - WRuntimeNote
public struct WRuntimeNote: Codable {
    public let the0: String

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: String) {
        self.the0 = the0
    }
}

// MARK: WRuntimeNote convenience initializers and mutators

public extension WRuntimeNote {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRuntimeNote.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil
    ) -> WRuntimeNote {
        return WRuntimeNote(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSandboxFailure
public struct WSandboxFailure: Codable {
    public let the0: WSandboxFailureRecord

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WSandboxFailureRecord) {
        self.the0 = the0
    }
}

// MARK: WSandboxFailure convenience initializers and mutators

public extension WSandboxFailure {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSandboxFailure.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WSandboxFailureRecord? = nil
    ) -> WSandboxFailure {
        return WSandboxFailure(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WServedRequest
public struct WServedRequest: Codable {
    public let the0: WThe0_Class

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WThe0_Class) {
        self.the0 = the0
    }
}

// MARK: WServedRequest convenience initializers and mutators

public extension WServedRequest {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WServedRequest.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WThe0_Class? = nil
    ) -> WServedRequest {
        return WServedRequest(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WThe0_Class
public struct WThe0_Class: Codable {
    public let kind: WServedRequestKind
    public let outcome: WServedRequestOutcome

    public init(kind: WServedRequestKind, outcome: WServedRequestOutcome) {
        self.kind = kind
        self.outcome = outcome
    }
}

// MARK: WThe0_Class convenience initializers and mutators

public extension WThe0_Class {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WThe0_Class.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        kind: WServedRequestKind? = nil,
        outcome: WServedRequestOutcome? = nil
    ) -> WThe0_Class {
        return WThe0_Class(
            kind: kind ?? self.kind,
            outcome: outcome ?? self.outcome
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WServedRequestKind
public struct WServedRequestKind: Codable {
    public let readFile: WReadFile?
    public let writeFile: WriteFile?
    public let runCommand: WRunCommand?

    public init(readFile: WReadFile?, writeFile: WriteFile?, runCommand: WRunCommand?) {
        self.readFile = readFile
        self.writeFile = writeFile
        self.runCommand = runCommand
    }
}

// MARK: WServedRequestKind convenience initializers and mutators

public extension WServedRequestKind {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WServedRequestKind.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        readFile: WReadFile?? = nil,
        writeFile: WriteFile?? = nil,
        runCommand: WRunCommand?? = nil
    ) -> WServedRequestKind {
        return WServedRequestKind(
            readFile: readFile ?? self.readFile,
            writeFile: writeFile ?? self.writeFile,
            runCommand: runCommand ?? self.runCommand
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WReadFile
public struct WReadFile: Codable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

// MARK: WReadFile convenience initializers and mutators

public extension WReadFile {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WReadFile.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        path: String? = nil
    ) -> WReadFile {
        return WReadFile(
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRunCommand
public struct WRunCommand: Codable {
    public let args: [String]
    public let command: String

    public init(args: [String], command: String) {
        self.args = args
        self.command = command
    }
}

// MARK: WRunCommand convenience initializers and mutators

public extension WRunCommand {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRunCommand.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        args: [String]? = nil,
        command: String? = nil
    ) -> WRunCommand {
        return WRunCommand(
            args: args ?? self.args,
            command: command ?? self.command
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WriteFile
public struct WriteFile: Codable {
    public let byteCount: Double
    public let path: String

    public init(byteCount: Double, path: String) {
        self.byteCount = byteCount
        self.path = path
    }
}

// MARK: WriteFile convenience initializers and mutators

public extension WriteFile {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WriteFile.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        byteCount: Double? = nil,
        path: String? = nil
    ) -> WriteFile {
        return WriteFile(
            byteCount: byteCount ?? self.byteCount,
            path: path ?? self.path
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WServedRequestOutcome
public struct WServedRequestOutcome: Codable {
    public let served: [String: JSONAny]?
    public let refused: WRefused?
    public let failed: WServedRequestOutcomeFailed?

    public init(served: [String: JSONAny]?, refused: WRefused?, failed: WServedRequestOutcomeFailed?) {
        self.served = served
        self.refused = refused
        self.failed = failed
    }
}

// MARK: WServedRequestOutcome convenience initializers and mutators

public extension WServedRequestOutcome {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WServedRequestOutcome.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        served: [String: JSONAny]?? = nil,
        refused: WRefused?? = nil,
        failed: WServedRequestOutcomeFailed?? = nil
    ) -> WServedRequestOutcome {
        return WServedRequestOutcome(
            served: served ?? self.served,
            refused: refused ?? self.refused,
            failed: failed ?? self.failed
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WServedRequestOutcomeFailed
public struct WServedRequestOutcomeFailed: Codable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

// MARK: WServedRequestOutcomeFailed convenience initializers and mutators

public extension WServedRequestOutcomeFailed {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WServedRequestOutcomeFailed.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        message: String? = nil
    ) -> WServedRequestOutcomeFailed {
        return WServedRequestOutcomeFailed(
            message: message ?? self.message
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WRefused
public struct WRefused: Codable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: WRefused convenience initializers and mutators

public extension WRefused {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WRefused.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        reason: String? = nil
    ) -> WRefused {
        return WRefused(
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WSettingsChanged
public struct WSettingsChanged: Codable {
    public let the0: WSwitchRecord

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WSwitchRecord) {
        self.the0 = the0
    }
}

// MARK: WSettingsChanged convenience initializers and mutators

public extension WSettingsChanged {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WSettingsChanged.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WSwitchRecord? = nil
    ) -> WSettingsChanged {
        return WSettingsChanged(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WStateChanged
public struct WStateChanged: Codable {
    public let the0: WAgentState
    public let reason: WEndedReason?

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
        case reason
    }

    public init(the0: WAgentState, reason: WEndedReason?) {
        self.the0 = the0
        self.reason = reason
    }
}

// MARK: WStateChanged convenience initializers and mutators

public extension WStateChanged {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WStateChanged.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WAgentState? = nil,
        reason: WEndedReason?? = nil
    ) -> WStateChanged {
        return WStateChanged(
            the0: the0 ?? self.the0,
            reason: reason ?? self.reason
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTranscriptEntryKindToolCall
public struct WTranscriptEntryKindToolCall: Codable {
    public let the0: WToolCall

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WToolCall) {
        self.the0 = the0
    }
}

// MARK: WTranscriptEntryKindToolCall convenience initializers and mutators

public extension WTranscriptEntryKindToolCall {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTranscriptEntryKindToolCall.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WToolCall? = nil
    ) -> WTranscriptEntryKindToolCall {
        return WTranscriptEntryKindToolCall(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WToolCallUpdate
public struct WToolCallUpdate: Codable {
    public let the0: WToolCall

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WToolCall) {
        self.the0 = the0
    }
}

// MARK: WToolCallUpdate convenience initializers and mutators

public extension WToolCallUpdate {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WToolCallUpdate.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WToolCall? = nil
    ) -> WToolCallUpdate {
        return WToolCallUpdate(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WUsageRecorded
public struct WUsageRecorded: Codable {
    public let the0: WTurnUsage

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WTurnUsage) {
        self.the0 = the0
    }
}

// MARK: WUsageRecorded convenience initializers and mutators

public extension WUsageRecorded {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WUsageRecorded.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WTurnUsage? = nil
    ) -> WUsageRecorded {
        return WUsageRecorded(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WUserMessage
public struct WUserMessage: Codable {
    public let the0: String
    public let blocks: [WContentBlock]?
    public let from: WPromptOrigin?

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
        case blocks, from
    }

    public init(the0: String, blocks: [WContentBlock]?, from: WPromptOrigin?) {
        self.the0 = the0
        self.blocks = blocks
        self.from = from
    }
}

// MARK: WUserMessage convenience initializers and mutators

public extension WUserMessage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WUserMessage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: String? = nil,
        blocks: [WContentBlock]?? = nil,
        from: WPromptOrigin?? = nil
    ) -> WUserMessage {
        return WUserMessage(
            the0: the0 ?? self.the0,
            blocks: blocks ?? self.blocks,
            from: from ?? self.from
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WorkReported
public struct WorkReported: Codable {
    public let the0: WorkReport

    public enum CodingKeys: String, CodingKey {
        case the0 = "_0"
    }

    public init(the0: WorkReport) {
        self.the0 = the0
    }
}

// MARK: WorkReported convenience initializers and mutators

public extension WorkReported {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WorkReported.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        the0: WorkReport? = nil
    ) -> WorkReported {
        return WorkReported(
            the0: the0 ?? self.the0
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTranscriptPage
public struct WTranscriptPage: Codable {
    public let entries: [WTranscriptEntry]
    public let firstIndex, total: Double

    public init(entries: [WTranscriptEntry], firstIndex: Double, total: Double) {
        self.entries = entries
        self.firstIndex = firstIndex
        self.total = total
    }
}

// MARK: WTranscriptPage convenience initializers and mutators

public extension WTranscriptPage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTranscriptPage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        entries: [WTranscriptEntry]? = nil,
        firstIndex: Double? = nil,
        total: Double? = nil
    ) -> WTranscriptPage {
        return WTranscriptPage(
            entries: entries ?? self.entries,
            firstIndex: firstIndex ?? self.firstIndex,
            total: total ?? self.total
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTurnsPage
public struct WTurnsPage: Codable {
    public let firstTurn, openStart: Double
    public let turns: [WTurnSummary]

    public init(firstTurn: Double, openStart: Double, turns: [WTurnSummary]) {
        self.firstTurn = firstTurn
        self.openStart = openStart
        self.turns = turns
    }
}

// MARK: WTurnsPage convenience initializers and mutators

public extension WTurnsPage {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTurnsPage.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        firstTurn: Double? = nil,
        openStart: Double? = nil,
        turns: [WTurnSummary]? = nil
    ) -> WTurnsPage {
        return WTurnsPage(
            firstTurn: firstTurn ?? self.firstTurn,
            openStart: openStart ?? self.openStart,
            turns: turns ?? self.turns
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - WTurnSummary
public struct WTurnSummary: Codable {
    public let ask: WTranscriptEntry?
    public let concise: [WTranscriptEntry]?
    public let end: Double
    public let id: String
    public let last: WTranscriptEntry?
    public let outcome: [WTranscriptEntry]?
    public let start: Double
    public let steps: Double?
    public let usage: WTurnUsage?

    public init(ask: WTranscriptEntry?, concise: [WTranscriptEntry]?, end: Double, id: String, last: WTranscriptEntry?, outcome: [WTranscriptEntry]?, start: Double, steps: Double?, usage: WTurnUsage?) {
        self.ask = ask
        self.concise = concise
        self.end = end
        self.id = id
        self.last = last
        self.outcome = outcome
        self.start = start
        self.steps = steps
        self.usage = usage
    }
}

// MARK: WTurnSummary convenience initializers and mutators

public extension WTurnSummary {
    init(data: Data) throws {
        self = try newJSONDecoder().decode(WTurnSummary.self, from: data)
    }

    init(_ json: String, using encoding: String.Encoding = .utf8) throws {
        guard let data = json.data(using: encoding) else {
            throw NSError(domain: "JSONDecoding", code: 0, userInfo: nil)
        }
        try self.init(data: data)
    }

    init(fromURL url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    func with(
        ask: WTranscriptEntry?? = nil,
        concise: [WTranscriptEntry]?? = nil,
        end: Double? = nil,
        id: String? = nil,
        last: WTranscriptEntry?? = nil,
        outcome: [WTranscriptEntry]?? = nil,
        start: Double? = nil,
        steps: Double?? = nil,
        usage: WTurnUsage?? = nil
    ) -> WTurnSummary {
        return WTurnSummary(
            ask: ask ?? self.ask,
            concise: concise ?? self.concise,
            end: end ?? self.end,
            id: id ?? self.id,
            last: last ?? self.last,
            outcome: outcome ?? self.outcome,
            start: start ?? self.start,
            steps: steps ?? self.steps,
            usage: usage ?? self.usage
        )
    }

    func jsonData() throws -> Data {
        return try newJSONEncoder().encode(self)
    }

    func jsonString(encoding: String.Encoding = .utf8) throws -> String? {
        return String(data: try self.jsonData(), encoding: encoding)
    }
}

// MARK: - Helper functions for creating encoders and decoders

func newJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        decoder.dateDecodingStrategy = .iso8601
    }
    return decoder
}

func newJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    if #available(iOS 10.0, OSX 10.12, tvOS 10.0, watchOS 3.0, *) {
        encoder.dateEncodingStrategy = .iso8601
    }
    return encoder
}

// MARK: - Encode/decode helpers

public class JSONNull: Codable, Hashable {

    public static func == (lhs: JSONNull, rhs: JSONNull) -> Bool {
            return true
    }

    public var hashValue: Int {
            return 0
    }

    public init() {}

    public required init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if !container.decodeNil() {
                    throw DecodingError.typeMismatch(JSONNull.self, DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONNull"))
            }
    }

    public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encodeNil()
    }
}

class JSONCodingKey: CodingKey {
    let key: String

    required init?(intValue: Int) {
            return nil
    }

    required init?(stringValue: String) {
            key = stringValue
    }

    var intValue: Int? {
            return nil
    }

    var stringValue: String {
            return key
    }
}

public class JSONAny: Codable {

    public let value: Any

    static func decodingError(forCodingPath codingPath: [CodingKey]) -> DecodingError {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode JSONAny")
            return DecodingError.typeMismatch(JSONAny.self, context)
    }

    static func encodingError(forValue value: Any, codingPath: [CodingKey]) -> EncodingError {
            let context = EncodingError.Context(codingPath: codingPath, debugDescription: "Cannot encode JSONAny")
            return EncodingError.invalidValue(value, context)
    }

    static func decode(from container: SingleValueDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if container.decodeNil() {
                    return JSONNull()
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout UnkeyedDecodingContainer) throws -> Any {
            if let value = try? container.decode(Bool.self) {
                    return value
            }
            if let value = try? container.decode(Int64.self) {
                    return value
            }
            if let value = try? container.decode(Double.self) {
                    return value
            }
            if let value = try? container.decode(String.self) {
                    return value
            }
            if let value = try? container.decodeNil() {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer() {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decode(from container: inout KeyedDecodingContainer<JSONCodingKey>, forKey key: JSONCodingKey) throws -> Any {
            if let value = try? container.decode(Bool.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Int64.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                    return value
            }
            if let value = try? container.decode(String.self, forKey: key) {
                    return value
            }
            if let value = try? container.decodeNil(forKey: key) {
                    if value {
                            return JSONNull()
                    }
            }
            if var container = try? container.nestedUnkeyedContainer(forKey: key) {
                    return try decodeArray(from: &container)
            }
            if var container = try? container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key) {
                    return try decodeDictionary(from: &container)
            }
            throw decodingError(forCodingPath: container.codingPath)
    }

    static func decodeArray(from container: inout UnkeyedDecodingContainer) throws -> [Any] {
            var arr: [Any] = []
            while !container.isAtEnd {
                    let value = try decode(from: &container)
                    arr.append(value)
            }
            return arr
    }

    static func decodeDictionary(from container: inout KeyedDecodingContainer<JSONCodingKey>) throws -> [String: Any] {
            var dict = [String: Any]()
            for key in container.allKeys {
                    let value = try decode(from: &container, forKey: key)
                    dict[key.stringValue] = value
            }
            return dict
    }

    static func encode(to container: inout UnkeyedEncodingContainer, array: [Any]) throws {
            for value in array {
                    if let value = value as? Bool {
                            try container.encode(value)
                    } else if let value = value as? Int64 {
                            try container.encode(value)
                    } else if let value = value as? Double {
                            try container.encode(value)
                    } else if let value = value as? String {
                            try container.encode(value)
                    } else if value is JSONNull {
                            try container.encodeNil()
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer()
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout KeyedEncodingContainer<JSONCodingKey>, dictionary: [String: Any]) throws {
            for (key, value) in dictionary {
                    let key = JSONCodingKey(stringValue: key)!
                    if let value = value as? Bool {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Int64 {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? Double {
                            try container.encode(value, forKey: key)
                    } else if let value = value as? String {
                            try container.encode(value, forKey: key)
                    } else if value is JSONNull {
                            try container.encodeNil(forKey: key)
                    } else if let value = value as? [Any] {
                            var container = container.nestedUnkeyedContainer(forKey: key)
                            try encode(to: &container, array: value)
                    } else if let value = value as? [String: Any] {
                            var container = container.nestedContainer(keyedBy: JSONCodingKey.self, forKey: key)
                            try encode(to: &container, dictionary: value)
                    } else {
                            throw encodingError(forValue: value, codingPath: container.codingPath)
                    }
            }
    }

    static func encode(to container: inout SingleValueEncodingContainer, value: Any) throws {
            if let value = value as? Bool {
                    try container.encode(value)
            } else if let value = value as? Int64 {
                    try container.encode(value)
            } else if let value = value as? Double {
                    try container.encode(value)
            } else if let value = value as? String {
                    try container.encode(value)
            } else if value is JSONNull {
                    try container.encodeNil()
            } else {
                    throw encodingError(forValue: value, codingPath: container.codingPath)
            }
    }

    public required init(from decoder: Decoder) throws {
            if var arrayContainer = try? decoder.unkeyedContainer() {
                    self.value = try JSONAny.decodeArray(from: &arrayContainer)
            } else if var container = try? decoder.container(keyedBy: JSONCodingKey.self) {
                    self.value = try JSONAny.decodeDictionary(from: &container)
            } else {
                    let container = try decoder.singleValueContainer()
                    self.value = try JSONAny.decode(from: container)
            }
    }

    public func encode(to encoder: Encoder) throws {
            if let arr = self.value as? [Any] {
                    var container = encoder.unkeyedContainer()
                    try JSONAny.encode(to: &container, array: arr)
            } else if let dict = self.value as? [String: Any] {
                    var container = encoder.container(keyedBy: JSONCodingKey.self)
                    try JSONAny.encode(to: &container, dictionary: dict)
            } else {
                    var container = encoder.singleValueContainer()
                    try JSONAny.encode(to: &container, value: self.value)
            }
    }
}
