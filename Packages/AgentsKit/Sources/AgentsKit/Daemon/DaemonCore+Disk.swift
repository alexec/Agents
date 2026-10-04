import Foundation
import AgentsKitCore

/// Free space on the volumes the app writes to (#195): `mac.disk_low` and `mac.disk_ok`,
/// and the window's strip.
///
/// On 2026-10-03 the Mac's disk filled with agents' worktrees, every agent then failed
/// on every command, and nothing said so until a person noticed. Now the volumes that
/// hold the Agents root, the projects and their worktrees are looked at once a minute
/// and after each lease is given back, and a crossing is raised once, both ways.
extension DaemonCore {
    /// Start looking. The real reader in the daemon; a test hands in its own and calls
    /// `checkDiskSpace` itself rather than waiting a minute.
    public func startWatchingDisk(every interval: Duration = DiskSpace.interval) {
        diskTicker?.cancel()
        diskTicker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkDiskSpace()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopWatchingDisk() {
        diskTicker?.cancel()
        diskTicker = nil
    }

    /// A test's own reader: what every folder's volume says.
    func useDiskReader(_ reader: @escaping @Sendable (URL) -> DiskReading?) {
        diskReader = reader
    }

    /// A look soon, after a lease was given back or the Mac woke: one look for a burst.
    func scheduleDiskCheck() {
        guard diskTicker != nil, diskCheckSoon == nil else { return }
        diskCheckSoon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.diskCheckDone()
        }
    }

    private func diskCheckDone() async {
        await checkDiskSpace()
        diskCheckSoon = nil
    }

    /// The folders whose volumes matter, each with the project whose settings it goes by
    /// (nil for the Agents root itself).
    func diskFolders() -> [(folder: URL, project: URL?)] {
        var folders: [(URL, URL?)] = [(locations.root, nil)]
        for project in allProjects(includeArchived: false) where project.exists {
            folders.append((project.folder, project.folder))
        }
        for agent in agents.values where agent.state != .archived {
            if let worktree = agent.worktree { folders.append((worktree.root, agent.projectFolder)) }
        }
        return folders
    }

    /// Look at every volume once, and raise what crossed.
    func checkDiskSpace() async {
        loadEventsIfNeeded()
        let folders = diskFolders()
        let reader = diskReader
        let override = diskOverride()
        // Off the actor: a volume's important-usage figure can take a moment to work out.
        let readings: [(URL?, DiskReading)] = await Task.detached {
            folders.compactMap { folder, project in
                guard var reading = reader(folder) else { return nil }
                if let override { reading.freeBytes = min(override, reading.totalBytes) }
                return (project, reading)
            }
        }.value
        var byMount: [String: (reading: DiskReading, projects: Set<URL>)] = [:]
        for (project, reading) in readings {
            var entry = byMount[reading.mount] ?? (reading, [])
            if let project { entry.projects.insert(project) }
            byMount[reading.mount] = entry
        }
        var levels = eventState.diskLevels ?? [:]
        var alarms = diskAlarms
        for (mount, entry) in byMount.sorted(by: { $0.key < $1.key }) {
            let thresholds = DiskThresholds.strictest(entry.projects.sorted { $0.path < $1.path }
                .compactMap { configuredDiskSpace(in: $0) })
            let before = levels[mount].flatMap(DiskLevel.init(rawValue:))
            let (level, crossing) = DiskSpace.next(from: before, entry.reading, thresholds)
            levels[mount] = level.rawValue
            switch crossing {
            case .low(let level, let threshold):
                let worktrees = await largestWorktrees(on: mount, among: entry.projects)
                let alarm = DiskAlarm(reading: entry.reading, level: level, threshold: threshold, worktrees: worktrees)
                alarms[mount] = alarm
                raiseDiskLow(alarm)
            case .ok(let threshold):
                alarms[mount] = nil
                raiseDiskOK(entry.reading, threshold: threshold)
            case nil:
                if level == .ok {
                    alarms[mount] = nil
                } else if var alarm = alarms[mount] {
                    alarm.reading = entry.reading
                    alarm.level = level
                    alarms[mount] = alarm
                } else {
                    // Low when the daemon started, already said before it stopped.
                    alarms[mount] = DiskAlarm(reading: entry.reading, level: level,
                                              threshold: level == .critical ? thresholds.criticalLine
                                                  : thresholds.lowLine(total: entry.reading.totalBytes))
                }
            }
        }
        if levels != eventState.diskLevels ?? [:] {
            eventState.diskLevels = levels
            saveEventState()
        }
        if alarms != diskAlarms {
            diskAlarms = alarms
            broadcast(DaemonAPI.Notification.diskChanged, diskState())
        }
    }

    /// Every volume not ok, worst first, for `disk/state`.
    func diskState() -> DiskState {
        DiskState(alarms: diskAlarms.values.sorted {
            ($0.level, $1.reading.freeBytes) > ($1.level, $0.reading.freeBytes)
        })
    }

    private func raiseDiskLow(_ alarm: DiskAlarm) {
        let reading = alarm.reading
        var details = ["volume": reading.volume, "free_bytes": String(reading.freeBytes),
                       "free_percent": String(reading.freePercent), "level": alarm.level.rawValue,
                       "threshold": String(alarm.threshold)]
        var named = Array(alarm.worktrees.prefix(DiskSpace.worktreesNamed))
        while !named.isEmpty, DiskSpace.worktreeWords(named).count > EventDraft.maximumDetailLength {
            named.removeLast()
        }
        if !named.isEmpty { details["worktrees"] = DiskSpace.worktreeWords(named) }
        let free = DiskSpace.words(reading.freeBytes)
        raise(EventDraft(name: "mac.disk_low", at: now(), scope: .mac,
                         sentence: alarm.level == .critical
                             ? "\(reading.volume) is almost full: \(free) free."
                             : "\(reading.volume) is running low: \(free) free.",
                         details: details))
    }

