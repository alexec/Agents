import AgentsKitCore
import SwiftUI

/// What runs on a machine (#3453): its CPU and memory, then the daemon, each session's
/// runtime and their children, with the CPU and memory each uses now. Read with
/// `processes/list` when it opens and every few seconds while it is open, never otherwise.
/// A session's row opens its chat. Settings ▸ Machines ▸ This Mac draws it for this Mac, and
/// a machine's Processes… for any other; the web page draws the same in
/// Web/src/views/settings/Processes.tsx.
struct MachineProcessesSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let client: DaemonClient
    let hostName: String
    /// What opening a session does first, as a sheet closing.
    var opened: () -> Void = {}

    @State private var state: DaemonAPI.ProcessesState?
    @State private var failure: String?

    var body: some View {
        Section {
            if let state {
                LabeledContent("CPU", value: ProcessWords.machineCPU(state.machine))
                LabeledContent("Memory", value: ProcessWords.machineMemory(state.machine))
                ForEach(state.processes) { process in
                    row(process)
                }
                if state.omitted > 0 {
                    Text("And \(state.omitted) more.").foregroundStyle(.secondary)
                }
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        } header: {
            Text("Processes on \(hostName)")
        } footer: {
            Text("Agents’ own processes only. Stop a session to stop its processes.")
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                await read()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func row(_ process: DaemonAPI.ProcessUsage) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).lineLimit(1)
                if process.depth == 0 {
                    Text("Agents’ daemon").appText(.supporting).foregroundStyle(.secondary)
                } else if let agent = process.agentId, process.isSessionsOwn(in: state?.processes ?? []) {
                    Button(process.title ?? "Untitled session") {
                        opened()
                        model.showInMainWindow(agent, opening: openWindow)
                    }
                    .buttonStyle(.link)
                    .appText(.supporting)
                }
            }
            .padding(.leading, CGFloat(min(process.depth, 6)) * 14)
            Spacer()
            Text(ProcessWords.cpu(process.cpuPercent))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(ProcessWords.memory(process.memory))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .help("Process \(process.pid)")
    }

    private func read() async {
        do {
            state = try await client.call(DaemonAPI.Method.processesList, DaemonAPI.Empty(),
                                          returning: DaemonAPI.ProcessesState.self)
            failure = nil
        } catch let error as JSONRPCError {
            failure = error.message
        } catch {
            failure = "\(hostName) can’t be asked now: \(error.localizedDescription)"
        }
    }
}

extension DaemonAPI.ProcessUsage {
    /// Whether this is the top of a session's processes (its runtime or a terminal), not a
    /// child of one: only that row names the session.
    func isSessionsOwn(in all: [DaemonAPI.ProcessUsage]) -> Bool {
        guard let agentId else { return false }
        return all.first { $0.pid == parent }?.agentId != agentId
    }
}

/// The numbers as the page says them.
enum ProcessWords {
    static func cpu(_ percent: Double) -> String {
        percent < 0.05 ? "0%" : percent < 10 ? String(format: "%.1f%%", percent) : "\(Int(percent.rounded()))%"
    }

    /// Resident memory, in the units Activity Monitor uses (1 GB is 1024 MB).
    static func memory(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var n = Double(bytes)
        var unit = 0
        while n >= 1024, unit < units.count - 1 {
            n /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) bytes" }
        return "\(n < 10 ? String(format: "%.1f", n) : String(Int(n.rounded()))) \(units[unit])"
    }

    static func machineCPU(_ machine: DaemonAPI.MachineUsage) -> String {
        "\(cpu(machine.cpuPercent)) of \(machine.cpuCount) \(machine.cpuCount == 1 ? "core" : "cores")"
    }

    static func machineMemory(_ machine: DaemonAPI.MachineUsage) -> String {
        "\(memory(machine.memoryUsed)) of \(memory(machine.memoryTotal))"
    }
}

/// A machine's processes (#3453), from its menu in Settings ▸ Machines.
struct MachineProcessesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: DaemonAPI.ControlMachine

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                MachineProcessesSection(client: model.client(for: host.id), hostName: host.name, opened: { dismiss() })
            }
            .paperForm()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding()
        }
        .frame(width: 560, height: 560)
    }
}
