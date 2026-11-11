import AgentsKitCore
import SwiftUI

/// A Work row in two lines (#4391, parts.md section 2), the same on the Mac and the Remote: the
/// state icon, the title and its label chips, and at the trailing edge a pull request's checks
/// and review, the comment count and the assignees; under it the number, the age and author, and
/// what lineage knows. On a phone the title takes two lines, the chips wrap under it, the second
/// line is shorter and the avatars go.
struct WorkItemRow: View {
    let row: WorkList.Row
    /// The list shows more than one repo: the row says its own.
    let several: Bool
    var compact = false
    /// The latest release of its repo: a green Latest chip after its name (#4421).
    var latest = false
    /// Sets the list's Label filter to a chip (Mac); nil leaves the chips as words.
    var pick: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WorkStateIcon(kind: row.node.kind, state: row.state, draft: row.draft, stateReason: row.stateReason)
                .frame(width: 16)
            if compact { stacked } else { wide }
        }
        .padding(.vertical, compact ? 4 : 3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityWords)
    }

    /// The pictures the forge gives on a row: the author's, for an assignee who wrote it (#4363).
    private var avatars: [String: String] {
        guard let author = row.author, let avatar = row.avatar else { return [:] }
        return [author: avatar]
    }

    private var title: Text { Text.forgeTitle(row.title).fontWeight(.semibold) }

    private var wide: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                title.lineLimit(1).truncationMode(.tail).layoutPriority(1)
                if latest { WorkReleaseChip.latest.fixedSize() }
                // As many chips as fit whole, the rest as "+2", so a narrow window never squeezes one.
                ViewThatFits(in: .horizontal) {
                    ForEach((0 ... WorkLook.rowChips).reversed(), id: \.self) { chips($0) }
                }
                Spacer(minLength: 8)
                trailing
                WorkAvatarStack(logins: row.assignees, avatars: avatars)
            }
            HStack(spacing: 6) {
                secondLine
                Spacer(minLength: 8)
                if several {
                    Text(WorkList.repoName(row.repo)).appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func chips(_ limit: Int) -> some View {
        let chips = WorkLook.shownLabels(row.labels, limit: limit)
        return HStack(spacing: 6) {
            ForEach(chips.shown, id: \.name) { WorkLabelChip(label: $0, pick: pick).fixedSize() }
            WorkMoreChips(count: chips.more).fixedSize()
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                title.lineLimit(2)
                if latest { WorkReleaseChip.latest.fixedSize() }
            }
            if !row.labels.isEmpty || several {
                WrappingHStack(spacing: 4) {
                    ForEach(row.labels, id: \.name) { WorkLabelChip(label: $0) }
                    if several {
                        Text(WorkList.repoName(row.repo)).appText(.fine).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 6) {
                secondLine
                Spacer(minLength: 4)
                // No checks glyph or review word on a phone: the item's page has them (lists.md section 3).
                comments
            }
        }
    }

    private var secondLine: some View {
        Text(WorkLook.rowLine(row, compact: compact))
            .appText(.fine)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }

    /// A pull request's checks glyph and review word, then the comment count.
    @ViewBuilder
    private var trailing: some View {
        if let checks = WorkLook.checks(row.checks) { WorkChecksGlyph(checks: checks) }
        if let review = WorkLook.reviewWord(row.review) {
            Text(review).appText(.fine).foregroundStyle(row.review == "changes_requested" ? WorkLook.Tone.red.color : .secondary)
                .lineLimit(1)
        }
        comments
    }

    @ViewBuilder
    private var comments: some View {
        if let n = WorkLook.commentsWords(row.comments) {
            Label(n, systemImage: "bubble.left")
                .labelStyle(.titleAndIcon)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var accessibilityWords: String {
        var parts = [WorkLook.glyph(kind: row.node.kind, state: row.state, draft: row.draft, stateReason: row.stateReason)?
            .accessibilityLabel, row.title,
                     latest ? WorkReleaseChip.latest.words : nil]
        parts.append(row.labels.isEmpty ? nil : "labels " + row.labels.map(\.name).joined(separator: ", "))
        parts.append(WorkLook.rowLine(row, compact: false))
        parts.append(WorkLook.checks(row.checks)?.accessibilityLabel)
        parts.append(WorkLook.reviewWord(row.review))
        parts.append(row.comments > 0 ? "\(row.comments) comments" : nil)
        parts.append(row.assignees.isEmpty ? nil : "assigned to " + row.assignees.joined(separator: ", "))
        if several { parts.append(WorkList.repoName(row.repo)) }
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// A pull request's checks as a glyph: a tick, a cross or a dot, in the state's colour.
struct WorkChecksGlyph: View {
    let checks: WorkLook.Checks

    var body: some View {
        Group {
            switch checks {
            case .passing: Image(systemName: "checkmark").foregroundStyle(WorkLook.Tone.green.color)
            case .failing: Image(systemName: "xmark").foregroundStyle(WorkLook.Tone.red.color)
            case .running: Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(Color(light: 0x9A6700, dark: 0xD29922))
            }
        }
        .appText(.fine)
        .fontWeight(.semibold)
        .help(checks.accessibilityLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(checks.accessibilityLabel)
    }
}
