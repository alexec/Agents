#if DEBUG && targetEnvironment(simulator)
import UIKit

/// A menu on the Remote's walk socket (#4381): a `Menu`'s button opens its menu, and an item of
/// the open menu runs, as a finger's taps do. A menu's row is a cell that runs nothing when it
/// is selected, so the item's `UIAction` is found in the menu the list draws and sent.
@MainActor
enum WalkMenu {
    // MARK: opening

    /// A control whose primary action is its menu (a toolbar `Menu`'s button): the menu opens,
    /// as at a tap on its middle. UIKit opens one only from a touch, so this is its own
    /// private call, which this Debug walk build alone makes.
    static func open(_ object: NSObject) -> Bool {
        guard let control = object as? UIControl, control.isEnabled, control.showsMenuAsPrimaryAction,
              let interaction = control.contextMenuInteraction else { return false }
        let present = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: present) else { return false }
        typealias Present = @convention(c) (NSObject, Selector, CGPoint) -> Void
        let call = unsafeBitCast(interaction.method(for: present), to: Present.self)
        call(interaction, present, CGPoint(x: control.bounds.midX, y: control.bounds.midY))
        return true
    }

    // MARK: running an item

    /// A row of an open menu, or a view in it (its label): its action runs and the menu
    /// closes. False for anything else.
    static func run(_ object: NSObject) -> Bool {
        var view = object as? UIView
        while let current = view, !(current is UICollectionViewCell) { view = current.superview }
        guard let cell = view as? UICollectionViewCell, let list = cell.superview as? UICollectionView,
              let menu = displayedMenu(above: list) else { return false }
        let title = words(cell)
        // The same title can be in more than one section (Add Folder… per machine): the nth
        // row with it is the nth item with it.
        let rows = list.indexPathsForVisibleItems.sorted().compactMap(list.cellForItem(at:))
        let nth = rows.prefix { $0 !== cell }.filter { same(words($0), title) }.count
        let found = leaves(of: menu).filter { same(title, $0.title) }
        guard found.indices.contains(nth), !found[nth].attributes.contains(.disabled) else { return false }
        closeMenus()
        // An action runs from a control, which a SwiftUI item does not read.
        UIButton().sendAction(found[nth])
        return true
    }

    /// A row's words: those of the first view in it that says any (its content view).
    private static func words(_ view: UIView) -> String {
        let own = WalkAX(object: view).label
        if !own.isEmpty { return own }
        return view.subviews.lazy.map(words).first { !$0.isEmpty } ?? ""
    }

    /// A row's words hold the item's title, and maybe its subtitle after it.
    private static func same(_ row: String, _ title: String) -> Bool {
        !title.isEmpty && (row == title || row.hasPrefix(title + " ") || row.hasPrefix(title + ","))
    }

    /// The menu that a collection view of UIKit's context menu draws: its list view's
    /// `displayedMenu`, a private property, read only by this Debug walk build.
    private static func displayedMenu(above view: UIView) -> UIMenu? {
        let key = NSSelectorFromString("displayedMenu")
        var current: UIView? = view
        while let next = current {
            if NSStringFromClass(type(of: next)).contains("ContextMenu"), next.responds(to: key) {
                return next.value(forKey: "displayedMenu") as? UIMenu
            }
            current = next.superview
        }
        return nil
    }

    /// The actions a menu draws, with those of its sections (inline menus), in their order.
    private static func leaves(of menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let sub = element as? UIMenu, sub.options.contains(.displayInline) { return leaves(of: sub) }
            return []
        }
    }

    /// Every open menu closes, as at a tap on an item.
    private static func closeMenus() {
        func search(_ view: UIView) {
            for case let interaction as UIContextMenuInteraction in view.interactions { interaction.dismissMenu() }
            for sub in view.subviews { search(sub) }
        }
        for window in WalkCommands.windows() { search(window) }
    }
}
#endif
