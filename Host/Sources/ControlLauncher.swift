import Foundation

/// Runs `agents-control` with its secrets on inherited descriptors (058, T056, T058a):
/// the control plane's key on 3 and, for a bucket, its keys as JSON on 4. Nothing secret is
/// in an argument, the environment, a plist or a file.
enum ControlTool {
    static let keyFD: Int32 = 3
    static let bucketFD: Int32 = 4

    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String
        var ok: Bool { status == 0 }
        /// What `agents-control` said went wrong, without its name in front.
        var problem: String {
            let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.replacingOccurrences(of: "agents-control: ", with: "")
        }
    }

    /// The arguments and environment for `store`, with the descriptors to hand over.
    static func plan(_ arguments: [String], paths: HostPaths, settings: HostSettings, key: Bool = true,
                     store: StoreAddress? = nil, keys given: HostSecrets.BucketKeys? = nil) throws -> (arguments: [String], environment: [String: String], secrets: [Int32: Data]) {
        let address = store ?? StoreAddress(settings.store, bucket: settings.bucket, paths: paths)
        var arguments = arguments
        var secrets: [Int32: Data] = [:]
        if key {
            secrets[keyFD] = try HostSecrets.controlKey(paths)
            arguments += ["--key-fd", String(keyFD)]
        }
        if address.needsKeys {
            guard let keys = given ?? HostSecrets.bucketKeys(paths) else { throw ControlService.Failure("the bucket's keys are not saved yet") }
            secrets[bucketFD] = try JSONEncoder().encode(keys)
            arguments += ["--store-credentials-fd", String(bucketFD)]
        }
        // Only what agents-control needs: not the window's or a shell's variables, and
        // never this session's.
        var environment = address.environment
        environment["AGENTS_STORE"] = address.url
        environment["HOME"] = NSHomeDirectory()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        #if DEBUG
        // A walk's stand-in for a public root (#61, Pebble): Debug builds only.
        if let root = ProcessInfo.processInfo.environment["AGENTS_TEST_TRUST_ROOT"] { environment["AGENTS_TEST_TRUST_ROOT"] = root }
        #endif
        return (arguments, environment, secrets)
    }

    /// Runs one command to its end: `code`, `hosts`, `clients`, `store check`, `store copy`.
    static func run(_ arguments: [String], paths: HostPaths, settings: HostSettings, key: Bool = true,
                    store: StoreAddress? = nil, keys: HostSecrets.BucketKeys? = nil) async -> Result {
        do {
            let planned = try plan(arguments, paths: paths, settings: settings, key: key, store: store, keys: keys)
            return try await spawn(paths.agentsControl.path, planned.arguments, planned.environment, planned.secrets)
        } catch {
            return Result(status: -1, output: "", error: "\(error)")
        }
    }

    private static func spawn(_ tool: String, _ arguments: [String], _ environment: [String: String],
                              _ secrets: [Int32: Data]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { continuation.resume(returning: try spawnBlocking(tool, arguments, environment, secrets)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func spawnBlocking(_ tool: String, _ arguments: [String], _ environment: [String: String],
                                      _ secrets: [Int32: Data]) throws -> Result {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var opened: [Int32] = []
        defer { opened.forEach { close($0) } }
        // A pipe per secret, filled before the child starts: each is far below a pipe's
        // buffer, so nothing waits on the child to read.
        for (target, data) in secrets {
            var ends: [Int32] = [0, 0]
            guard pipe(&ends) == 0 else { throw ControlService.Failure("no pipe for the key") }
            data.withUnsafeBytes { _ = write(ends[1], $0.baseAddress, data.count) }
            close(ends[1])
            opened.append(ends[0])
            posix_spawn_file_actions_adddup2(&actions, ends[0], target)
        }
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0 else { throw ControlService.Failure("no pipe for the output") }
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        let argv = ([tool] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, tool, &actions, nil, argv, envp)
        close(out[1]); close(err[1])
        guard status == 0 else {
            close(out[0]); close(err[0])
            throw ControlService.Failure("could not start agents-control (\(status))")
        }
        let output = FileHandle(fileDescriptor: out[0], closeOnDealloc: true).readDataToEndOfFile()
        let error = FileHandle(fileDescriptor: err[0], closeOnDealloc: true).readDataToEndOfFile()
        var exit: Int32 = 0
        waitpid(pid, &exit, 0)
        return Result(status: (exit >> 8) & 0xff, output: String(decoding: output, as: UTF8.self),
                      error: String(decoding: error, as: UTF8.self))
    }
}

/// What the control plane's launch agent runs: this app's own program with
/// `--launch-control`. It reads the key (and a bucket's keys) from the keychain, where only
/// this app may read them, puts them on descriptors, and becomes `agents-control serve`.
/// launchd keeps it running; its output goes to the control plane's log.
enum ControlLauncher {
    static let argument = "--launch-control"

    static func run() -> Never {
        let paths = HostPaths.current
        let settings = HostSettings.load(paths)
        do {
            try FileManager.default.createDirectory(at: paths.controlHome, withIntermediateDirectories: true)
            let log = open(paths.controlLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if log >= 0 { dup2(log, 1); dup2(log, 2); close(log) }
            var arguments = ["serve", "--home", paths.controlHome.path, "--port", String(paths.port)]
            if paths.scratch, ProcessInfo.processInfo.environment["AGENTS_HOST_BONJOUR"] != "1" { arguments.append("--no-bonjour") }
            // Empty, for the control plane to come back to (T127); once it has, it serves.
            if settings.receiving == true { arguments.append("--receive") }
            let planned = try ControlTool.plan(arguments, paths: paths, settings: settings)
            for (target, data) in planned.secrets {
                var ends: [Int32] = [0, 0]
                guard pipe(&ends) == 0 else { throw ControlService.Failure("no pipe for the key") }
                data.withUnsafeBytes { _ = write(ends[1], $0.baseAddress, data.count) }
                close(ends[1])
                if ends[0] != target { dup2(ends[0], target); close(ends[0]) }
            }
            let tool = paths.agentsControl.path
            let argv = ([tool] + planned.arguments).map { strdup($0) } + [nil]
            let envp = planned.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            execve(tool, argv, envp)
            throw ControlService.Failure("could not start \(tool): \(String(cString: strerror(errno)))")
        } catch {
            FileHandle.standardError.write(Data("Agents Host: \(error)\n".utf8))
            // Not at once again: launchd would restart a failure in a tight loop.
            sleep(10)
            exit(1)
        }
    }
}

/// A failure said in words for the window.
enum ControlService {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
