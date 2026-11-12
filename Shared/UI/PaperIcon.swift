import SwiftUI

/// Paper v2's one icon set (#4976; specs/4926-paper-v2/spec.md, Icons): Lucide at a 1.5 stroke.
///
/// The model still names an icon by its SF Symbol, as it did before; a view draws it with
/// `Image(icon:)`, `Label(_:icon:)` or `Button(_:icon:action:)`, and on the Mac that draws the
/// Lucide symbol of the same meaning from Icons.xcassets (`design/icons.json`, made by
/// `scripts/design.sh icons`). Each is a symbol image, so it takes the text's size, scale and
/// colour as an SF Symbol does. A name with no Lucide meaning yet draws its SF Symbol.
///
/// The Remote draws the SF Symbols until its own story (#4996) turns them on there.
enum PaperIcon {
    /// The Lucide symbol to draw for an SF Symbol's name, or nil to draw the SF Symbol.
    static func lucide(_ systemName: String) -> String? {
        #if os(macOS)
        LucideIcons.bySystemName[systemName]
        #else
        nil
        #endif
    }
}

extension Image {
    /// The icon for an SF Symbol's name: on the Mac, its Lucide symbol (#4976).
    init(icon systemName: String) {
        if let name = PaperIcon.lucide(systemName) {
            self.init(name)
        } else {
            self.init(systemName: systemName)
        }
    }
}

extension Image {
    /// The icon for an SF Symbol's name in a window's toolbar (#4976). AppKit draws a toolbar
    /// item from an `NSImage`, and it draws a symbol image from an asset catalogue empty
    /// (macOS 27), so on the Mac this hands it Lucide's symbol as an `NSImage`, at the size
    /// a toolbar draws an SF Symbol. Not for a view: that image keeps its size whatever the font.
    init(toolbarIcon systemName: String) {
        #if os(macOS)
        if let name = PaperIcon.lucide(systemName),
           let image = NSImage(named: name)?.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) {
            self.init(nsImage: image)
            return
        }
        #endif
        self.init(systemName: systemName)
    }
}

extension Label where Title == Text, Icon == Image {
    /// A toolbar item's label with the icon for an SF Symbol's name: see `Image(toolbarIcon:)`.
    init(_ titleKey: LocalizedStringKey, toolbarIcon systemName: String) {
        self.init { Text(titleKey) } icon: { Image(toolbarIcon: systemName) }
    }

    /// A toolbar item's label with the icon for an SF Symbol's name: see `Image(toolbarIcon:)`.
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, toolbarIcon systemName: String) {
        self.init { Text(title) } icon: { Image(toolbarIcon: systemName) }
    }

    /// A label with the icon for an SF Symbol's name (#4976).
    init(_ titleKey: LocalizedStringKey, icon systemName: String) {
        self.init { Text(titleKey) } icon: { Image(icon: systemName) }
    }

    /// A label with the icon for an SF Symbol's name (#4976).
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon systemName: String) {
        self.init { Text(title) } icon: { Image(icon: systemName) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    /// A toolbar button with a title and the icon for an SF Symbol's name: see `Image(toolbarIcon:)`.
    @preconcurrency nonisolated init(_ titleKey: LocalizedStringKey, toolbarIcon systemName: String,
                                     role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, toolbarIcon: systemName) }
    }

    /// A button with a title and the icon for an SF Symbol's name (#4976).
    @preconcurrency nonisolated init(_ titleKey: LocalizedStringKey, icon systemName: String, role: ButtonRole? = nil,
         action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, icon: systemName) }
    }

    /// A button with a title and the icon for an SF Symbol's name (#4976).
    @_disfavoredOverload @preconcurrency nonisolated
    init<S: StringProtocol>(_ title: S, icon systemName: String, role: ButtonRole? = nil,
                            action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: systemName) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    /// A menu with a title and the icon for an SF Symbol's name (#4976).
    init(_ titleKey: LocalizedStringKey, icon systemName: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(titleKey, icon: systemName) }
    }

    /// A menu with a title and the icon for an SF Symbol's name (#4976).
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon systemName: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, icon: systemName) }
    }
}

extension Toggle where Label == SwiftUI.Label<Text, Image> {
    /// A toggle with a title and the icon for an SF Symbol's name (#4976).
    init(_ titleKey: LocalizedStringKey, icon systemName: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI.Label(titleKey, icon: systemName) }
    }

    /// A toggle with a title and the icon for an SF Symbol's name (#4976).
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon systemName: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { SwiftUI.Label(title, icon: systemName) }
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    /// An empty state with the icon for an SF Symbol's name (#4976).
    init(_ titleKey: LocalizedStringKey, icon systemName: String, description: Text? = nil) {
        self.init { SwiftUI.Label(titleKey, icon: systemName) } description: { description }
    }

    /// An empty state with the icon for an SF Symbol's name (#4976).
    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon systemName: String, description: Text? = nil) {
        self.init { SwiftUI.Label(title, icon: systemName) } description: { description }
    }
}
