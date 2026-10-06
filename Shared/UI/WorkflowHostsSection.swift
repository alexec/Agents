import AgentsKitCore
import SwiftUI

/// Which computers run this workflow (#317).
///
/// An empty list is every host that has the project. Choosing a computer writes that
/// computer's id into the file. Turning the last one off, or turning Every host on,
/// takes the list out, which is every host again. A computer the control plane does
/// not know still shows, as its id, so a save does not drop it.
struct WorkflowHostsSection: View {
    let choices: [WorkflowHostChoice]
    let hosts: [String]
    var locked: Bool
    let onChange: ([String]) -> Void

    private var rows: [WorkflowHostChoice] {
        let known = Set(choices.map(\.machineID))
        let extras = hosts.filter { !known.contains($0) }.map { WorkflowHostChoice(machineID: $0, name: $0) }
        return choices + extras
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runs on")
                .appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Text("Every host with this project runs it, unless it is pinned to some of them. The file stores each computer's id, so renaming one does not unpin it.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Every host", isOn: Binding(
                get: { hosts.isEmpty },
                set: { on in if on { onChange([]) } }))
                .disabled(locked || hosts.isEmpty)
                .hostPinStyle()
            ForEach(rows) { row in
                Toggle(row.name, isOn: Binding(
                    get: { hosts.contains(row.machineID) },
                    set: { on in
                        let next = on ? hosts + [row.machineID] : hosts.filter { $0 != row.machineID }
                        onChange(next)
                    }))
                    .disabled(locked)
                    .hostPinStyle()
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
