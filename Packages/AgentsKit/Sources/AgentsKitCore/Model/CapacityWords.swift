import Foundation

/// A machine's capacity in words (#4582), as its page says it: the load and the level in the
/// summary, a line that warns at near and full, and the starts that wait. The level and its
/// signals come from `machine/usage` (#4578). The web page's model/capacity.ts says the same.
public enum CapacityWords {
    /// "Load 2.4 per core", in the summary.
    public static func load(_ perCore: Double) -> String {
        "Load \(String(format: "%.1f", perCore)) per core"
    }

    /// "Near capacity" or "At capacity"; nil at ok, where the summary says nothing of it.
    public static func level(_ level: DaemonAPI.CapacityLevel?) -> String? {
        switch level {
        case .near: "Near capacity"
        case .full: "At capacity"
        case .ok, nil: nil
        }
    }

    /// The warning at near and full: "This Mac is near capacity: load 2.4 per core." Nil at ok.
    /// The daemon's machine.busy says the same sentence.
    public static func warning(_ usage: DaemonAPI.MachineUsage, name: String) -> String? {
        let words: String
        switch usage.capacity {
        case .near: words = "near capacity"
        case .full: words = "at capacity"
        case .ok, nil: return nil
        }
        return "\(name) is \(words): \(signal(usage))."
    }

    /// What put it there, as machine.busy names it: the signal over the level's line, the
    /// load when none is (the level falls only after two looks under its lines).
    static func signal(_ usage: DaemonAPI.MachineUsage) -> String {
        let load = usage.loadPerCore ?? 0
        let swap = usage.swapUsedPercent ?? 0
        let pressure = "memory pressure \(usage.memoryPressure?.rawValue ?? "unknown")"
        let swapWords = "swap \(Int(swap.rounded()))% used"
        if usage.capacity == .full {
            if usage.memoryPressure == .critical { return pressure }
            if swap > 50, load <= 2.5 { return swapWords }
        } else if usage.memoryPressure == .warn, load <= 1.5 {
            return pressure
        }
        return "load \(String(format: "%.1f", load)) per core"
    }

    /// Every signal, for the summary's tooltip: "Load 2.4 per core over 1 minute, 2.1 over 5 ·
    /// Memory pressure normal · Swap 3% used". Nil before the first look.
    public static func detail(_ usage: DaemonAPI.MachineUsage) -> String? {
        guard let load = usage.loadPerCore else { return nil }
        var parts = ["\(Self.load(load)) over 1 minute"
            + (usage.loadPerCore5.map { ", \(String(format: "%.1f", $0)) over 5" } ?? "")]
        if let pressure = usage.memoryPressure { parts.append("Memory pressure \(pressure.rawValue)") }
        if let swap = usage.swapUsedPercent { parts.append("Swap \(Int(swap.rounded()))% used") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "2 starts queued": the sessions on the machine that wait for a place (#4377). Nil at none.
    public static func queued(_ count: Int) -> String? {
        count == 0 ? nil : "\(count) \(count == 1 ? "start" : "starts") queued"
    }
}