    private func raiseDiskOK(_ reading: DiskReading, threshold: Int64) {
        raise(EventDraft(name: "mac.disk_ok", at: now(), scope: .mac,
                         sentence: "\(reading.volume) has \(DiskSpace.words(reading.freeBytes)) free again.",
                         details: ["volume": reading.volume, "free_bytes": String(reading.freeBytes),
                                   "free_percent": String(reading.freePercent), "threshold": String(threshold)]))
    }

    // MARK: Worktrees

    /// The worktrees on a volume, largest first, measured once at a crossing and within
    /// a budget of files and time, so a volume full of build output is not walked whole.
    /// One that ran over the budget is marked partial: it holds at least that much.
    private func largestWorktrees(on mount: String, among projects: Set<URL>) async -> [DiskWorktree] {
        var roots: [URL] = []
        for agent in agents.values {
            if let root = agent.worktree?.root { roots.append(root) }
        }
        for project in projects {
            let folder = project.appending(path: WorktreeName.folder, directoryHint: .isDirectory)
            let found = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            roots += found
        }
        let reader = diskReader
        let budget = diskMeasureBudget
        return await Task.detached {
            var seen = Set<String>()
            let unique = roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
                .filter { FileManager.default.fileExists(atPath: $0.path) && reader($0)?.mount == mount }
            guard !unique.isEmpty else { return [] }
            let deadline = ContinuousClock.now.advanced(by: budget.time)
            let each = max(budget.files / unique.count, 1)
            return unique.map { Self.measure($0, files: each, until: deadline) }
                .sorted { $0.bytes > $1.bytes }
        }.value
    }

    /// The bytes under `root`, counting at most `files` entries and stopping at `deadline`.
    nonisolated static func measure(_ root: URL, files: Int, until deadline: ContinuousClock.Instant) -> DiskWorktree {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                        options: [], errorHandler: { _, _ in true }) else {
            return DiskWorktree(name: root.lastPathComponent, bytes: 0)
        }
        var bytes: Int64 = 0
        var counted = 0
        var partial = false
        while let url = walk.nextObject() as? URL {
            counted += 1
            if counted > files || (counted % 512 == 0 && ContinuousClock.now >= deadline) {
                partial = true
                break
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return DiskWorktree(name: root.lastPathComponent, bytes: bytes, partial: partial)
    }

    // MARK: Settings

    /// What the project's file sets for disk space, read once until it changes.
    func configuredDiskSpace(in folder: URL) -> DiskThresholds? {
        let standardized = Project.standardize(folder)
        if let known = diskSpaceConfigCache[standardized] { return known }
        let found = ProjectConfig.diskSpace(in: standardized)
        diskSpaceConfigCache[standardized] = .some(found)
        return found
    }

    /// `projects/setDiskSpace`: the person's lines, written into the project's own file.
    public func setDiskSpace(_ request: DaemonAPI.SetDiskSpaceRequest) throws -> DaemonAPI.ProjectSummary {
        let standardized = Project.standardize(request.folder)
        guard projectSummary(for: standardized) != nil, Self.isDirectory(standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject,
                               message: "\(standardized.path) is not a project, or is not there.")
        }
        if let problem = request.diskSpace.problem {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: problem)
        }
        do {
            try ProjectConfig.setDiskSpace(request.diskSpace, in: standardized)
        } catch let unreadable as ProjectConfig.Unreadable {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: unreadable.message)
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "\(DotAgents.folder)/\(ProjectConfig.fileName) could not be written: \(error.localizedDescription)")
        }
        diskSpaceConfigCache[standardized] = nil
        guard let summary = projectSummary(for: standardized) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchProject, message: "\(standardized.path) is not a project.")
        }
        sendProject(summary)
        scheduleDiskCheck()
        return summary
    }

    // MARK: Trying it

    /// Free bytes a scratch root says every volume has, so the strip and the events can
    /// be seen without filling a disk: a file `disk-free-override` in the root holding a
    /// number of bytes, or of GB with `GB` after it. Debug builds on a scratch root only.
    func diskOverride() -> Int64? {
        #if DEBUG
        guard !locations.isStandard,
              let text = try? String(contentsOf: locations.root.appending(path: "disk-free-override"), encoding: .utf8)
        else { return nil }
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if said.hasSuffix("GB"), let gb = Double(said.dropLast(2).trimmingCharacters(in: .whitespaces)) {
            return Int64(gb * Double(DiskSpace.gigabyte))
        }
        return Int64(said)
        #else
        return nil
        #endif
    }
}

/// How a volume is read: its name, where it is mounted, and how much is free for what
/// matters, which on a Mac counts space the system would free for it.
enum DiskReader {
    static func read(_ folder: URL) -> DiskReading? {
        #if canImport(Darwin)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                         .volumeTotalCapacityKey, .volumeNameKey, .volumeURLKey]
        guard let values = try? folder.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else {
            return nil
        }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let mount = values.volume?.path ?? "/"
        return DiskReading(volume: values.volumeName ?? mount, mount: mount, freeBytes: free, totalBytes: Int64(total))
        #else
        guard let system = try? FileManager.default.attributesOfFileSystem(forPath: folder.path),
              let free = (system[.systemFreeSize] as? NSNumber)?.int64Value,
              let total = (system[.systemSize] as? NSNumber)?.int64Value else { return nil }
        let device = (system[.systemNumber] as? NSNumber)?.intValue ?? 0
        return DiskReading(volume: "This server’s disk", mount: "device-\(device)", freeBytes: free, totalBytes: total)
        #endif
    }
}
