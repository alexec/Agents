import Foundation

/// One answer a banner can give without the app (#1170): a button, or a line of text.
///
/// Made by the daemon from the question's own options, never from a fixed list, and put
/// in the need's `Headline`, so every banner (the Mac's, the phone's local one and the
/// sealed push) has the same buttons. The answer itself is the card's answer: the same
/// call to the daemon, which refuses it when the need is already over.
///
/// Only what fits in one tap or one line: a permission's options, a question with one
/// choice of two to four options, or a question with one free-text field. A form with
/// more than that has no answers here, and a tap opens the card (Alex can overrule:
/// a banner cannot show a form, and a half answer is worse than one tap more).
public struct QuickAnswer: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// A permission's option, or one option of a question's one choice.
        case choice
        /// A question's one free-text field.
        case reply
    }

    public var kind: Kind
    /// The permission's `optionID`, or the choice's value. Empty for a reply.
    public var id: String
    /// What the button says.
    public var title: String
    /// The question's field this answers. Nil for a permission.
    public var field: String?
    /// Drawn in red: a permission's reject options.
    public var isDestructive: Bool

    public init(kind: Kind, id: String, title: String, field: String? = nil, isDestructive: Bool = false) {
        self.kind = kind
        self.id = id
        self.title = title
        self.field = field
        self.isDestructive = isDestructive
    }

    /// The most a button's title may carry, in characters. A banner shows a short line.
    public static let titleBudget = 40
    /// The most buttons a banner shows (Apple shows four on a banner).
    public static let most = 4

    /// This answer with its title cut to `titleBudget`, and never empty.
    public func truncating() -> QuickAnswer {
        var answer = self
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            answer.title = kind == .reply ? "Reply" : id
        } else if trimmed.count > Self.titleBudget {
            answer.title = String(trimmed.prefix(Self.titleBudget - 1)) + "…"
        } else {
            answer.title = trimmed
        }
        return answer
    }

    /// A permission's answers: one button for each of its options, in the runtime's order.
    /// Nil when it has none, or more than a banner shows.
    public static func answers(for request: PermissionRequest) -> [QuickAnswer]? {
        guard !request.options.isEmpty, request.options.count <= most else { return nil }
        return request.options.map { option in
            QuickAnswer(kind: .choice, id: option.optionID, title: option.name,
                        isDestructive: option.kind == .rejectOnce || option.kind == .rejectAlways)
        }
    }

    /// A question's answers: one button for each option of a one-choice form with two to
    /// four options, or a Reply for a form with one free-text field. A choice may carry
    /// its optional note beside it (`question_0_custom`, see `ElicitationSchema.pages`):
    /// left empty, the choice is still a whole answer. Nil for anything else: a page to
    /// open, more than one question, a number, more options than fit, or a secret, which a
    /// banner's reply would take in clear (#2885).
    public static func answers(for request: ElicitationRequest) -> [QuickAnswer]? {
        guard case .form(let schema) = request.mode, request.secret == nil else { return nil }
        let pages = schema.pages
        guard pages.count == 1, let only = pages[0].first,
              case .string(let format, _, _, let choices) = only.kind else { return nil }
        if let choices, !choices.isEmpty {
            guard (2...most).contains(choices.count) else { return nil }
            return choices.map { QuickAnswer(kind: .choice, id: $0.value, title: $0.title, field: only.name) }
        }
        guard pages[0].count == 1, format == nil else { return nil }
        return [QuickAnswer(kind: .reply, id: "", title: "Reply", field: only.name)]
    }

    /// What goes to the daemon for this answer to a question: the one field, with the
    /// option or the line typed. Nil for a reply with nothing typed, or no field.
    public func content(typed text: String? = nil) -> [String: JSONValue]? {
        guard let field else { return nil }
        switch kind {
        case .choice:
            return [field: .string(id)]
        case .reply:
            let typed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return nil }
            return [field: .string(typed)]
        }
    }

    /// The name of the set of buttons these answers make, for the notification centre's
    /// category. The same buttons are the same category, so a dozen permissions with
    /// Allow / Always allow / Reject register one. Stable from one launch to the next
    /// (FNV-1a, not `Hasher`, whose seed changes every run).
    public static func categoryID(for answers: [QuickAnswer]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for answer in answers {
            for byte in "\(answer.kind.rawValue)\u{1}\(answer.title)\u{1}\(answer.isDestructive)\u{2}".utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return "answers:" + String(hash, radix: 16)
    }

    /// The action's identifier for the answer at `index` in its banner.
    public static func actionID(at index: Int) -> String { "answer:\(index)" }

    /// The index an action's identifier names, or nil for a tap on the banner itself.
    public static func index(ofAction identifier: String) -> Int? {
        guard identifier.hasPrefix("answer:") else { return nil }
        return Int(identifier.dropFirst("answer:".count))
    }

    /// The key under which a banner's `userInfo` keeps its answers, as JSON text.
    public static let userInfoKey = "answers"

    /// The answers as `userInfo` can hold them.
    public static func userInfoValue(_ answers: [QuickAnswer]) -> String? {
        (try? JSONEncoder().encode(answers)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The answers a banner's `userInfo` kept.
    public static func answers(inUserInfo userInfo: [AnyHashable: Any]) -> [QuickAnswer]? {
        guard let text = userInfo[userInfoKey] as? String else { return nil }
        return try? JSONDecoder().decode([QuickAnswer].self, from: Data(text.utf8))
    }
}
