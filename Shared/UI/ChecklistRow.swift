import SwiftUI

/// One step of a checklist: a tick or an open circle, the title, and while it is not done
/// a grey line saying how, with the step's own button under it. The Mac's Get started
/// card draws it (#982); here, not in the app, so the milestones list on all three
/// clients (#984) can draw an earned and an unearned milestone with the same row.
struct ChecklistRow<Action: View>: View {
    let title: String
    let how: String
    let isDone: Bool
    @ViewBuilder var action: () -> Action

    init(title: String, how: String, isDone: Bool, @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        self.how = how
        self.isDone = isDone
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                // Decorative: the row's state, said in its accessibility value.
                .glyph(size: 13)
                .foregroundStyle(isDone ? AnyShapeStyle(Paper.accent) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !isDone {
                    Text(how)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Under the words, not beside them: a sidebar is narrow, and beside
                    // them the title and the how were cut short.
                    action().padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(isDone ? "Done" : "Not done")
    }
}

extension ChecklistRow where Action == EmptyView {
    init(title: String, how: String, isDone: Bool) {
        self.init(title: title, how: how, isDone: isDone) { EmptyView() }
    }
}
