import AgentsKitCore
import SwiftUI

/// Which computers run this workflow (#317).
///
/// An empty list is every host that has the folder. Choosing a computer writes that
/// computer's id into the file, and each computer chosen runs it (#2064). Turning the last
/// one off, or turning Every host on, takes the ids out, which is every host again. A
/// computer the control plane does not know still shows, as its id, so a save does not drop
/// it. A label that is no computer (a bot, an os) is shown under Also needs and kept.
struct WorkflowHostsSection: View {
    let choices: [WorkflowHostChoice]
    let hosts: [String]
    var locked: Bool
    let onChange: ([String]) -> Void

    private var parts: (machines: [String], needs: [String]) {
        Workflow.runsOnParts(hosts, known: Set(choices.map(\.machineID)))
    }

    private var rows: [WorkflowHostChoice] {
        let known = Set(choices.map(\.machineID))
        let extras = parts.machines.filter { !known.contains($0) }.map { WorkflowHostChoice(machineID: $0, name: $0) }
        return choices + extras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs on")
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text(Workflow.runsOnSentence)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Every machine", isOn: Binding(
                get: { parts.machines.isEmpty },
                set: { on in if on { onChange(parts.needs) } }))
                .disabled(locked || parts.machines.isEmpty)
                .hostPinStyle()
            ForEach(rows) { row in
                Toggle(row.name, isOn: Binding(
                    get: { parts.machines.contains(row.machineID) },
                    set: { on in
                        let (machines, needs) = parts
                        let next = on ? machines + [row.machineID] : machines.filter { $0 != row.machineID }
                        onChange(next + needs)
                    }))
                    .disabled(locked)
                    .hostPinStyle()
            }
            if !parts.needs.isEmpty {
                Text("Also needs: \(parts.needs.joined(separator: ", "))")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    @ViewBuilder func hostPinStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox).appText(.fine)
        #else
        self.toggleStyle(.switch).appText(.reading)
        #endif
    }
}
