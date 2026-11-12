import AgentsKitCore
import SwiftUI

/// Work's filter bar (#4391, parts.md section 4; lists.md section 1): a search field first, then
/// a compact menu per filter, and Sort at the trailing edge. On the Mac and an iPad one row above
/// the list: when it does not fit, the search field gets shorter, then the menus with no value
/// set go into More. On a phone the search is the navigation bar's (`.searchable`, which the
/// list adds) and the menus scroll sideways in one row of capsules.
struct WorkFilterBar<Menus: View, More: View, Trailing: View>: View {
    let kind: WorkList.Kind
    @Binding var text: String
    var compact = false
    /// The menus in the bar; `folded` leaves out those with no value set, which `more` has.
    @ViewBuilder var menus: (_ folded: Bool) -> Menus
    /// The menus with no value set, as the items of More.
    @ViewBuilder var more: () -> More
    /// Sort, at the trailing edge.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if compact {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    menus(false)
                    trailing()
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        } else {
            ViewThatFits(in: .horizontal) {
                line(search: WorkLook.filterBarSearch.wide, folded: false)
                line(search: WorkLook.filterBarSearch.short, folded: false)
                line(search: WorkLook.filterBarSearch.short, folded: true)
            }
        }
    }

    private func line(search: Double, folded: Bool) -> some View {
        HStack(spacing: 14) {
            WorkSearchField(prompt: WorkLook.searchPrompt(kind), text: $text)
                .frame(width: search)
            menus(folded)
            if folded {
                Menu { more() } label: { WorkMenuLabel(title: "More", isSet: false) }
                    .modifier(WorkMenuStyle())
                    .accessibilityLabel("More filters")
            }
            Spacer(minLength: 14)
            trailing()
        }
    }
}

/// A menu's words and its chevron ("Label ▾"), in the accent when it is set.
struct WorkMenuLabel: View {
    let title: String
    let isSet: Bool
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").imageScale(.small).fontWeight(.semibold).accessibilityHidden(true)
        }
        .appText(.supporting)
        .foregroundStyle(isSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .padding(.horizontal, compact ? 12 : 0)
        .padding(.vertical, compact ? 6 : 0)
        .background {
            if compact { Capsule().fill(isSet ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(Paper.well)) }
        }
        .contentShape(Capsule())
    }
}

/// The filter bar's menus as words, with no button's border or indicator.
struct WorkMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .menuStyle(.button)
            .buttonStyle(.plain)
            #if os(macOS)
            .menuIndicator(.hidden)
            #endif
            .fixedSize()
    }
}

/// Clear (lists.md section 1): after the last filter while one other than State is set; it
/// clears the search text and every menu but State and Sort.
struct WorkClearButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(WorkLook.clear, systemImage: "xmark").labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .appText(.supporting)
        .foregroundStyle(.secondary)
        .help("Clear the search and the filters")
        .fixedSize()
    }
}

/// The search field: a magnifying glass, the words, and a clear button while it has words.
struct WorkSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.control).fill(Paper.raised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.control).strokeBorder(Paper.rule))
    }
}

/// One filter as a compact menu: its name and a chevron while it is not set ("Label ▾"); its
/// name and value in the accent when it is ("Label: bug ▾"), with `any` at the top to clear it.
/// With no `any` it shows its value at all times, as State does ("Open ▾"). On a phone, a capsule.
struct WorkFilterMenu<Option: Hashable>: View {
    let name: String
    @Binding var selection: Option
    let options: [Option]
    let words: (Option) -> String
    /// The choice that clears it ("Any", "All"), first in the menu; nil for a filter that always has a value.
    var any: Option?
    var anyWords = "Any"
    var compact = false
    /// A filter that always has a value says its name too ("Sort: Newest"); State says only its value.
    var named = false
    /// An item of More: a submenu by its name alone.
    var inMore = false

    private var isSet: Bool { any.map { selection != $0 } ?? false }

    private var title: String {
        if any == nil { return named ? WorkLook.menuTitle(name, value: words(selection)) : words(selection) }
        return WorkLook.menuTitle(name, value: isSet ? words(selection) : nil)
    }

    var body: some View {
        if inMore {
            Menu(name) { picker }
        } else {
            Menu { picker } label: { WorkMenuLabel(title: title, isSet: isSet, compact: compact) }
                .modifier(WorkMenuStyle())
                .accessibilityLabel(any == nil ? "\(name): \(words(selection))" : isSet ? "\(name): \(words(selection))" : "\(name): \(anyWords)")
        }
    }

    private var picker: some View {
        Picker(name, selection: $selection) {
            if let any {
                Text(anyWords).tag(any)
                Divider()
            }
            ForEach(options, id: \.self) { Text(words($0)).tag($0) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Refresh, for the toolbar: the standard two-arrow circle, which turns about its own centre while a read
/// runs, ⌘R on the Mac. A one-arrow `arrow.clockwise` read as Redo, and a `rotationEffect` on it turned
/// about the frame, not the glyph, so it wobbled.
struct WorkRefreshButton: View {
    var running = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, isActive: running)
        }
        .help("Refresh")
        .accessibilityLabel("Refresh")
        .keyboardShortcut("r", modifiers: .command)
    }
}
