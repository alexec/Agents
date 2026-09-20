import SwiftUI

/// A select, drawn as a glass capsule.
///
/// It reads as the chosen value, open or closed, because that is what you want to see
/// at a glance and a control that changes its own label is a control that moves. The
/// name of the setting is at the top of the list, and in the tooltip.
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
                Text(title)
                Image(systemName: "chevron.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
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
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                choices { isOpen = false }
            }
            .padding(6)
        }
    }
}

/// A setting that is on or off, drawn as the same capsule as a select.
///
/// The Claude adapter sends its fast mode as a two-item menu until the app says it
/// takes booleans, and as this once it does. A thing with two states should look like
/// one thing, not a list of two.
struct BooleanCapsule: View {
    let name: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button {
            set(!isOn)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(name)
            }
        }
        .buttonStyle(.plain)
        .font(.footnote)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(name)
        .accessibilityValue(isOn ? "on" : "off")
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
