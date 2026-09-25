import SwiftUI

/// A select, drawn as a raised paper capsule.
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
            // The capsule is the button, not the words in it: padding put on outside
            // a plain button is paper that takes no clicks.
            .padding(.horizontal, 10)
            .padding(.vertical, TouchTarget.capsuleVertical)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .help(name)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                choices { isOpen = false }
            }
            .padding(6)
            .paperPopover()
            // A popover on a phone too, not a sheet: choosing a model is a glance,
            // and a sheet over the conversation is a trip away from it (033).
            .presentationCompactAdaptation(.popover)
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
            .padding(.horizontal, 10)
            .padding(.vertical, TouchTarget.capsuleVertical)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
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
                    .appText(.code)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).appText(.fine)
                    if let description, !description.isEmpty {
                        Text(description)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, TouchTarget.rowVertical)
            .background(isHovered ? AnyShapeStyle(Paper.wash) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// The same controls under a thumb as under a pointer, taller where a thumb has to hit
/// them (033). The look is the Mac's; only the target grows.
enum TouchTarget {
    #if os(iOS)
    static let capsuleVertical: CGFloat = 8
    static let rowVertical: CGFloat = 10
    #else
    static let capsuleVertical: CGFloat = 4
    static let rowVertical: CGFloat = 5
    #endif
}
