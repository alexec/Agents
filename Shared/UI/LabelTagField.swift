import AgentsKitCore
import SwiftUI

/// A session's labels as one tag input, the same on the Mac and the phone (070).
///
/// The labels sit as chips in front of a text field. A comma finishes what was typed
/// into a label, as does Return. Delete at the start of the field removes the label
/// just before the cursor; the left arrow moves the cursor onto the labels, and Delete
/// then removes the one it is on. Each chip also has its own remove button, for a
/// pointer or a finger.
struct LabelTagField: View {
    let labels: [SessionLabel]
    var suggestions: [String] = []
    let add: ([String]) -> Void
    let remove: (String) -> Void
    /// Opened from a folded line (#1107): the field takes the focus at once, and
    /// `onEndEditing` is called when it loses it.
    var focusFirst = false
    var onEndEditing: (() -> Void)?

    @State private var text = ""
    @State private var selection: TextSelection?
    /// The chip the cursor is on, when the arrows have moved it off the field.
    @State private var chosen: Int?
    @FocusState private var focused: Bool

    private var hasRoom: Bool { labels.count < SessionLabelPolicy.maximumCount }

    var body: some View {
        WrappingHStack(spacing: 5) {
            ForEach(Array(labels.enumerated()), id: \.element.normalizedValue) { index, label in
                chip(label, isChosen: focused && chosen == index)
            }
            if hasRoom || chosen != nil {
                field
            }
            #if os(iOS)
            // The Mac offers these under the field as it is typed in; iOS has no such
            // list, so they follow it as chips while it is being typed in.
            if focused {
                ForEach(matchingSuggestions.prefix(4), id: \.self) { value in
                    Button("+ \(value)") { commit([value]); text = "" }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                }
            }
            #endif
        }
        .appText(.fine)
        .onAppear { if focusFirst { focused = true } }
    }

    private var field: some View {
        TextField(labels.isEmpty ? "Add labels" : placeholderAfterLabels, text: $text, selection: $selection)
            .textFieldStyle(.plain)
            .focused($focused)
            .frame(width: fieldWidth)
            .padding(.vertical, 3)
            .suggesting(matchingSuggestions)
            .onChange(of: text) {
                chosen = nil
                let typed = SessionLabelPolicy.split(typed: text)
                guard !typed.finished.isEmpty else { return }
                text = typed.remainder
                commit(typed.finished)
            }
            .onSubmit {
                commit([text])
                text = ""
                focused = true
            }
            .onChange(of: focused) {
                guard !focused else { return }
                chosen = nil
                commit([text])
                text = ""
                onEndEditing?()
            }
            .onKeyPress(.delete) { removeAtCursor() }
            .onKeyPress(.deleteForward) {
                guard let chosen else { return .ignored }
                removeChosen(chosen)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                if let index = chosen {
                    chosen = max(0, index - 1)
                    return .handled
                }
                guard cursorAtStart, !labels.isEmpty else { return .ignored }
                chosen = labels.count - 1
                return .handled
            }
            .onKeyPress(.rightArrow) {
                guard let index = chosen else { return .ignored }
                chosen = index + 1 < labels.count ? index + 1 : nil
                return .handled
            }
            .onKeyPress(.escape) {
                guard chosen != nil else { return .ignored }
                chosen = nil
                return .handled
            }
            .accessibilityLabel("Add label")
            .accessibilityHint("Type a comma to finish a label.")
    }

    private func chip(_ label: SessionLabel, isChosen: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label.value)
            Button {
                remove(label.value)
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .accessibilityLabel("Remove \(label.value)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .labelChip(label, isChosen: isChosen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label.value), \(label.owner.rawValue) label")
        .accessibilityAction(named: "Remove") { remove(label.value) }
    }

    /// On a phone the empty field beside labels is only room to tap, so it does not wrap
    /// the row onto a line of its own; it widens while it is typed in (#670).
    private var fieldWidth: CGFloat {
        #if os(iOS)
        labels.isEmpty || focused ? 120 : 44
        #else
        120
        #endif
    }

    private var placeholderAfterLabels: String {
        #if os(iOS)
        "Add"
        #else
        ""
        #endif
    }

    private var cursorAtStart: Bool {
        if text.isEmpty { return true }
        guard case .selection(let range) = selection?.indices else { return false }
        return range.isEmpty && range.lowerBound == text.startIndex
    }

    private var matchingSuggestions: [String] {
        guard hasRoom else { return [] }
        let used = Set(labels.map(\.normalizedValue))
        let typed = SessionLabelPolicy.key(text)
        return suggestions.filter {
            let key = SessionLabelPolicy.key($0)
            return !used.contains(key) && (typed.isEmpty || key.hasPrefix(typed))
        }
    }

    private func removeAtCursor() -> KeyPress.Result {
        if let chosen {
            removeChosen(chosen)
            return .handled
        }
        guard cursorAtStart, let last = labels.last else { return .ignored }
        remove(last.value)
        return .handled
    }

    /// Back to the field after removing the chip it was on, so typing carries on.
    private func removeChosen(_ index: Int) {
        guard labels.indices.contains(index) else { chosen = nil; return }
        remove(labels[index].value)
        chosen = nil
    }

    private func commit(_ typed: [String]) {
        let values = SessionLabelPolicy.accepted(typed, existing: labels.map(\.value))
        if !values.isEmpty { add(values) }
    }
}

private extension View {
    @ViewBuilder func suggesting(_ values: [String]) -> some View {
        #if os(macOS)
        textInputSuggestions {
            ForEach(values, id: \.self) { value in
                Text(value).textInputCompletion(value)
            }
        }
        #else
        self
        #endif
    }
}

/// One label where it is only shown: a card or a row, which open the chat to change it.
struct LabelChip: View {
    let label: SessionLabel

    var body: some View {
        Text(label.value)
            .appText(.fine)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .labelChip(label)
            .accessibilityLabel("\(label.value), \(label.owner.rawValue) label")
    }
}

/// A label chip's colours (#2958). What the label names gives the hue: an issue and a pull
/// request their own, finished work grey, anything else the accent. Who added it gives the
/// fill: the person's labels are filled, the agent's only outlined.
private extension View {
    func labelChip(_ label: SessionLabel, isChosen: Bool = false) -> some View {
        let hue: Color = switch label.kind {
        case .issue: Paper.issue
        case .pullRequest: Paper.pull
        case .finished: .secondary
        case .plain: Paper.accent
        }
        let fill = isChosen ? hue.opacity(0.35) : label.owner == .person ? hue.opacity(0.16) : .clear
        return foregroundStyle(label.kind == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(hue))
            .background(fill)
            // On the page's paper first (#3196): a chip over the transcript (the prompt
            // bar's row) let its words show through the tint, or through nothing at all
            // for an agent's label.
            .background(Paper.ground)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(hue.opacity(isChosen ? 1 : 0.5)))
    }
}
