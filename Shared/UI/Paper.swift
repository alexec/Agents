import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The app's surfaces: what the page is printed on, and the few ways a thing sits on it.
///
/// The theme is paper, version 2 (`specs/4926-paper-v2/spec.md`). Most of what this app
/// shows is prose — a report, a transcript, a document an agent is writing — so the ground
/// is warm near-white rather than pure white, the ink is a deep charcoal (17:1) rather than
/// pure black, and a list is rows under rules rather than a stack of glass cards. Lines, not
/// shading: a rule sets things apart, nothing on the page casts a shadow, and only what
/// floats over it (a menu, the prompt bar, a toast, a sheet) has a short one. Flat, with
/// light greys one small step from the page, and no gradients.
///
/// `StateTint` still owns the three state colours and `TextStep` the sizes. This owns
/// everything else a surface is drawn in, so no view picks a background of its own.
///
///     TOKEN      LIGHT     DARK      FOR
///     ground     #FCFBF9   #1A1A19   the page every column sits on
///     sidebar    #F8F7F4   #171716   the folders column, one small step from the page
///     raised     #FFFFFF   #212120   cards, the prompt bar, menus, sheets
///     well       #F6F5F2   #262625   what is set into the page: code, your own message
///     wash       #F1F0EC   #2E2E2C   hover; a pressed quiet button
///     rule       #D6D2C9   #3D3D3A   the line that sets things apart, 1.5:1
///     edge       #7D786E   #85817A   a field's, checkbox's or toggle's edge, 3:1 or more
///     ink        #1A1918   #F4F2ED   text, icons
///     secondary  #4A4741   #BDB9B0   second lines, speakers, section headings
///     tertiary   #625E57   #A29E95   timestamps, counts, placeholders
///     accent     #1A52C0   #86B4FF   the icon's cobalt (#156, #695): links, focus, the chosen
///                                    control; `Color.accentColor`, from the asset
///     issue      #0C6278   #73CBE0   a session label naming an issue, `#12` (#2958)
///     pull       #6C3CAE   #BEA3F2   a session label naming a pull request, `P#12` (#2958)
///     line…      pale      deep      a state's line: accent, attention, vouched, failure
///     forge…    GitHub's  own       an item's state on its forge (Work; #4618), below
///
/// `design/tokens.json` holds every value here, and `DesignTokensTests` fails when one
/// differs. Code's ink is `Packages/CodeText/Sources/CodeText/InkValues.swift`'s.
enum Paper {
    static let ground = Color(light: 0xFCFBF9, dark: 0x1A1A19)
    static let sidebar = Color(light: 0xF8F7F4, dark: 0x171716)
    static let raised = Color(light: 0xFFFFFF, dark: 0x212120)
    static let well = Color(light: 0xF6F5F2, dark: 0x262625)
    static let wash = Color(light: 0xF1F0EC, dark: 0x2E2E2C)
    static let rule = Color(light: 0xD6D2C9, dark: 0x3D3D3A)
    /// A control's edge (a field, a checkbox, a toggle's track): 3:1 or more on every
    /// surface, so a control can be found (WCAG 1.4.11). A rule is for setting apart.
    static let edge = Color(light: 0x7D786E, dark: 0x85817A)
    static let ink = Color(light: 0x1A1918, dark: 0xF4F2ED)
    /// Text a step quieter than ink, opaque so it is 4.5:1 or more on every surface, the
    /// selection too: a row's second line, a speaker, a section heading.
    static let secondary = Color(light: 0x4A4741, dark: 0xBDB9B0)
    /// Quieter still, and still 4.5:1 or more: timestamps, counts, placeholders.
    static let tertiary = Color(light: 0x625E57, dark: 0xA29E95)
    /// The picked row, with a bar in the accent at its edge.
    static let selection = Color(light: 0xEBE9E4, dark: 0x363633)
    /// The cobalt, from the asset catalogue rather than a hex here, so a control and
    /// the system's own focus rings and selections agree. The one place a view reaches it.
    static let accent = Color.accentColor
    /// A label chip's hue by what the label names (`SessionLabel.Kind`, #2958): not the
    /// state tints, so a label never reads as a session needing someone or failing.
    static let issue = Color(light: 0x0C6278, dark: 0x73CBE0)
    static let pull = Color(light: 0x6C3CAE, dark: 0xBEA3F2)

