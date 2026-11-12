import AgentsKitCore
import SwiftUI

/// The ⌘K command menu (#4787): a field over the window that finds any session, folder, issue
/// or pull request, and any action, as it is typed, each with its shortcut. Up and Down move
/// through what was found, Return does it, Escape (or a click outside) closes it and changes
/// nothing. What it finds, and in what order, is `CommandFinder.matches`; what an item does is
/// the app's (`choose`), so the Remote can draw the same menu with its own items (#4792).
struct CommandMenuView: View {
    /// Every item the menu can find, the nearest first; read again as the app's copy changes.
    let items: [CommandFinder.Item]
    /// The repos the issues and PRs come from, for a ref typed that no item has yet.
    let repos: [String]
    let choose: (CommandFinder.Item) -> Void
    let dismiss: () -> Void

    @State private var term: String
    @State private var selected = 0
    @FocusState private var focused: Bool

    /// `term` is what is typed to start with: the Remote's sidebar search, when the menu is
    /// opened from it on a phone with no keyboard (#4792).
    init(items: [CommandFinder.Item], repos: [String], term: String = "",
         choose: @escaping (CommandFinder.Item) -> Void, dismiss: @escaping () -> Void) {
        self.items = items
        self.repos = repos
        self.choose = choose
        self.dismiss = dismiss
        _term = State(initialValue: term)
    }

    private var found: [CommandFinder.Item] {
        let matched = CommandFinder.matches(items, query: term)
        return matched + CommandFinder.refItems(term, repos: repos, known: matched)
    }

    var body: some View {
        let found = found
        ZStack(alignment: .top) {
            // A click anywhere else closes it, as a menu would.
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                TextField(CommandMenuWords.prompt, text: $term)
                    .textFieldStyle(.plain)
                    .appText(.reading)
                    .focused($focused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { choose(at: selected, in: found) }
                    .onKeyPress(.downArrow) {
                        guard !found.isEmpty else { return .ignored }
                        selected = min(selected + 1, found.count - 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !found.isEmpty else { return .ignored }
                        selected = max(selected - 1, 0)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(CommandMenuWords.label)
                if !found.isEmpty {
                    rows(found)
                } else if !term.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(CommandMenuWords.nothing(term))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.top, 48)
        }
        #if os(macOS)
        .onExitCommand(perform: dismiss)
        #endif
        .onAppear { focused = true }
        .onChange(of: term) { selected = 0 }
    }

    private func rows(_ found: [CommandFinder.Item]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, item in
                        Button { choose(item) } label: { row(item, isSelected: index == selected) }
                            .buttonStyle(.plain)
                            .id(item.id)
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .paperRaised(in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: selected) {
                guard found.indices.contains(selected) else { return }
                proxy.scrollTo(found[selected].id)
            }
        }
    }

    private func row(_ item: CommandFinder.Item, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(item.title)
                .appText(.reading)
                .lineLimit(1)
            if !item.ref.isEmpty, !item.title.hasSuffix(item.ref) {
                Text(item.ref)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            if !item.detail.isEmpty {
                Text(item.detail)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !item.shortcut.isEmpty {
                Text(item.shortcut)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(CommandMenuWords.shortcut(item.shortcut))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.kind.word)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func choose(at index: Int, in found: [CommandFinder.Item]) {
        guard found.indices.contains(index) else { return }
        choose(found[index])
    }
}

/// What the command menu says, once for every client that draws it.
enum CommandMenuWords {
    /// The Go menu's item, ⌘K.
    static let menuItem = "Command Menu…"
    static let prompt = "Find a session, folder, issue or action"
    static let label = "Command menu"
    /// The row at the top of the Remote's sidebar search (#4792): the menu, with no keyboard.
    static func searchRow(_ term: String) -> String {
        "Actions, folders and issues for “\(term.trimmingCharacters(in: .whitespaces))”"
    }
    static func nothing(_ term: String) -> String { "Nothing matches “\(term.trimmingCharacters(in: .whitespaces))”." }
    static func shortcut(_ glyphs: String) -> String { "Shortcut \(glyphs)" }
}

/// One action in the ⌘K command menu (#4787): its row, and what choosing it does. On the Mac the
/// menu bar makes them, as it knows each action's state and key; on the Remote,
/// `RemoteCommandMenu.actions` (#4792).
struct CommandMenuAction {
    let item: CommandFinder.Item
    let perform: @MainActor () -> Void

    /// `listKey` is the session list's single key for it (#4796), shown after the menu's key:
    /// `⌥⌘⌫ · E`.
    init(_ title: String, key: KeyboardShortcut? = nil, listKey: ListKey? = nil, keywords: [String] = [],
         perform: @escaping @MainActor () -> Void) {
        let keys = [key?.glyphs, listKey?.glyph].compactMap { $0 }
        item = CommandFinder.Item(id: "action:\(title)", kind: .action, title: title,
                                shortcut: keys.joined(separator: " · "), keywords: keywords)
        self.perform = perform
    }
}

/// The command menu's issues and pull requests, from the Work lists read so far, for every
/// client that draws it: the Mac window and the Remote (#4792).
@MainActor
enum CommandMenuWork {
    /// The rows the Work list of a kind has read, as items; none before it is read.
    static func items(_ lists: WorkLists, _ kind: WorkList.Kind) -> [CommandFinder.Item] {
        lists[kind].all.map { row in
            CommandFinder.Item(id: "\(kind == .pr ? "pr" : "issue"):\(row.node.ref)", kind: kind == .pr ? .pr : .issue,
                               title: row.title, detail: ReportValueWords.name(.init(kind: "", ref: WorkList.repo(of: row.node.ref))),
                               ref: WorkList.shortRef(row.node.ref))
        }
    }

    /// The repos the read issues and PRs are from, for a ref typed that no item has.
    static func repos(_ lists: WorkLists) -> [String] {
        var seen = Set<String>()
        return (lists[.issue].all + lists[.pr].all)
            .map { WorkList.repo(of: $0.node.ref) }
            .filter { seen.insert($0).inserted }
    }

    /// The Work page an issue or pull request item opens, or nil for any other item.
    static func place(of item: CommandFinder.Item) -> WorkPlace? {
        let (prefix, rest) = CommandMenuID.split(item.id)
        switch prefix {
        case "issue": return WorkPlace(kind: .issue, ref: rest)
        case "pr": return WorkPlace(kind: .pr, ref: rest)
        default: return nil
        }
    }
}

/// An item's id, `kind:rest`, taken apart.
enum CommandMenuID {
    static func split(_ id: String) -> (String, String) {
        guard let colon = id.firstIndex(of: ":") else { return (id, "") }
        return (String(id[..<colon]), String(id[id.index(after: colon)...]))
    }
}

extension KeyboardShortcut {
    /// The shortcut as a menu draws it, `⌥⌘⌫`: the modifiers in the system's order, then the key.
    var glyphs: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.glyph(key)
    }

    private static func glyph(_ key: KeyEquivalent) -> String {
        switch key {
        case .delete: "⌫"
        case .deleteForward: "⌦"
        case .return: "↩"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        default: String(key.character).uppercased()
        }
    }
}
