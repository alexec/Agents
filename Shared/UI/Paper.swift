import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's surfaces: what the page is printed on, and the few ways a thing sits on it.
///
/// The theme is paper. Most of what this app shows is prose — a report, a transcript, a
/// document an agent is writing — so the ground is warm off-white rather than a window
/// grey, the ink is near-black rather than pure black, and a list is rows under hairline
/// rules rather than a stack of glass cards. Glass made every row a floating object;
/// on paper a row is a line in a ledger, and the only things that float are the ones
/// that really are on top: the prompt bar, a question, a menu.
///
/// `StateTint` still owns the three state colours and `TextStep` the sizes. This owns
/// everything else a surface is drawn in, so no view picks a background of its own.
///
///     TOKEN     LIGHT     DARK      FOR
///     ground    #FBF9F4   #1C1B19   the page every column sits on
///     sidebar   #F3F0E8   #161513   the projects column, one shade deeper
///     raised    #FFFFFF   #262421   what floats: prompt bar, cards, menus
///     well      #F1EDE4   #2A2825   what is set into the page: code, your own message
///     wash      #ECE7DB   #2F2C28   a row under the pointer, a picked item
///     rule      #E2DCCF   #3A3733   hairlines between rows and round raised things
///     ink       #1F1D1A   #ECE7DC   the prominent button's fill
enum Paper {
    static let ground = Color(light: 0xFBF9F4, dark: 0x1C1B19)
    static let sidebar = Color(light: 0xF3F0E8, dark: 0x161513)
    static let raised = Color(light: 0xFFFFFF, dark: 0x262421)
    static let well = Color(light: 0xF1EDE4, dark: 0x2A2825)
    static let wash = Color(light: 0xECE7DB, dark: 0x2F2C28)
    static let rule = Color(light: 0xE2DCCF, dark: 0x3A3733)
    static let ink = Color(light: 0x1F1D1A, dark: 0xECE7DC)

    /// The shadow under a raised thing. Soft and short: paper lifted a little off the
    /// desk, not a window hovering over it.
    static let shadow = Color(light: 0x3B2F1E, dark: 0x000000).opacity(0.10)
}

extension Color {
    /// A colour that follows the appearance. Paper's only constructor, so a hex value
    /// appears nowhere outside this file.
    init(light: UInt32, dark: UInt32) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
extension NSColor {
    /// Paper for AppKit views that take an `NSColor` rather than a `Color` — the
    /// terminal. Dynamic, like the `Color`s, so the appearance can change under them.
    static let paperGround = NSColor(light: 0xFBF9F4, dark: 0x1C1B19)
    static let paperInk = NSColor(light: 0x1F1D1A, dark: 0xECE7DC)
    static let paperSelection = NSColor(light: 0xE4DCC8, dark: 0x3A3630)

    private convenience init(light: UInt32, dark: UInt32) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif

extension View {
    /// The page: ground under the whole column and under the toolbar above it.
    ///
    /// No foreground is set. The system's secondary and tertiary label colours are
    /// translucent, so they already come out warm on this ground, and a foreground set
    /// here would override the tint every link and control draws in.
    func paperGround() -> some View {
        #if os(macOS)
        self
            .background(Paper.ground)
            .toolbarBackground(Paper.ground, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        #else
        self
            .background(Paper.ground)
            .toolbarBackground(Paper.ground, for: .navigationBar)
        #endif
    }

    /// A thing that floats above the page: raised paper with a hairline edge and a
    /// short shadow. Replaces `.glassEffect(.regular, in:)`.
    func paperRaised(in shape: some InsettableShape) -> some View {
        self
            .background(Paper.raised, in: shape)
            .overlay(shape.strokeBorder(Paper.rule, lineWidth: 1))
            .shadow(color: Paper.shadow, radius: 6, y: 2)
    }

    /// Something set into the page: a code block, your own message, a diff.
    /// Replaces `.background(.quaternary.opacity(…), in:)`.
    func paperWell(in shape: some Shape) -> some View {
        background(Paper.well, in: shape)
    }

    /// A sheet: the same ground as the page it came from, so opening one is turning to
    /// another page rather than a system window appearing over paper.
    func paperSheet() -> some View {
        paperGround().presentationBackground(Paper.ground)
    }

    /// A popover: raised paper, as everything else that floats is.
    func paperPopover() -> some View {
        presentationBackground(Paper.raised)
    }

    /// A settings form: grouped as before, on the ground, its sections on raised paper
    /// rather than the system's cool fill.
    func paperForm() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
    }

    /// A row in a system `List`, where the list rather than the row draws the fill.
    /// Raised paper, which is what a grouped cell is: a card set on the page.
    func paperListRow() -> some View {
        listRowBackground(Paper.raised)
    }

    /// A row in a list you can go into: no fill until the pointer is on it, and a
    /// hairline under it. Replaces the interactive glass card.
    func paperRow(cornerRadius: CGFloat = 10) -> some View {
        modifier(PaperRow(cornerRadius: cornerRadius))
    }
}

private struct PaperRow: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Paper.wash : .clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Paper.rule)
                    .frame(height: 1)
                    .padding(.horizontal, cornerRadius)
                    .opacity(isHovered ? 0 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A small control on paper: raised capsule, hairline edge, a wash while pressed.
/// Replaces `.buttonStyle(.glass)`.
struct PaperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Paper.wash : Paper.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(Paper.rule, lineWidth: 1))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
}

/// The one control on a card that is the answer: ink on paper turned over, so the
/// ground becomes the text. Replaces `.buttonStyle(.glassProminent)`.
struct PaperProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Paper.ground)
            // `.paper`'s padding, so a prominent button beside plain ones — send next
            // to attach and dictate — is the same size as they are.
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            // Inside `.paper`'s hairline rather than out to where it is drawn. The same
            // outer size filled edge to edge reads a size larger than a button whose
            // edge is a line, and send sat beside two of those looking wider than them.
            .background(Paper.ink.opacity(configuration.isPressed ? 0.8 : 1),
                        in: Capsule().inset(by: 1))
            .overlay(Capsule().strokeBorder(Paper.rule, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PaperProminentButtonStyle {
    static var paperProminent: PaperProminentButtonStyle { PaperProminentButtonStyle() }
}
