import Foundation

/// What runs on a machine, for its page (#3453): the daemon, each session's runtime and the
/// terminals it asked for, and their children, with the CPU and memory each uses now, and
/// the machine's totals. Asked while the page is open, never kept up to date otherwise.
extension DaemonAPI.Method {
    public static let processesList = "processes/list"
    /// A machine's page (#3626): its CPU and memory now, and every disk its agents write to.
    public static let machineUsage = "machine/usage"
}

extension DaemonAPI {
    /// The whole machine's CPU and memory now.
    public struct MachineUsage: Codable, Hashable, Sendable {
        /// Every core together, 0 to 100.
        public var cpuPercent: Double
        public var cpuCount: Int
        /// Bytes in use, and the bytes the machine has.
        public var memoryUsed: Int64
        public var memoryTotal: Int64

        public init(cpuPercent: Double, cpuCount: Int, memoryUsed: Int64, memoryTotal: Int64) {
            self.cpuPercent = cpuPercent
            self.cpuCount = cpuCount
            self.memoryUsed = memoryUsed
            self.memoryTotal = memoryTotal
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
