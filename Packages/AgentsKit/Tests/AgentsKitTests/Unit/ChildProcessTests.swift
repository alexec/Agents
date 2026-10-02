import AgentsKitCore
import Foundation
import Testing

/// A short command run to its end (#92): output past a pipe's 64 KB comes back whole,
/// and one that never ends is stopped at its deadline.
@Suite("A child process run to its end", .timeLimit(.minutes(1)))
struct ChildProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func outputLargerThanThePipeComesBackWhole() async {
        // 200,000 bytes on each pipe: three times what either holds.
        let outcome = await ChildProcess.run(shell, ["-c", "head -c 200000 /dev/zero; head -c 200000 /dev/zero >&2"],
                                             deadline: .seconds(20))
        #expect(!outcome.timedOut)
        #expect(outcome.status == 0)
        #expect(outcome.output.count == 200_000)
        #expect(outcome.errors.count == 200_000)
    }

    @Test func theStatusAndTextAreKept() async {
        let outcome = await ChildProcess.run(shell, ["-c", "printf hello; printf oops >&2; exit 3"])
        #expect(outcome.status == 3)
        #expect(outcome.text == "hello")
        #expect(outcome.errorText == "oops")
    }

    @Test func aChildPastItsDeadlineIsStopped() async {
        let started = Date()
        let outcome = await ChildProcess.run(shell, ["-c", "printf begun; exec sleep 30"], deadline: .milliseconds(500))
        #expect(outcome.timedOut)
        #expect(outcome.status == -1)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aMissingProgramSaysWhy() async {
        let outcome = await ChildProcess.run(URL(fileURLWithPath: "/nonexistent/tool"), [])
        #expect(outcome.status == -1)
        #expect(outcome.failure != nil)
    }
}
