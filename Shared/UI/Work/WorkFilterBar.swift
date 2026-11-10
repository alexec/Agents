import AgentsKitCore
import SwiftUI

/// Work's filter bar (#4391, parts.md section 4): a wide search field first, then a compact menu
/// per filter. On the Mac and an iPad one row above the list; on a phone the search is the
/// navigation bar's (`.searchable`, which the list adds) and the menus scroll sideways in one row
/// of capsules.
struct WorkFilterBar<Menus: View>: View {
    let kind: WorkList.Kind
    @Binding var text: String
    var compact = false
    @ViewBuilder var menus: Menus

    var body: some View {
        if compact {
            ScrollView(.horizontal) {
                HStack(spacing: 8) { menus }.padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        } else {
            HStack(spacing: 14) {
                WorkSearchField(prompt: WorkLook.searchPrompt(kind), text: $text)
                    .frame(minWidth: 180, maxWidth: .infinity)
                menus
            }
        }
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

    private var isSet: Bool { any.map { selection != $0 } ?? false }

    private var title: String {
        if any == nil { return named ? WorkLook.menuTitle(name, value: words(selection)) : words(selection) }
        return WorkLook.menuTitle(name, value: isSet ? words(selection) : nil)
    }

    var body: some View {
        Menu {
            Picker(name, selection: $selection) {
                if let any {
                    Text(anyWords).tag(any)
                    Divider()
                }
                ForEach(options, id: \.self) { Text(words($0)).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
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
        .menuStyle(.button)
        .buttonStyle(.plain)
        #if os(macOS)
        .menuIndicator(.hidden)
        #endif
        .fixedSize()
        .accessibilityLabel(any == nil ? "\(name): \(words(selection))" : isSet ? "\(name): \(words(selection))" : "\(name): \(anyWords)")
    }
}

/// Refresh, for the toolbar: an arrow that spins while a read runs, ⌘R on the Mac.
struct WorkRefreshButton: View {
    var running = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(running ? 360 : 0))
                .animation(running ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: running)
        }
        .help("Refresh")
        .accessibilityLabel("Refresh")
        .keyboardShortcut("r", modifiers: .command)
    }
}
