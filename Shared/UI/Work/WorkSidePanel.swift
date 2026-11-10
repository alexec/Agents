import AgentsKitCore
import SwiftUI

/// An item page's side panel (#4391, parts.md section 5): sections, each a small grey heading and
/// its value, with a hairline between. On a wide page (the Mac, an iPad) a column of 240 points on
/// the trailing side; on a narrow one (a phone, a Mac window under 700 points) a compact block of
/// rows, "Assignees · alexec", under the header.
struct WorkSidePanel<Content: View>: View {
    var compact = false
    @ViewBuilder var content: Content

    /// The column's width on a wide page.
    static var width: CGFloat { 240 }
    /// Under this a page draws the panel narrow, as a block under its header.
    static var narrowUnder: CGFloat { 700 }

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 0) { content }
                .environment(\.workSideCompact, true)
                .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.well))
        } else {
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(width: Self.width, alignment: .leading)
        }
    }
}

extension EnvironmentValues {
    @Entry var workSideCompact = false
}

/// One section of the side panel: Assignees, Labels, Milestone, Repo, Linked or Lineage. `edit`
/// puts a gear by its heading (the pages say which forges can edit what).
struct WorkSideSection<Content: View>: View {
    let title: String
    var edit: (() -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.workSideCompact) private var compact
    @State private var hovered = false

    var body: some View {
        if compact {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).appText(.fine).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) { content }
                    .appText(.supporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let edit {
                    Button(action: edit) { Image(systemName: "chevron.right") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .accessibilityLabel("Edit \(title.lowercased())")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { edit?() }
            Divider().padding(.leading, 12)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let edit {
                        // Faint until the pointer is on the section, never hidden: VoiceOver and
                        // the keyboard find a control at no opacity only by chance (#4400).
                        Button(action: edit) { Image(systemName: "gearshape") }
                            .buttonStyle(.plain)
                            .foregroundStyle(hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                            .help("Edit \(title.lowercased())")
                            .accessibilityLabel("Edit \(title.lowercased())")
                    }
                }
                content.appText(.supporting)
            }
            .padding(.vertical, 10)
            .onHover { hovered = $0 }
            Divider()
        }
    }
}

/// A side panel's "No one" or "None": the value of a section with nothing in it.
struct WorkSideNone: View {
    let words: String

    var body: some View { Text(words).foregroundStyle(.secondary) }
}

/// A person on the side panel: the avatar and the login.
struct WorkSidePerson: View {
    let login: String

    var body: some View {
        HStack(spacing: 6) {
            WorkAvatar(login: login)
            Text(login).lineLimit(1)
        }
    }
}

/// A linked item on the side panel (the parent, a child, a pull request that fixes it): the state
/// icon, the number and the title, on one line. It opens the item.
struct WorkSideLinked: View {
    let node: DaemonAPI.LineageNode
    var title: String?
    var state = ""
    var open: (() -> Void)?

    var body: some View {
        Button { open?() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                WorkStateIcon(kind: node.kind, state: state)
                Text(WorkList.shortRef(node.ref)).foregroundStyle(.secondary).monospacedDigit()
                if let title { Text.forgeTitle(title).lineLimit(1) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(open == nil)
    }
}
