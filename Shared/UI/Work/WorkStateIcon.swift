import AgentsKitCore
import SwiftUI

/// The glyph at the start of a Work row (#4391, parts.md section 1): an issue's or a pull request's
/// state in the forge's colour, with words for a screen reader, so the colour is never the only
/// sign. A milestone or a release, which have no state of their own, show their kind's glyph in grey.
struct WorkStateIcon: View {
    let kind: String
    let state: String
    var draft = false
    /// The forge's `not_planned`, where it gives one: a ring with a slash.
    var stateReason: String?
    /// White, on a fill of the state's colour (the item page's pill, #4400).
    var onFill = false
    /// White on a selected row in a key window, as the row's text.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let glyph = WorkLook.glyph(kind: kind, state: state, draft: draft, stateReason: stateReason) {
            symbol(glyph)
                .foregroundStyle(onFill || prominence == .increased ? Color.white : glyph.tone.color)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(glyph.accessibilityLabel)
        } else {
            Image(systemName: WorkList.Kind(rawValue: kind)?.sidebarIcon ?? "circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func symbol(_ glyph: WorkLook.Glyph) -> some View {
        switch glyph {
        case .issueOpen: Image(systemName: "smallcircle.filled.circle")
        case .issueDone: Image(systemName: "checkmark.circle")
        case .issueNotPlanned: Image(systemName: "slash.circle")
        case .prOpen, .prDraft: Image(systemName: "arrow.triangle.pull")
        case .prMerged: Image(systemName: "arrow.triangle.merge")
        case .prClosed:
            // The branch glyph with a cross: SF Symbols has no one glyph for it.
            Image(systemName: "arrow.triangle.pull")
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "xmark").imageScale(.small).fontWeight(.bold)
                        .padding(1)
                        .background(Circle().fill(Paper.raised))
                        .offset(x: 3, y: 2)
                }
        }
    }
}

extension WorkLook.Tone {
    var color: Color { Color(light: light, dark: dark) }
}

/// A person's avatar (#4391, parts.md section 6). With no image (the wire has none yet, #4363): a
/// circle with the login's first letter on a colour picked from the login, so one person keeps
/// one colour.
struct WorkAvatar: View {
    let login: String
    var side: CGFloat = 20

    var body: some View {
        Circle()
            .fill(Color(hue: WorkLook.avatarHue(login), saturation: 0.45, brightness: 0.78))
            .frame(width: side, height: side)
            .overlay {
                Text(WorkLook.initial(login))
                    // Sized to the circle, not to the text style: a marked decorative glyph.
                    .font(.system(size: side * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Up to three avatars, overlapped, then "+2" (the row's trailing edge).
struct WorkAvatarStack: View {
    let logins: [String]
    var limit = 3

    var body: some View {
        if !logins.isEmpty {
            HStack(spacing: -6) {
                ForEach(logins.prefix(limit), id: \.self) { login in
                    WorkAvatar(login: login).overlay(Circle().strokeBorder(Paper.raised, lineWidth: 1.5))
                }
                if logins.count > limit {
                    Text("+\(logins.count - limit)").appText(.fine).foregroundStyle(.secondary).padding(.leading, 8)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Assigned to \(logins.joined(separator: ", "))")
        }
    }
}

/// A label in its forge's colour (#2956, #4391 parts.md section 3): the colour at a low opacity
/// as its fill, a stronger border, and text that keeps 4.5:1 to the fill (`WorkLook.chip`). With
/// no colour, the grey chip. A scoped label's scope ("feature:") is in the regular weight.
struct WorkLabelChip: View {
    let label: DaemonAPI.ForgeLabel
    /// Sets the list's Label filter (Mac); nil where a chip is not a button.
    var pick: ((String) -> Void)?
    @Environment(\.colorScheme) private var scheme
    /// On a selected row in a key window the chip goes white, as the row's text does (lists.md section 2).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let pick {
            Button { pick(label.name) } label: { chip }
                .buttonStyle(.plain)
                .help("Show only \(label.name)")
        } else {
            chip
        }
    }

    private var chip: some View {
        let white = prominence == .increased
        let colours = white ? nil : WorkLook.chip(label.color, dark: scheme == .dark)
        let text: Color = white ? .white : colours?.text.color ?? .secondary
        let fill: Color = white ? .white.opacity(0.2) : colours?.fill.color ?? Paper.well
        let border: Color = white ? .white.opacity(0.6) : colours?.border.color ?? Paper.rule
        let parts = WorkLook.scoped(label.name)
        var words = Text(parts.rest).fontWeight(.medium)
        if let scope = parts.scope { words = Text("\(Text(scope).fontWeight(.regular))\(words)") }
        return words
            .appText(.fine)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .foregroundStyle(text)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(border))
            // One element with one label: a label stacked on a Text's own crashes AppKit's accessibility.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Label \(label.name)")
    }
}

extension WorkLook.RGB {
    var color: Color { Color(red: r, green: g, blue: b) }
}

/// "+2": the chips a wide row leaves out.
struct WorkMoreChips: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("+\(count)").appText(.fine).foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(count) more labels")
        }
    }
}
