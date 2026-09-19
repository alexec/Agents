import SwiftUI

/// A select, drawn as a glass capsule.
///
/// Closed, it reads as the chosen value, because that is what you want to see at a
/// glance. Open, it reads as the name of the setting, because that is the question you
/// are answering. The name is also the tooltip, for when neither is enough.
///
/// Built from a button and a popover rather than from `Menu`, so the label can change
/// while it is open.
struct SelectCapsule<Content: View>: View {
    let name: String
    let title: String
    @ViewBuilder var choices: (@escaping () -> Void) -> Content

    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 4) {
                Text(isOpen ? name : title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(name)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                choices { isOpen = false }
            }
            .padding(6)
        }
    }
}

/// One line in an open select.
struct SelectChoice: View {
    let title: String
    let description: String?
    let isChosen: Bool
    let choose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(isChosen ? "✓" : " ")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.footnote)
                    if let description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
