import AgentsKitCore
import Foundation

/// The numbers as a machine's page says them, on the Mac and the Remote (#4034).
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

    /// The closed Processes row on a machine's page (#3743): "Processes (12) · 4.5% · 1.2 GB",
    /// what Agents' own processes use together.
    static func processesLine(_ state: DaemonAPI.ProcessesState) -> String {
        let count = state.processes.count + state.omitted
        let cpu = state.processes.reduce(0) { $0 + $1.cpuPercent }
        let memory = state.processes.reduce(Int64(0)) { $0 + $1.memory }
        return "Processes (\(count)) · \(Self.cpu(cpu)) · \(Self.memory(memory))"
    }
}
