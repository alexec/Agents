import AgentsKitCore
import SwiftUI

/// From, To, the time zone and the days of a window of hours: a workflow's Some hours on
/// Configuration (#4820), and the project's Working hours in Project Settings (#4821).
/// `whose` names what the days belong to in their help: "its" or "the working".
struct HoursWindowControls: View {
    let current: WorkflowHours
    let whose: String
    let write: (WorkflowHours?) -> Void

    var body: some View {
        let window = current.window
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("From", selection: Binding(get: { window?.from }, set: { write(current.starting(at: $0)) })) {
                    Text("All day").tag(Int?.none)
                    ForEach(WorkflowHours.halfHours, id: \.self) { m in
                        Text(WorkflowHours.clockText(m)).tag(Int?.some(m))
                    }
                }
                .fixedSize()
                if let window {
                    Picker("to", selection: Binding(get: { window.to }, set: { write(current.ending(at: $0)) })) {
                        ForEach(WorkflowHours.halfHours.filter { $0 != window.from }, id: \.self) { m in
                            Text(WorkflowHours.clockText(m)).tag(m)
                        }
                    }
                    .fixedSize()
                }
                Picker("Time zone", selection: Binding(get: { current.timeZone }, set: { write(current.inZone($0)) })) {
                    Text("Your time zone").tag(String?.none)
                    Divider()
                    ForEach(WorkflowHours.zones(with: current.timeZone), id: \.self) { zone in
                        Text(zone).tag(String?.some(zone))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            .pickerStyle(.menu)
            HStack(spacing: 4) {
                ForEach(WorkflowHours.shownDays, id: \.self) { day in
                    Toggle(WorkflowHours.dayName(day), isOn: Binding(get: { current.admits(day) },
                                                                     set: { _ in write(current.toggling(day)) }))
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(current.admits(day) ? "Take \(WorkflowHours.dayName(day)) out of \(whose) hours"
                                                  : "Put \(WorkflowHours.dayName(day)) in \(whose) hours")
                }
            }
        }
    }
}