    /// A state's line (`design/tokens.json`'s `color.line`): a state shows its colour in
    /// its text, its icon and this line, never in a fill.
    static let lineAccent = Color(light: 0xA9C2EE, dark: 0x3D5687)
    static let lineAttention = Color(light: 0xE3D196, dark: 0x615326)
    static let lineWarning = Color(light: 0xEBBF9F, dark: 0x6B4A33)
    static let lineVouched = Color(light: 0xA9D3BB, dark: 0x36614D)
    static let lineFailure = Color(light: 0xEEB0B3, dark: 0x6B3A3D)

    /// An item's state on its forge, in GitHub's own colours (`specs/4328-work-look/parts.md`,
    /// `design/tokens.json`'s `color.forge`): the forge's state, not the app's, which is
    /// `StateTint`'s. Work draws them; the glyph or the words always go with the colour.
    static let forgeOpen = Color(light: 0x1A7F37, dark: 0x3FB950)
    static let forgeDone = Color(light: 0x8250DF, dark: 0xA371F7)
    static let forgeDraft = Color(light: 0x6E7781, dark: 0x8B949E)
    static let forgeClosed = Color(light: 0xCF222E, dark: 0xF85149)
    /// The forge's amber: an item that waits on someone, a check that still runs.
    static let forgeWaiting = Color(light: 0x9A6700, dark: 0xD29922)
    /// A notice in the amber: its fill and its edge.
    static let forgeWaitingWash = Color(light: 0xFFF8C5, dark: 0x2F2A1A)
    static let forgeWaitingRule = Color(light: 0xD4A72C, dark: 0x6B5A1E)
    /// The near-black disc under a connector's letters (GH, GL) in its set-up sheet.
    static let forgeMark = Color(light: 0x212121, dark: 0x212121)
    /// A state chip's fill under white words, GitHub's state label, as the web page draws it.
    static let forgeFillOpen = Color(light: 0x1F883D, dark: 0x238636)
    static let forgeFillDone = Color(light: 0x8250DF, dark: 0x8957E5)
    static let forgeFillClosed = Color(light: 0xCF222E, dark: 0xDA3633)
    static let forgeFillDraft = Color(light: 0x59636E, dark: 0x6E7681)

    /// Corner radii: code, control (chips, rail), card (rows, wells), and a pill for a
    /// state badge.
    enum Radius {
        static let code: CGFloat = 5
        static let control: CGFloat = 7
        static let card: CGFloat = 10
        static let pill: CGFloat = 99
    }

    /// Depth. Only what floats over the page casts a shadow; cards, buttons and rows have
    /// none, only a rule. The ink's colour in the light, black in the dark.
    struct Shadow {
        let color: Color
        let radius: CGFloat
        let y: CGFloat

        /// Menus, the prompt bar, toasts: `0 4px 12px`, 10% light and 40% dark.
        static let floating = Shadow(color: Color(light: 0x1A1918, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.40),
                                     blur: 12, y: 4)
        /// Sheets and dialogs, over a dimmed page: `0 12px 32px`, 18% light and 55% dark.
        static let sheet = Shadow(color: Color(light: 0x1A1918, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0.55),
                                  blur: 32, y: 12)

        /// A CSS blur is twice SwiftUI's radius.
        init(color: Color, blur: CGFloat, y: CGFloat) {
            self.color = color
            radius = blur / 2
            self.y = y
        }
    }

    /// Keyboard focus: a ring in the accent, `gap` from the control.
    enum Focus {
        static let width: CGFloat = 2
        static let gap: CGFloat = 2
    }
}

