import Foundation

/// A chat that was waiting for an allowance to come back (052, US4). Nothing waits since
/// 065: kept only so a record written then still loads, and cleared at launch.
public struct AllowanceWait: Codable, Hashable, Sendable {
    /// When the first entry is due a check; moved on while none has passed.
    public var resumeAt: Date
    /// That entry, and its runtime, for saying which.
    public var entryID: UUID?
    public var runtimeID: String
    /// What was refused, to be sent again.
    public var text: String
    public var blocks: [ContentBlock]
    public var from: PromptOrigin

    public init(resumeAt: Date, entryID: UUID?, runtimeID: String, text: String,
                blocks: [ContentBlock], from: PromptOrigin) {
        self.resumeAt = resumeAt
        self.entryID = entryID
        self.runtimeID = runtimeID
        self.text = text
        self.blocks = blocks
        self.from = from
    }

    public func isDue(now: Date) -> Bool { resumeAt <= now }
}
