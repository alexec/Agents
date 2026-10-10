import Foundation

/// A session's history as another agent reads it (065): the app's own record of what
/// was asked, what was said, what was done and the plan as it stood, in Markdown.
///
/// Built a transcript entry at a time, in order, so a session of tens of megabytes is
/// never held whole: the first turn, the latest turns that fit and the last plan are
/// all it keeps. Given whole when it fits the budget; otherwise the middle goes, and
/// the history says how many turns. The daemon feeds it only the first turn and the
/// latest it read back from the end, and says how many it skipped (#210).
public enum SessionHistory {
    /// Characters. Over this, the middle of the conversation is left out.
    public static let budget = 80_000

    public struct Worktree: Hashable, Sendable {
        public var name: String
        public var branch: String?

        public init(name: String, branch: String?) {
            self.name = name
            self.branch = branch
        }
    }

    /// What the history says of the session before any of it.
    public struct Header: Hashable, Sendable {
        public var id: UUID
        public var title: String?
        /// The runtime's name, as the person sees it.
        public var runtime: String
        /// The status in the words the agent list uses.
        public var status: String
        /// Where its files were written.
        public var folder: String
        public var worktree: Worktree?

        public init(id: UUID, title: String?, runtime: String, status: String, folder: String,
                    worktree: Worktree?) {
            self.id = id
            self.title = title
            self.runtime = runtime
            self.status = status
            self.folder = folder
            self.worktree = worktree
        }
    }

    public struct Document: Hashable, Sendable {
        public var markdown: String
        /// Turns left out to fit the budget; nil when the whole record fit.
        public var leftOut: Int?
    }

    /// The history of `entries`, all at once. The same as a `Builder` fed them in turn.
    public static func document(header: Header, entries: [TranscriptEntry],
                                budget: Int = budget) -> Document {
        var builder = Builder(runtime: header.runtime, budget: budget)
        for entry in entries { builder.add(entry) }
        return builder.document(header: header)
    }

    /// Keeps what a history needs as entries arrive in order, and no more.
    public struct Builder: Sendable {
        private let runtime: String
        private let budget: Int
        /// The first turn, once the second has begun.
        private var first: String?
        /// The turn being read, as pieces still able to change: a reply arrives a chunk
        /// at a time, and a tool call learns its file and its real title from updates.
        private var current: [Piece] = []
        /// Whether the entry before this one was the reply being built, which the next
        /// chunk of that reply continues. Anything between them ends it, as in the chat.
        private var replyOpen = false
        /// The app's own calls, whose updates are not lines either.
        private var suppressed: Set<String> = []
        /// The latest complete turns, oldest first, kept within the budget.
        private var kept: [String] = []
        private var keptSize = 0
        /// Complete turns between `first` and `kept` that no longer fit.
        private var dropped = 0
        private var plan: Plan?

        public init(runtime: String, budget: Int = SessionHistory.budget) {
            self.runtime = runtime
            self.budget = budget
        }

        private enum Piece: Sendable {
            case line(String)
            case reply(TranscriptEntry)
            case tool(ToolCall)
        }

        /// The same folding the chat does (`TranscriptDisplayBuilder`): chunks of one
        /// message joined, and a tool call's updates merged into it.
        public mutating func add(_ entry: TranscriptEntry) {
            // A subagent's steps are its own; the call that started it is the parent's line.
            guard entry.subagentID == nil else { return }
            if replyOpen, case .reply(let prior) = current.last,
               let joined = TranscriptEntry.join(entry, onto: prior) {
                current[current.count - 1] = .reply(joined)
                return
            }
            replyOpen = false
            switch entry.kind {
            case .userMessage(let text, _, let from):
                close()
                let who = switch from {
                case .person: "The person"
                case .app: "The app"
                case .agent: "\u{201C}\(entry.sender?.title ?? "Another agent")\u{201D}"
                }
                current = [.line("**\(who):** \(text)")]
            case .agentMessage:
                current.append(.reply(entry))
                replyOpen = true
            case .toolCall(let call), .toolCallUpdate(let call):
                if let id = call.toolCallID, suppressed.contains(id) { return }
                if Self.isTheApps(call) {
                    if let id = call.toolCallID { suppressed.insert(id) }
                    return
                }
                if let id = call.toolCallID, let at = current.lastIndex(where: {
                    if case .tool(let earlier) = $0 { return earlier.toolCallID == id }
                    return false
                }), case .tool(let earlier) = current[at] {
                    current[at] = .tool(TranscriptEntry.merge(call, onto: earlier))
                } else if case .toolCall = entry.kind {
                    current.append(.tool(call))
                }
            case .workReported(let report):
                current.append(.line("*Said how the work went: \(report.outcome.rawValue). \(report.message)*"))
            case .planUpdated(let updated):
                plan = updated.state == .current ? updated : nil
            default:
                break
            }
        }

