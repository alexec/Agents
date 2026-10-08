import Foundation

/// Reading one workflow off disk.
///
/// A workflow file is a Markdown document that opens with a metadata block: the same
/// shape the app already understands everywhere else, which is why the positional rule
/// comes from `FrontMatter` rather than being written a second time here. `---` on the
/// first line fences metadata; `---` anywhere else is a horizontal rule a reader is
/// entitled to see, and getting that backwards eats the top of a document.
///
/// The metadata is YAML, and this reads a deliberate subset of it: scalars, block
/// sequences, block mappings, and inline `[a, b]` sequences. That is the whole of what
/// the format documented in `contracts/workflow-file.md` uses. Anything outside it is
/// reported as unreadable rather than guessed at, because a workflow that runs
/// something other than what its author wrote is worse than one that does not run.
public enum WorkflowFile {
    public static let fileExtension = WorkflowPaths.fileExtension
    public static let folderName = WorkflowPaths.folderName
    public static func folder(in project: URL) -> URL { WorkflowPaths.folder(in: project) }
    public static func url(for workflowID: String, in project: URL) -> URL { WorkflowPaths.url(for: workflowID, in: project) }

    /// Read and parse one file. A file that cannot be read at all is still a workflow —
    /// one carrying its problem, so the project page can say what is wrong with it
    /// rather than leaving a gap where a row should be.
    public static func read(_ url: URL, in project: URL) -> Workflow {
        let workflowID = url.deletingPathExtension().lastPathComponent
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Workflow(workflowID: workflowID, folder: project,
                            problem: .unreadable("This file could not be read"))
        }
        return parse(text, workflowID: workflowID, in: project)
    }

    /// The whole of the format, as a function of text, so a test needs no file.
    public static func parse(_ text: String, workflowID: String, in project: URL) -> Workflow {
        // Set once the metadata block is found, so a file broken further down can still
        // show what it says.
        var frontMatter: [String]?
        func broken(_ why: String) -> Workflow {
            var workflow = Workflow(workflowID: workflowID, folder: project, problem: .unreadable(why))
            // What can still be read of it, for the page to show (#98): its name, its
            // triggers and its mode. Shown and never acted on: the problem stops every
            // fire, every next time and every match before the triggers are looked at.
            if let frontMatter, let mapping = try? YAMLNode.mapping(from: frontMatter) {
                if let name = mapping["name"]?.scalar, !name.isEmpty { workflow.name = name }
                if let on = mapping["on"], let triggers = try? parseTriggers(on) { workflow.triggers = triggers }
                if let named = mapping["agent"]?.scalar, let mode = WorkflowMode(rawValue: named) {
                    workflow.mode = mode
                }
                if let text = mapping[WorkflowCooldown.key]?.scalar,
                   case .success(let length) = WorkflowCooldown.parse(text) {
                    workflow.cooldown = length
                }
                // Its switch and its archive, so a broken file put away stays put away.
                workflow.enabled = WorkflowSwitches.flag(mapping["enabled"])
                workflow.archived = WorkflowSwitches.flag(mapping[WorkflowSwitches.archived])
                workflow.whenDone = mapping[WorkflowWhenDone.key]?.scalar.flatMap(WorkflowWhenDone.init(rawValue:))
                // Where it was pinned, when that list can be read, so a broken file
                // meant for another computer stays off this one's list (#317).
                if let node = mapping["hosts"], let ids = try? Self.hostIDs(from: node) {
                    workflow.hosts = ids.isEmpty ? nil : ids
                }
            }
            return workflow
        }

        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return broken("This file does not start with a metadata block")
        }
        guard let closing = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return broken("The metadata block is never closed")
        }

        frontMatter = Array(lines[1..<closing])
        let body = FrontMatter.strip(text)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return broken("There is no prompt under the metadata")
        }

        let mapping: [String: YAMLNode]
        do {
            mapping = try YAMLNode.mapping(from: frontMatter ?? [])
        } catch let error as YAMLNode.Failure {
            return broken(error.message)
        } catch {
            return broken("The metadata could not be read")
        }

        guard let onNode = mapping["on"] else {
            return broken("The metadata does not say what makes this run")
        }
        let triggers: [WorkflowTrigger]
        do {
            triggers = try parseTriggers(onNode)
        } catch let error as YAMLNode.Failure {
            return broken(error.message)
        } catch {
            return broken("The triggers could not be read")
        }
        guard !triggers.isEmpty else {
            return broken("The metadata does not say what makes this run")
        }

        // A mode we do not know is understood but not supported: listed and inert,
        // never a parse failure, because it is a file from a later version and not a
        // broken one.
        var problem: WorkflowProblem?
        var mode = WorkflowMode.new
        if let named = mapping["agent"]?.scalar {
            if let known = WorkflowMode(rawValue: named) {
                mode = known
            } else {
                problem = .unsupportedMode(named)
            }
        }
        if problem == nil, triggers.allSatisfy({ !$0.isSupported }) {
            problem = .triggerNotSupported(triggers[0].name)
        }

        // How the agent should be started. A key that is there but is not a scalar —
        // a list, or a block under it — is a file somebody has to fix, because the one
        // thing worse than a workflow that does not run is one that runs with a
        // permission we guessed at. A key with nothing after it says nothing, which is
        // the same as leaving it out.
        func setting(_ key: String) throws -> String? {
            guard let node = mapping[key] else { return nil }
            guard let value = node.scalar else {
                throw YAMLNode.Failure("`\(key):` must be a single value")
            }
            return value.isEmpty ? nil : value
        }
        // Everything else the runtime offers, by its own id, one scalar each. A value
        // left empty says nothing, as it does at the top level.
        func options() throws -> [String: String] {
            guard let node = mapping[WorkflowSettings.Setting.options] else { return [:] }
            if node.scalar?.isEmpty == true { return [:] }
            guard case .mapping(let pairs) = node else {
                throw YAMLNode.Failure("`options:` must be a list of keys, like `fast: true`")
            }
            var named: [String: String] = [:]
            for (id, value) in pairs {
                guard let text = value.scalar else {
                    throw YAMLNode.Failure("`\(id):` under `options:` must be a single value")
                }
                if !text.isEmpty { named[id] = text }
            }
            return named
        }
        func labels() throws -> [String] {
            guard let node = mapping["labels"] else { return [] }
            guard let values = node.sequenceValues else {
                throw YAMLNode.Failure("`labels:` must be a list of names")
            }
            do {
                return try SessionLabelPolicy.change(current: [], add: values, actor: .agent,
                                                     projectLabels: []).map(\.value)
            } catch {
                throw YAMLNode.Failure("`labels:` \(error.localizedDescription)")
            }
        }
        // How long from one run's start to the next (#103). Wrong, it is a file to fix
        // rather than a cooldown to guess at: a workflow meant to run once an hour and
        // running on every trigger is the thing the key was written to stop.
        var cooldown: TimeInterval?
        if let node = mapping[WorkflowCooldown.key] {
            guard let text = node.scalar else {
                return broken("`\(WorkflowCooldown.key):` must be a single value, like 15m")
            }
            if !text.isEmpty {
                switch WorkflowCooldown.parse(text) {
                case .success(let length): cooldown = length
                case .failure(let failure): return broken(failure.message)
                }
            }
        }

        // Where the Enabled switch starts (#42). Anything but true or false is a file to
        // fix: a workflow meant to arrive off and arriving on is what the key prevents.
        var enabled: Bool?
        if let node = mapping["enabled"] {
            switch node.scalar {
            case "true": enabled = true
            case "false": enabled = false
            case "": break
            default: return broken("`enabled:` must be true or false")
            }
        }

        // Put away (#125). As strict as `enabled:`: a workflow meant to be archived and
        // running is what the key prevents.
        var archived: Bool?
        if let node = mapping[WorkflowSwitches.archived] {
            switch node.scalar {
            case "true": archived = true
            case "false": archived = false
            case "": break
            default: return broken("`archived:` must be true or false")
            }
        }

        // What a run may do with its session when it is done (#433). As strict as
        // `archived:`: a workflow meant to keep its runs and archiving them is what the
        // key must never do.
        var whenDone: WorkflowWhenDone?
        if let node = mapping[WorkflowWhenDone.key] {
            guard let text = node.scalar else { return broken(WorkflowWhenDone.unknown) }
            if !text.isEmpty {
                guard let known = WorkflowWhenDone(rawValue: text) else { return broken(WorkflowWhenDone.unknown) }
                whenDone = known
            }
        }

        // Which computers may run it (#317). Absent, or an empty list, is every host.
        // A list that is not ids is a file to fix: guessing which computer was meant
        // would run it in the wrong place, or hide it from the right one.
        var hosts: [String]?
        if let node = mapping["hosts"] {
            do {
                let ids = try Self.hostIDs(from: node)
                hosts = ids.isEmpty ? nil : ids
            } catch let error as YAMLNode.Failure {
                return broken(error.message)
            } catch {
                return broken(String(describing: error))
            }
        }

        let settings: WorkflowSettings
        do {
            settings = WorkflowSettings(permissionMode: try setting("permission-mode"),
                                        runtimeID: try setting("runtime"),
                                        model: try setting("model"),
                                        effort: try setting("effort"),
                                        options: try options(), labels: try labels())
        } catch let error as YAMLNode.Failure {
            return broken(error.message)
        } catch {
            return broken("The settings could not be read")
        }
        // A `runtime:` naming an id this version has never heard of is deliberately not
        // a parse error. A runtime dropped or renamed should turn into a workflow that
        // says why it did not run — which is a refusal, raised in the start path where
        // the catalog is actually consulted — and not into a file marked broken, which
        // is what a person would have to go and edit. See research.md §4.

        let known: Set<String> = ["on", "agent", "name", "permission-mode", "runtime", "model", "labels",
                                   "effort", "options", "enabled", WorkflowSwitches.archived,
                                   WorkflowCooldown.key, "hosts", WorkflowWhenDone.key]
        let unknown = mapping.filter { !known.contains($0.key) }.mapValues(\.jsonValue)

        return Workflow(workflowID: workflowID, folder: project,
                        name: mapping["name"]?.scalar,
                        triggers: triggers, mode: mode,
                        prompt: body, problem: problem, unknownFields: unknown,
                        settings: settings, cooldown: cooldown, enabled: enabled,
                        archived: archived, hosts: hosts, whenDone: whenDone)
    }

    /// The machine ids under `hosts:`. A bare id and a list of them are the same
    /// thing, as `days:` already is. A block that is not a list of ids is refused.
    static func hostIDs(from node: YAMLNode) throws -> [String] {
        let texts: [String]
        switch node {
        case .mapping:
            throw YAMLNode.Failure("`hosts:` must be a list of machine ids")
        case .scalar(let value):
            texts = [value]
        case .sequence(let items):
            var read: [String] = []
            for item in items {
                guard let text = item.scalar else {
                    throw YAMLNode.Failure("`hosts:` must be a list of machine ids")
                }
                read.append(text)
            }
            texts = read
        }
        return WorkflowHosts.cleaned(texts)
    }

    // MARK: Triggers

    private static func parseTriggers(_ node: YAMLNode) throws -> [WorkflowTrigger] {
        // A single trigger written without a dash is the same thing as a list of one.
        let entries: [YAMLNode]
        switch node {
        case .sequence(let items): entries = items
        default: entries = [node]
        }
        return try entries.map(parseTrigger)
    }

    private static func parseTrigger(_ node: YAMLNode) throws -> WorkflowTrigger {
        // A bare name: `- agent-finished`.
        if let name = node.scalar { return try trigger(named: name, keys: [:]) }
        // A single-key mapping: `- schedule:` with its settings under it.
        guard case .mapping(let pairs) = node, let (name, value) = pairs.first, pairs.count == 1 else {
            throw YAMLNode.Failure("A trigger must be a name, or a name with settings under it")
        }
        guard case .mapping(let settings) = value else {
            // `- workflow-completed:` with nothing under it is the bare form.
            if value.scalar?.isEmpty ?? false { return try trigger(named: name, keys: [:]) }
            throw YAMLNode.Failure("The settings for \"\(name)\" are not a list of keys")
        }
        return try trigger(named: name, keys: settings)
    }

    private static func trigger(named name: String, keys: [String: YAMLNode]) throws -> WorkflowTrigger {
        switch name {
        case "schedule": return .schedule(try parseSchedule(keys))
        case "agent-finished": return .agentFinished
        case "agent-asked-permission": return .agentAskedPermission
        case "agent-asked-form": return .agentAskedForm
        case "agent-stopped": return .agentStopped
        case "workflow-completed": return .workflowCompleted(id: keys["id"]?.scalar)
        default:
            // A server's event (#383): `noun.verbed`, not the app's, its keys the
            // subscription's arguments rather than details matched here. Whether a server
            // offers it is known only once one is asked, so that is said on the page,
            // not here.
            if EventCatalogue.isServerEventName(name) {
                let values = keys.mapValues(\.jsonValue)
                guard let trigger = MCPEventTrigger(event: name, keys: values) else {
                    throw YAMLNode.Failure("`server:` under \"\(name)\" is a server's name, or a list of them")
                }
                guard MCPEventTrigger.canonicalJSON(.object(trigger.arguments)).utf8.count
                        <= MCPEventTrigger.argumentLimit else {
                    throw YAMLNode.Failure("The settings under \"\(name)\" are over 2 KB")
                }
                return .serverEvent(trigger)
            }
            // An event (042): a catalogue name, a subject with .*, or custom.<name>,
            // narrowed by details written under it. A name the catalogue knows with a
            // detail it does not carry is a mistake worth saying; a dotted name it does
            // not know is from a later version, and is kept whole like any other.
            if name.contains(".") {
                // One value, or a list of them meaning any of (073 FR-015), inline or as
                // a block, as `days:` already is.
                var filters: [String: DetailFilter] = [:]
                for (key, value) in keys {
                    let filter: DetailFilter?
                    switch value {
                    case .scalar(let text): filter = DetailFilter(text)
                    case .sequence(let items):
                        let texts = items.compactMap(\.scalar)
                        filter = texts.count == items.count ? DetailFilter(anyOf: texts) : nil
                    case .mapping: filter = nil
                    }
                    guard let filter else {
                        throw YAMLNode.Failure("The \"\(key)\" under \"\(name)\" should be one value or a list of values")
                    }
                    filters[key] = filter
                }
                switch EventPattern.parse(name, filters: filters) {
                case .success(let pattern):
                    return .event(pattern)
                case .failure(.badFilter(let kind, let key, let valid)):
                    throw YAMLNode.Failure(valid.isEmpty
                        ? "\"\(kind)\" takes no settings, not \(key)"
                        : "\"\(kind)\" takes \(valid.joined(separator: ", ")), not \(key)")
                case .failure(let problem) where problem.isBadValue:
                    throw YAMLNode.Failure(problem.message)
                case .failure:
                    break
                }
            }
            // Kept whole, with whatever it came with. This is the case that lets the
            // format grow without anything already on disk changing shape.
            return .unrecognised(name: name, keys: keys.mapValues(\.jsonValue))
        }
    }

    private static func parseSchedule(_ keys: [String: YAMLNode]) throws -> WorkflowSchedule {
        guard let atNode = keys["at"] else {
            throw YAMLNode.Failure("A schedule must say what time with `at:`")
        }
        let atValues = atNode.sequenceValues ?? [atNode.scalar ?? ""]
        var minutes: Set<Int> = []
        for value in atValues {
            // `:00` and `:30`, and nothing else. The half-hour granularity is a floor
            // rather than an oversight, so a finer value is an error and not a rounding.
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(":"), let minute = Int(trimmed.dropFirst()),
                  WorkflowSchedule.allowedMinutes.contains(minute) else {
                throw YAMLNode.Failure("\"\(trimmed)\" is not a time a workflow can run at — only \":00\" and \":30\"")
            }
            minutes.insert(minute)
        }
        guard !minutes.isEmpty else {
            throw YAMLNode.Failure("A schedule must say what time with `at:`")
        }

        var hours = 0...23
        var startMinute = 0
        var endMinute = 30
        if let between = keys["between"]?.scalar, !between.isEmpty {
            let halves = between.split(separator: "-", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            // Compared as minutes of the day, so `09:30-09:00` is refused along with
            // `18:00-09:00`.
            guard halves.count == 2,
                  let from = time(from: halves[0]), let to = time(from: halves[1]),
                  from.hour * 60 + from.minute <= to.hour * 60 + to.minute else {
                throw YAMLNode.Failure("\"\(between)\" is not a range of times, like \"09:00-18:00\"")
            }
            hours = from.hour...to.hour
            startMinute = from.minute
            endMinute = to.minute
        }

        var days = Weekday.everyDay
        if let named = keys["days"]?.sequenceValues {
            var parsed: Set<Weekday> = []
            for day in named {
                guard let weekday = Weekday(rawValue: day.trimmingCharacters(in: .whitespaces).lowercased()) else {
                    throw YAMLNode.Failure("\"\(day)\" is not a day of the week")
                }
                parsed.insert(weekday)
            }
            guard !parsed.isEmpty else { throw YAMLNode.Failure("`days:` names no days") }
            days = parsed
        }

        return WorkflowSchedule(minutes: minutes, hours: hours, startMinute: startMinute,
                                endMinute: endMinute, days: days)
    }

    /// `09:00` or `9` — the hour part of either.
    /// `09:00` or `9:30`, or a bare hour. The minutes are the ones a schedule can run
    /// at and no others: a range that starts at `09:45` names a moment nothing can fire
    /// at, and rounding it one way or the other would be a guess about what was meant.
    private static func time(from text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count),
              let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        guard parts.count == 2 else { return (hour, 0) }
        guard let minute = Int(parts[1]), WorkflowSchedule.allowedMinutes.contains(minute) else { return nil }
        return (hour, minute)
    }
}

/// The two lines of a workflow's front matter the app writes for the person (#125):
/// `enabled: false` while it is turned off, `archived: true` while it is put away.
///
/// Both are left out when they say the default, so turning a workflow off and on again,
/// or archiving and bringing it back, leaves the file exactly as it was.
public enum WorkflowSwitches {
    public static let enabled = "enabled"
    public static let archived = "archived"

    /// `true` or `false`, leniently, for a file that is broken somewhere else.
    static func flag(_ node: YAMLNode?) -> Bool? {
        switch node?.scalar {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// The file's text with its switch set: `enabled: false` when off, no line when on.
    public static func setting(enabled: Bool, in text: String) throws -> String {
        try FrontMatterEdit.set(Self.enabled, to: enabled ? nil : "false", in: text)
    }

    /// The file's text archived or brought back: `archived: true`, or no line.
    public static func setting(archived: Bool, in text: String) throws -> String {
        try FrontMatterEdit.set(Self.archived, to: archived ? "true" : nil, in: text)
    }
}
