import Foundation
@testable import AgentsKit

/// The fake `ssh` in `Fixtures/ssh/`, and a server home for it to run commands in (037).
///
/// See `Fixtures/ssh/README.md`. Each test gets its own home and control folder, so
/// several can run at once, and removes them when it is done.
struct FakeSSH {
    static let fixtures = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ssh", isDirectory: true)

    static var executable: URL { fixtures.appendingPathComponent("ssh") }

    /// Everything this fake server has, under one temporary folder.
    let folder: URL
    /// The server's `$HOME`.
    let home: URL
    /// Where the window's control and forward sockets go. Short, because a Unix socket
    /// path has 104 bytes and `NSTemporaryDirectory()` spends half of them.
    let hosts: URL

    init() throws {
        let id = UUID().uuidString.prefix(8).lowercased()
        folder = URL(filePath: "/tmp/fs-\(id)", directoryHint: .isDirectory)
        home = folder.appendingPathComponent("home", isDirectory: true)
        hosts = folder.appendingPathComponent("h", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
    }

    /// What the fake reads. `uname` defaults to an ARM64 Linux server.
    func environment(fail: String? = nil, uname: String? = nil, knownHosts: URL? = nil,
                     extra: [String: String] = [:]) -> [String: String] {
        var env = SSHCommand.environment(from: ProcessInfo.processInfo.environment)
        env.merge(extra) { _, new in new }
        env["FAKE_SSH_HOME"] = home.path
        if let fail { env["FAKE_SSH_FAIL"] = fail }
        if let uname { env["FAKE_SSH_UNAME"] = uname }
        if let knownHosts { env["FAKE_SSH_KNOWN_HOSTS"] = knownHosts.path }
        return env
    }

    func command(name: String = "fakebox", id: String = "fk000001", fail: String? = nil,
                 uname: String? = nil, knownHosts: URL? = nil, extra: [String: String] = [:]) -> SSHCommand {
        var ssh = SSHCommand(executable: Self.executable, name: name,
                             controlPath: hosts.appendingPathComponent("\(id).ctl"))
        ssh.environment = environment(fail: fail, uname: uname, knownHosts: knownHosts, extra: extra)
        return ssh
    }

    /// Stop anything a test left running under this folder, then remove it. A master's
    /// pid is in its `.ctl` file; nothing is killed by name.
    func tearDown() {
        if let names = try? FileManager.default.contentsOfDirectory(atPath: hosts.path) {
            // A master killed outright leaves its relay behind; a real ssh has none.
            for name in names where name.hasSuffix(".ctl.relay") || name.hasSuffix(".ctl") {
                if let text = try? String(contentsOfFile: hosts.appendingPathComponent(name).path, encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    stopIfOurs(pid)
                }
            }
        }
        let lock = home.appendingPathComponent(".agents-server/root/daemon.lock")
        if let text = try? String(contentsOf: lock, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            stopIfOurs(pid)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A pid left in a file here may be long gone and handed to another process, which a
    /// busy run makes likely: another test's ssh was sent SIGTERM that way (#225). So only
    /// a process whose arguments name this folder is stopped.
    private func stopIfOurs(_ pid: Int32) {
        guard pid > 0, let arguments = Self.arguments(of: pid), arguments.contains(folder.path) else { return }
        kill(pid, SIGTERM)
    }

    /// A process's executable path and arguments, as one string; nil if it is gone.
    private static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // An argc, then NUL-separated strings; only whether the folder is named matters.
        let text = buffer.dropFirst(MemoryLayout<Int32>.size).prefix(size).map { $0 == 0 ? 0x20 : $0 }
        return String(decoding: text, as: UTF8.self)
    }
}
