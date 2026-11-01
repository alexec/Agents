import AgentsKitCore
import SwiftUI

/// One rule on Agents ▸ Policy (#2957, FR-019, FR-020): your value, and the menu or field to
/// change it; under it, a cap from a layer above with 🔒 and the line that names that layer,
/// "Kept, not used" when your own value is capped, and **Where this comes from**. A menu
/// shows the values looser than the cap dimmed, with the reason. The web page's is in
/// `Web/src/views/settings/AgentsPolicy.tsx`.
struct PolicyRuleRow: View {
    let row: PolicyLayersWords.Row
    /// The machine's effective rule; nil from a machine that does not list it.
    let rule: DaemonAPI.EffectiveRule?
    /// Your layer's value, or nil when you do not set it.
    let yours: JSONValue?
    let editable: Bool
    let set: (JSONValue?) -> Void

    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                control
            } label: {
                Text(row.title)
            }
            if let line = rule?.capLine {
                Label(line, systemImage: "lock.fill")
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rule, PolicyLayersWords.yoursIsKept(rule) {
                Text("\(PolicyLayersWords.keptNotUsed). \(rule.words) applies.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Button(PolicyLayersWords.whereFrom) { showsSource = true }
                .buttonStyle(.borderless)
                .appText(.fine)
                .disabled(rule == nil)
                .popover(isPresented: $showsSource) {
                    if let rule { PolicySourcePopover(row: row, rule: rule) }
                }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var control: some View {
        switch row.kind {
        case .choice(let order):
            menu(order.map { JSONValue.string($0) }) { PolicyLayersWords.choice(row.rule, $0.stringValue ?? "") }
        case .count(let numbers, _):
            menu(countChoices(numbers)) { PolicyLayersWords.count(row.rule, $0.intValue ?? 0) }
        case .money:
            PolicyAmountField(value: yours.flatMap { PolicyLayersWords.amountWords($0) } ?? "", prefix: "$",
                              editable: editable) { text in
                if let value = PolicyLayersWords.moneyValue(text) { set(value) }
            }
        case .tokens:
            PolicyAmountField(value: yours?.intValue.map { "\($0)" } ?? "", prefix: nil, editable: editable) { text in
                if let value = PolicyLayersWords.tokensValue(text) { set(value) }
            }
        case .toggle:
            Toggle(row.title, isOn: Binding(get: { yours?.boolValue ?? true }, set: { set(.bool($0)) }))
                .labelsHidden()
                .disabled(!editable)
        case .list:
            Text(rule?.decides == nil ? row.unset : (rule?.words ?? row.unset))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The numbers a menu offers, and your own value when it is none of them.
    private func countChoices(_ numbers: [Int]) -> [JSONValue] {
        var all = numbers
        if let n = yours?.intValue, !all.contains(n) { all = (all + [n]).sorted() }
        return all.map { .int($0) }
    }

    /// A menu of the rule's values: **Not set** first, which leaves it to the layers above
    /// and the default; a value looser than the cap is dimmed, with the cap's line.
    private func menu(_ values: [JSONValue], words: @escaping (JSONValue) -> String) -> some View {
        Menu {
            Button {
                set(nil)
            } label: {
                if yours == nil { Label(notSetWords, systemImage: "checkmark") } else { Text(notSetWords) }
            }
            Divider()
            ForEach(values, id: \.self) { value in
                let looser = PolicyLayersWords.isLooser(row, value, than: rule?.cap)
                Button {
                    set(value)
                } label: {
                    if yours == value { Label(words(value), systemImage: "checkmark") } else { Text(words(value)) }
                    if looser, let line = rule?.capLine { Text(line) }
                }
                .disabled(looser)
            }
        } label: {
            Text(yours.map(words) ?? notSetWords).lineLimit(1)
        }
        .fixedSize()
        .disabled(!editable)
        .accessibilityLabel(row.title)
        .accessibilityValue(yours.map(words) ?? notSetWords)
    }

    private var notSetWords: String { "\(PolicyLayersWords.notSet) (\(row.unset))" }
}

/// A money or token limit: typed, set on Return; empty is no limit, which is never a zero.
private struct PolicyAmountField: View {
    let value: String
    let prefix: String?
    let editable: Bool
    let save: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            if let prefix { Text(prefix).foregroundStyle(.secondary) }
            TextField("Limit", text: $text, prompt: Text("No limit"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 110)
                .onSubmit { save(text) }
                .disabled(!editable)
        }
        .onAppear { text = value }
        .onChange(of: value) { text = value }
    }
}
