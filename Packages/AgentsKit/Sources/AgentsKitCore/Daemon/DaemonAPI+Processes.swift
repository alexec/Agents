import Foundation

/// What runs on a machine, for its page (#3453): the daemon, each session's runtime and the
/// terminals it asked for, and their children, with the CPU and memory each uses now, and
/// the machine's totals. Asked while the page is open, never kept up to date otherwise.
extension DaemonAPI.Method {
    public static let processesList = "processes/list"
    /// A machine's page (#3626): its CPU and memory now, and every disk its agents write to.
    public static let machineUsage = "machine/usage"
    /// The machine's capacity level now (#4748), asked on connect.
    public static let capacityState = "capacity/state"
}

extension DaemonAPI.Notification {
    /// The machine's capacity level moved (#4748), so its rows say it with no page open.
    public static let capacityChanged = "capacity/changed"
}

extension DaemonAPI {
    /// A machine's capacity (#4578): ok; near (load per core above 1.5, or memory pressure
    /// warn); or full (load per core above 2.5, memory pressure critical, or swap more than
    /// half used).
    public enum CapacityLevel: String, Codable, Hashable, Sendable, CaseIterable {
        case ok, near, full
    }

    /// What capacity/state answers and capacity/changed carries (#4748): the level, and at
    /// near and full the words "this Mac is near capacity".
    public struct CapacityState: Codable, Hashable, Sendable {
        public var level: CapacityLevel
        public var words: String?

        public init(level: CapacityLevel, words: String? = nil) {
            self.level = level
            self.words = words
        }
    }

    /// The kernel's memory pressure (#4578).
    public enum MemoryPressure: String, Codable, Hashable, Sendable, CaseIterable {
        case normal, warn, critical
    }

    /// The whole machine's CPU and memory now, and its capacity as the last look found it.
    public struct MachineUsage: Codable, Hashable, Sendable {
        /// Every core together, 0 to 100.
        public var cpuPercent: Double
        public var cpuCount: Int
        /// Bytes in use, and the bytes the machine has.
        public var memoryUsed: Int64
        public var memoryTotal: Int64
        /// The 1- and 5-minute load averages per core (#4578); nil before the first look.
        public var loadPerCore: Double?
        public var loadPerCore5: Double?
        /// nil when the kernel does not say.
        public var memoryPressure: MemoryPressure?
        /// Swap in use, 0 to 100.
        public var swapUsedPercent: Double?
        public var capacity: CapacityLevel?

        public init(cpuPercent: Double, cpuCount: Int, memoryUsed: Int64, memoryTotal: Int64,
                    loadPerCore: Double? = nil, loadPerCore5: Double? = nil, memoryPressure: MemoryPressure? = nil,
                    swapUsedPercent: Double? = nil, capacity: CapacityLevel? = nil) {
            self.cpuPercent = cpuPercent
            self.cpuCount = cpuCount
            self.memoryUsed = memoryUsed
            self.memoryTotal = memoryTotal
            self.loadPerCore = loadPerCore
            self.loadPerCore5 = loadPerCore5
            self.memoryPressure = memoryPressure
            self.swapUsedPercent = swapUsedPercent
            self.capacity = capacity
        }
    }

    /// One process: the daemon, a session's runtime, or a child of either.
    public struct ProcessUsage: Codable, Hashable, Sendable, Identifiable {
        public var pid: Int
        public var parent: Int
        /// 0 for the daemon; a child is one deeper than its parent.
        public var depth: Int
        public var name: String
        /// Of one core, so more than 100 on several.
        public var cpuPercent: Double
        /// Resident bytes.
        public var memory: Int64
        /// The session whose runtime this is, or whose runtime started it.
        public var agentId: UUID?
        /// That session's title, when it has one.
        public var title: String?

        public var id: Int { pid }

        public init(pid: Int, parent: Int, depth: Int, name: String, cpuPercent: Double, memory: Int64,
                    agentId: UUID? = nil, title: String? = nil) {
            self.pid = pid
            self.parent = parent
            self.depth = depth
            self.name = name
            self.cpuPercent = cpuPercent
            self.memory = memory
            self.agentId = agentId
            self.title = title
        }
    }

    /// What `processes/list` answers: the machine's totals and the daemon's tree, in tree
    /// order, the daemon first. At most 200 processes; `omitted` counts the rest.
    public struct ProcessesState: Codable, Hashable, Sendable {
        public var machine: MachineUsage
        public var processes: [ProcessUsage]
        public var omitted: Int

        public init(machine: MachineUsage, processes: [ProcessUsage] = [], omitted: Int = 0) {
            self.machine = machine
            self.processes = processes
            self.omitted = omitted
        }
    }

    /// What `machine/usage` answers (#3626): the machine's totals, and every volume its
    /// agents write to, ok ones too, the most critical first, then the least free.
    public struct MachineUsageState: Codable, Hashable, Sendable {
        public var machine: MachineUsage
        public var disks: [DiskAlarm]

        public init(machine: MachineUsage, disks: [DiskAlarm] = []) {
            self.machine = machine
            self.disks = disks
        }
    }
}