        private func render(_ piece: Piece) -> String? {
            switch piece {
            case .line(let text):
                return text
            case .reply(let entry):
                guard case .agentMessage(_, let text, _) = entry.kind, !text.isEmpty else { return nil }
                return "**\(runtime):** \(text)"
            case .tool(let call):
                return "- \(call.line)" + (call.locations.first.map { " (`\($0.path)`)" } ?? "")
            }
        }

        /// A tool the app serves is the app's bookkeeping, not what the session did.
        private static func isTheApps(_ call: ToolCall) -> Bool {
            call.isTheApps || [call.name, call.title].contains { $0.map(AppTool.isServedByTheApp) == true }
        }

        /// The turn being read is over, though no ask follows: the next entries begin a
        /// turn of their own (#210).
        public mutating func endTurn() {
            replyOpen = false
            close()
        }

        /// `count` whole turns after the one being read were not read, to bound the read
        /// (#210). The history says so as it does for the ones the budget leaves out.
        public mutating func leaveOut(_ count: Int) {
            endTurn()
            dropped += max(0, count)
        }

        /// The turn being read is over: it becomes the first, or the latest kept.
        private mutating func close() {
            let lines = current.compactMap(render)
            current = []
            guard !lines.isEmpty else { return }
            let turn = lines.joined(separator: "\n")
            guard first != nil else {
                first = turn
                return
            }
            kept.append(turn)
            keptSize += turn.count + 2
            // Nothing past the budget can be in the result, so none of it is held.
            while keptSize > budget, !kept.isEmpty {
                keptSize -= kept.removeFirst().count + 2
                dropped += 1
            }
        }

        public func document(header: Header) -> Document {
            var builder = self
            builder.close()
            return builder.finished(header: header)
        }

        private func finished(header: Header) -> Document {
            let top = Self.header(header)
            guard let first else {
                return Document(markdown: top + "Nothing has been said in this session yet.\n", leftOut: nil)
            }
            let planText = plan.map(Self.planText) ?? ""
            var latest = kept
            var leftOut = dropped
            var text = Self.assemble(top, first, latest, leftOut, planText)
            while text.count > budget, !latest.isEmpty {
                latest.removeFirst()
                leftOut += 1
                text = Self.assemble(top, first, latest, leftOut, planText)
            }
            return Document(markdown: text, leftOut: leftOut == 0 ? nil : leftOut)
        }

        private static func assemble(_ top: String, _ first: String, _ latest: [String], _ leftOut: Int,
                                     _ planText: String) -> String {
            var parts = [first]
            if leftOut > 0 { parts.append("*\(leftOut) turns in the middle were left out to fit.*") }
            parts += latest
            return top + "## The conversation\n\n" + parts.joined(separator: "\n\n") + "\n" + planText
        }

        private static func header(_ header: Header) -> String {
            let name = header.title.map { "\u{201C}\($0)\u{201D}" } ?? "Untitled"
            var lines = [
                "# Session \(name)",
                "",
                "- Id: \(header.id.uuidString)",
                "- Runtime: \(header.runtime)",
                "- Status: \(header.status)",
                "- Working folder: `\(header.folder)`",
            ]
            if let worktree = header.worktree {
                lines.append("- Worktree: \(worktree.name)" + (worktree.branch.map { ", on branch `\($0)`" } ?? ""))
            }
            lines += [
                "",
                "This is the app's record of that session: what was asked, what was said, the tools "
                    + "that ran and the plan. Reading it did not change it. The files are as that "
                    + "session left them.",
                "", "",
            ]
            return lines.joined(separator: "\n")
        }

        private static func planText(_ plan: Plan) -> String {
            guard !plan.entries.isEmpty else { return "" }
            return "\n## The plan, as it last stood\n\n"
                + plan.entries.map { "- [\($0.status == .completed ? "x" : " ")] \($0.content)" }
                    .joined(separator: "\n")
                + "\n"
        }
    }
}
