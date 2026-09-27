import Foundation

/// Whether Auto-review may answer one permission request without asking (061).
///
/// Pure and fail-closed: unknown tools, ambiguous shell, out-of-reach paths, publishing
/// and privilege escalation all ask. Approval is only `allow_once`.
public enum ClientPermissionReview {
    /// The offered `allow_once` option when this request is ordinary in-reach work; nil to ask.
    public static func allowOnce(for request: PermissionRequest, scope: FolderScope) -> PermissionOption? {
        guard let option = request.options.first(where: { $0.kind == .allowOnce }) else { return nil }
        guard isOrdinary(request.toolCall, scope: scope) else { return nil }
        return option
    }

    public static func isOrdinary(_ call: ToolCall, scope: FolderScope) -> Bool {
        if isAppControl(call) { return false }
        if isFileAction(call) { return everyPath(in: call, scope: scope) }
        if isExecuteAction(call) { return commandIsOrdinary(call, scope: scope) }
        return false
    }

    private static func isAppControl(_ call: ToolCall) -> Bool {
        let named = call.name ?? call.title
        if call.isManagingWorkflows || call.isActingOnPullRequest { return true }
        if AppTool.isServedByTheApp(named) {
            return !(call.isFinishingTurn || call.isSuggestingPrompts
                || call.isShowingFile || call.isReportingOutcome)
        }
        return false
    }

