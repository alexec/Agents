import Foundation
import Testing
@testable import AgentsKit

/// A command that printed something never comes back empty.
///
/// The bug these are here for: the pipe was read by a readability handler, and the
/// process's termination handler cancelled that handler. For a command like `echo`,
/// which writes a few bytes and exits in microseconds, the exit often won the race and
/// the bytes were left unread in the pipe forever — so the agent got an empty result,
/// silently, with an exit code of zero. Under load it happened several times in a
/// hundred, which is why it read as a flaky test rather than as lost output.
@Suite("A terminal's output comes back")
struct TerminalOutputTests {
    private func service() -> (TerminalService, URL) {
        let cwd = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        return (TerminalService(scope: FolderScope(folders: [cwd]), defaultCWD: cwd), cwd)
    }

    /// Short-lived commands, many at once, because the race is lost more often the
    /// busier the machine is. Every one of them must come back with what it printed.
    @Test func everyShortCommandComesBackWithItsOutput() async throws {
        let (terminals, cwd) = service()
        let count = 60
        let missing = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for n in 0 ..< count {
                group.addTask {
                    let token = "probe-\(n)"
                    guard let id = try? await terminals.create(command: "echo", args: [token],
                                                               cwd: cwd.path, env: nil) else {
                        return token
                    }
                    _ = await terminals.waitForExit(id: id)
                    let output = await terminals.output(id: id)["output"]?.stringValue ?? ""
                    await terminals.release(id: id)
                    return output.contains(token) ? nil : token
                }
            }
            var lost: [String] = []
            for await result in group {
                if let result { lost.append(result) }
            }
            return lost
        }
        #expect(missing.isEmpty,
                "\(missing.count) of \(count) commands came back without their output: \(missing.sorted())")
    }

    /// Waiting for the exit and then asking for the output is the order an agent uses.
    /// The output has to be all there by the time the wait returns, not a beat later.
    @Test func theOutputIsWholeAsSoonAsTheCommandHasExited() async throws {
        let (terminals, cwd) = service()
        let expected = (1...2000).map(String.init).joined(separator: "\n") + "\n"
        let wrong = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    guard let id = try? await terminals.create(command: "seq", args: ["1", "2000"],
                                                               cwd: cwd.path, env: nil) else {
                        return true
                    }
                    _ = await terminals.waitForExit(id: id)
                    let output = await terminals.output(id: id)["output"]?.stringValue ?? ""
                    await terminals.release(id: id)
                    return output != expected
                }
            }
            var bad = 0
            for await isWrong in group where isWrong { bad += 1 }
            return bad
        }
        #expect(wrong == 0, "\(wrong) of 8 commands came back truncated or out of order")
    }
}
