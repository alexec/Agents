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
    public static let fileExtension = "md"
    /// Where a project keeps them. One folder, so nothing else in a repository can
    /// accidentally become a thing that starts agents.
    public static let folderName = ".agents/workflows"

    public static func folder(in project: URL) -> URL {
        project.appending(path: folderName, directoryHint: .isDirectory)
    }

    public static func url(for workflowID: String, in project: URL) -> URL {
        folder(in: project).appending(path: "\(workflowID).\(fileExtension)")
    }

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
        func broken(_ why: String) -> Workflow {
            Workflow(workflowID: workflowID, folder: project, problem: .unreadable(why))
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

        let frontMatter = Array(lines[1..<closing])
        let body = FrontMatter.strip(text)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return broken("There is no prompt under the metadata")
        }

        let mapping: [String: YAMLNode]
        do {
            mapping = try YAMLNode.mapping(from: frontMatter)
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

        let known: Set<String> = ["on", "agent", "name"]
        let unknown = mapping.filter { !known.contains($0.key) }.mapValues(\.jsonValue)

        return Workflow(workflowID: workflowID, folder: project,
                        name: mapping["name"]?.scalar,
                        triggers: triggers, mode: mode,
                        prompt: body, problem: problem, unknownFields: unknown)
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
        if let between = keys["between"]?.scalar, !between.isEmpty {
            let halves = between.split(separator: "-", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard halves.count == 2,
                  let from = hour(from: halves[0]), let to = hour(from: halves[1]),
                  from <= to else {
                throw YAMLNode.Failure("\"\(between)\" is not a range of times, like \"09:00-18:00\"")
            }
            hours = from...to
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

        return WorkflowSchedule(minutes: minutes, hours: hours, days: days)
    }

    /// `09:00` or `9` — the hour part of either.
    private static func hour(from text: String) -> Int? {
        let hourPart = text.split(separator: ":").first.map(String.init) ?? text
        guard let value = Int(hourPart), (0...23).contains(value) else { return nil }
        return value
    }
}