    private static func isFileAction(_ call: ToolCall) -> Bool {
        let kind = (call.kind ?? "").lowercased()
        if ["edit", "write", "delete", "move", "create"].contains(kind) {
            if let name = call.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return knownFileName(name)
            }
            return true
        }
        if let name = call.name { return knownFileName(name) }
        return false
    }

    private static func knownFileName(_ name: String) -> Bool {
        let bare = name.split(separator: "/").last.map(String.init) ?? name
        let known: Set<String> = [
            "write", "edit", "create", "delete", "remove", "unlink",
            "search_replace", "str_replace", "apply_patch", "edit_file",
            "write_file", "create_file", "delete_file", "remove_file",
            "Write", "Edit", "Delete", "MultiEdit",
        ]
        return known.contains(bare) || known.contains(bare.lowercased())
    }

    private static func isExecuteAction(_ call: ToolCall) -> Bool {
        let kind = (call.kind ?? "").lowercased()
        if ["execute", "shell", "terminal", "command"].contains(kind) { return true }
        if let name = call.name {
            let bare = (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
            return ["bash", "shell", "run_terminal_cmd", "run_terminal_command",
                    "run_command", "execute", "terminal"].contains(bare)
        }
        return false
    }

    private static func everyPath(in call: ToolCall, scope: FolderScope) -> Bool {
        let paths = declaredPaths(call)
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy { scope.allows($0) }
    }

    private static func declaredPaths(_ call: ToolCall) -> [String] {
        var paths: [String] = []
        paths.append(contentsOf: call.locations.map(\.path))
        paths.append(contentsOf: call.diffs.map(\.path))
        if let input = call.rawInput {
            for key in ["file_path", "path", "filePath", "file", "target", "destination", "from", "to"] {
                if let value = input[key]?.stringValue, !value.isEmpty { paths.append(value) }
            }
            if let list = input["paths"]?.arrayValue {
                paths.append(contentsOf: list.compactMap(\.stringValue))
            }
        }
        return paths.map(expandingHome).filter { !$0.isEmpty }
    }

    private static func expandingHome(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        return path
    }

    private static func absolutePath(_ path: String, workingDirectory: String?) -> String? {
        let expanded = expandingHome(path)
        if expanded.hasPrefix("/") { return expanded }
        guard let cwd = workingDirectory, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
    }

    private static func commandIsOrdinary(_ call: ToolCall, scope: FolderScope) -> Bool {
        guard let line = commandLine(call) else { return false }
        if hasShellControl(line) { return false }
        let cwd = workingDirectory(call, scope: scope)
        guard let cwd, scope.allows(cwd) else { return false }
        guard let argv = tokenize(line), let first = argv.first else { return false }
        let command = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        switch command {
        case "sudo", "su", "doas", "login", "dscl", "security": return false
        case "git": return gitIsOrdinary(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "npm", "npx", "yarn", "pnpm", "bun":
            return packageIsOrdinary(command, Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "swift": return swiftIsOrdinary(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "xcodebuild", "make", "cmake", "ninja", "bazel", "buck":
            return argvPathsInScope(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "cargo": return cargoIsOrdinary(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "go": return goIsOrdinary(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "python", "python3", "pytest", "py.test":
            return argvPathsInScope(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "prettier", "eslint", "ruff", "black", "clang-format", "swift-format", "rustfmt":
            return argvPathsInScope(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        case "pip", "pip3": return pipIsOrdinary(Array(argv.dropFirst()), cwd: cwd, scope: scope)
        default: return false
        }
    }

    private static func commandLine(_ call: ToolCall) -> String? {
        if let command = call.rawInput?["command"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            return command
        }
        let title = call.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.contains(" ") || title.contains("/") { return title }
        return nil
    }

    private static func workingDirectory(_ call: ToolCall, scope: FolderScope) -> String? {
        if let cwd = call.rawInput?["working_directory"]?.stringValue
            ?? call.rawInput?["cwd"]?.stringValue
            ?? call.rawInput?["workdir"]?.stringValue {
            return absolutePath(cwd, workingDirectory: scope.folders.first?.path) ?? expandingHome(cwd)
        }
        return scope.folders.first?.path
    }

    private static func hasShellControl(_ line: String) -> Bool {
        for token in [";", "&&", "||", "|", "`", "$(", "${", "\n", "\r", ">", "<", "&"] {
            if line.contains(token) { return true }
        }
        return line.contains("$")
    }

    private static func tokenize(_ line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if quote != nil || escaped { return nil }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func gitIsOrdinary(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        guard let sub = args.first?.lowercased() else { return false }
        let allowed: Set<String> = [
            "status", "diff", "log", "show", "add", "commit", "checkout", "switch",
            "branch", "fetch", "pull", "stash", "rev-parse", "describe", "ls-files",
            "restore", "reset", "cherry-pick", "rebase", "merge", "tag", "blame",
            "shortlog", "config",
        ]
        if ["push", "request-pull", "send-email", "imap-send"].contains(sub) { return false }
        guard allowed.contains(sub) else { return false }
        if sub == "config", args.contains(where: { $0 == "--global" || $0 == "--system" }) { return false }
        return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
    }

    private static func packageIsOrdinary(_ command: String, _ args: [String],
                                          cwd: String, scope: FolderScope) -> Bool {
        guard let sub = args.first?.lowercased() else { return false }
        if ["install", "ci", "add", "i"].contains(sub) {
            if args.contains("-g") || args.contains("--global") { return false }
            return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
        }
        if ["test", "run", "build", "lint", "format", "exec", "start"].contains(sub) {
            return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
        }
        return command == "npx" && argvPathsInScope(args, cwd: cwd, scope: scope)
    }

    private static func swiftIsOrdinary(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        guard let sub = args.first?.lowercased(),
              ["test", "build", "package", "run", "format"].contains(sub) else { return false }
        return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
    }

    private static func cargoIsOrdinary(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        guard let sub = args.first?.lowercased(),
              ["test", "build", "check", "fmt", "clippy", "run"].contains(sub) else { return false }
        return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
    }

    private static func goIsOrdinary(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        guard let sub = args.first?.lowercased(),
              ["test", "build", "fmt", "mod", "vet", "run"].contains(sub) else { return false }
        return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
    }

    private static func pipIsOrdinary(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        guard args.first?.lowercased() == "install" else { return false }
        if args.contains("--user") { return false }
        guard args.contains("-e") || args.contains("--editable")
                || args.contains("-r") || args.contains(".") || args.contains("./") else { return false }
        return argvPathsInScope(Array(args.dropFirst()), cwd: cwd, scope: scope)
    }

    private static func argvPathsInScope(_ args: [String], cwd: String, scope: FolderScope) -> Bool {
        for arg in args {
            if arg.hasPrefix("-") { continue }
            let looksLikePath = arg.hasPrefix("/") || arg.hasPrefix("~") || arg.hasPrefix(".") || arg.contains("/")
            guard looksLikePath else { continue }
            guard let absolute = absolutePath(arg, workingDirectory: cwd), scope.allows(absolute) else { return false }
        }
        return true
    }
}