extension View {
    /// One of Paper's shadows, for what floats.
    func paperShadow(_ shadow: Paper.Shadow) -> some View {
        self.shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }
}

extension Color {
    /// A colour that follows the appearance. Paper's only constructor, so a hex value
    /// appears nowhere outside this file.
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            return UIColor(hex: isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
        #endif
    }
}

#if os(macOS)
extension NSColor {
    /// Paper for AppKit views that take an `NSColor` rather than a `Color` — the
    /// terminal. Dynamic, like the `Color`s, so the appearance can change under them.
    static let paperGround = NSColor(light: 0xFCFBF9, dark: 0x1A1A19)
    static let paperInk = NSColor(light: 0x1A1918, dark: 0xF4F2ED)
    static let paperSelection = NSColor(light: 0xEBE9E4, dark: 0x363633)

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
extension UIColor {
    /// Paper for the phone's terminal, which takes a `UIColor` (034). The same values
    /// as the Mac's, dynamic in the same way.
    static let paperGround = UIColor(light: 0xFCFBF9, dark: 0x1A1A19)
    static let paperInk = UIColor(light: 0x1A1918, dark: 0xF4F2ED)
    static let paperSelection = UIColor(light: 0xEBE9E4, dark: 0x363633)

    private convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light) }
    }
}

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
    /// translucent, so they already pick up this ground, and a foreground set
    /// here would override the tint every link and control draws in.
    func paperGround() -> some View {
        #if os(macOS)
        // The ground runs on up under the window's toolbar, which draws none of its
        // own. A painted toolbar background is a view of SwiftUI's across the whole
        // title bar, and over the detail it kept the window from being dragged (#456).
        self
            .background(Paper.ground)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #else
        self
            .background(Paper.ground)
            .toolbarBackground(Paper.ground, for: .navigationBar)
        #endif
    }

    /// A thing that floats above the page: raised paper with a rule round it and the
    /// short `floating` shadow. Replaces `.glassEffect(.regular, in:)`.
    func paperRaised(in shape: some InsettableShape) -> some View {
        self
            .background(Paper.raised, in: shape)
            .overlay(shape.strokeBorder(Paper.rule, lineWidth: 1))
            .paperShadow(.floating)
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
    func paperRow(cornerRadius: CGFloat = Paper.Radius.card) -> some View {
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
struct PaperButtonStyle<Outline: InsettableShape>: ButtonStyle {
    let outline: Outline
    /// Dimmed when it can't be used, as the prominent style is: a style of our own does
    /// not get the system's greying.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Paper.wash : Paper.raised, in: outline)
            .overlay(outline.paperButtonEdge(Paper.rule, lineWidth: 1))
            .contentShape(outline)
            .paperTapTarget()
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension InsettableShape {
    /// A paper button's edge (#5236): the stroke inside the shape, half a point in from it.
    /// A button often sits on a half point (a centred label, a card's padding), and the
    /// layer it draws in is cut at whole pixels, so a stroke drawn to the very edge lost
    /// its outer half pixel on the top and leading sides: a 1.5 pt accent edge showed 1 px
    /// there and 1.5 px on the others, as if cut off.
    func paperButtonEdge(_ colour: Color, lineWidth: CGFloat) -> some View {
        inset(by: Paper.buttonEdgeInset).strokeBorder(colour, lineWidth: lineWidth)
    }
}

extension Paper {
    /// How far a button's edge is drawn in from its shape: half a point, which covers the
    /// pixel cut on both a 1x and a 2x screen (#5236).
    static let buttonEdgeInset: CGFloat = 0.5
}

extension EnvironmentValues {
    /// Set on a row of small round paper buttons (a prompt bar's) so that each takes a tap
    /// of at least 44 pt on iOS, the HIG's minimum (#2897). The capsule is drawn at its
    /// own 32 pt; the space around it takes the tap too. The Mac is clicked, so it is unchanged.
    @Entry var paperTapTargets = false
}

extension View {
    /// A tap area of at least 44 pt around the paper button, while `paperTapTargets` is set on iOS.
    fileprivate func paperTapTarget() -> some View {
        modifier(PaperTapTarget())
    }
}

private struct PaperTapTarget: ViewModifier {
    @Environment(\.paperTapTargets) private var isOn

    func body(content: Content) -> some View {
        #if os(iOS)
        if isOn {
            content
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension ButtonStyle where Self == PaperButtonStyle<Capsule> {
    static var paper: Self { PaperButtonStyle(outline: Capsule()) }
}

/// `.paper` with a card's corners rather than round ends, for a button whose label
/// wraps onto several lines: a capsule that tall cuts into the text at its corners.
extension ButtonStyle where Self == PaperButtonStyle<RoundedRectangle> {
    static var paperCard: Self { PaperButtonStyle(outline: RoundedRectangle(cornerRadius: Paper.Radius.card)) }
}

/// The one control on a card that is the answer, and the picked choice in a question
/// card: raised paper, the accent in its text and a 1.5 pt edge, bold (Paper v2, #4977).
/// Colour never fills it: the old accent fill under the ground's colour read as white on
/// a light blue in the dark. Replaces `.buttonStyle(.glassProminent)`.
struct PaperProminentButtonStyle<Outline: InsettableShape>: ButtonStyle {
    let outline: Outline
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Paper.accent)
            .fontWeight(.semibold)
            // `.paper`'s padding, so a prominent button beside plain ones — send next
            // to attach and dictate — is the same size as they are.
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Paper.wash : Paper.raised, in: outline)
            .overlay(outline.paperButtonEdge(Paper.accent, lineWidth: 1.5))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(outline)
            .paperTapTarget()
    }
}

extension ButtonStyle where Self == PaperProminentButtonStyle<Capsule> {
    static var paperProminent: Self { PaperProminentButtonStyle(outline: Capsule()) }
}

/// `.paperProminent` with a card's corners, as `.paperCard` is to `.paper`.
extension ButtonStyle where Self == PaperProminentButtonStyle<RoundedRectangle> {
    static var paperProminentCard: Self {
        PaperProminentButtonStyle(outline: RoundedRectangle(cornerRadius: Paper.Radius.card))
    }
}

extension View {
    /// For buttons that share one Form or List row (#2065). On iOS a tap anywhere in a row with
    /// automatic-style buttons fires every one of them, so here each is borderless and takes only
    /// its own taps. A Mac row takes no taps, so its buttons stay as they are.
    @ViewBuilder func rowButtons() -> some View {
        #if os(macOS)
        self
        #else
        buttonStyle(.borderless)
        #endif
    }

    /// The answer buttons on a sidebar card (join, link, sign-in, cap): small on the Mac, and
    /// at least 44 pt on iOS, so a mis-tap does not deny a machine, a link or a sign-in (#2078).
    @ViewBuilder func cardButtons() -> some View {
        #if os(macOS)
        controlSize(.small)
        #else
        controlSize(.large)
        #endif
    }
}

/// A picked sidebar row (Paper v2, #4977, #4993): the selection grey with a 3px bar in the
/// accent at its leading edge, inset as the system's sidebar selection is. The row's text
/// stays ink. The Mac's sidebar and the Remote's both draw it, in place of the system's
/// accent fill.
struct PaperSelectionRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Paper.Radius.control)
            .fill(Paper.selection)
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: Paper.Radius.control,
                                       bottomLeadingRadius: Paper.Radius.control)
                    .fill(Paper.accent)
                    .frame(width: 3)
            }
            .padding(.horizontal, 10)
    }
}

/// A sheet laid out the same way every time: title, body, then Cancel / primary actions.
struct PaperSheet<Content: View, Actions: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).appText(.reading).fontWeight(.semibold)
            content
            HStack {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(20)
    }
}
