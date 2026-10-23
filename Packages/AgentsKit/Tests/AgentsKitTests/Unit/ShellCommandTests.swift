import Foundation
import Testing
@testable import AgentsKitCore

/// Run a shell command from a reply (#1533): which blocks run, what is typed, and what Tell
/// the Agent says the shell printed.
@Suite("Shell commands in replies")
struct ShellCommandTests {
    @Test func aShellBlockIsItsCommand() {
        #expect(ShellCommand.runnable(tag: "bash", text: "swift test\n") == "swift test")
        #expect(ShellCommand.runnable(tag: "SH", text: "cd Web\nnpm test") == "cd Web\nnpm test")
        #expect(ShellCommand.runnable(tag: "zsh title=run", text: "make") == "make")
    }

    @Test func otherBlocksAndEmptyOnesDoNotRun() {
        #expect(ShellCommand.runnable(tag: "swift", text: "print(1)") == nil)
        #expect(ShellCommand.runnable(tag: nil, text: "ls") == nil)
        #expect(ShellCommand.runnable(tag: "bash", text: "  \n") == nil)
    }

    @Test func aConsoleRunsOnlyWhatWasTypedAtAPrompt() {
        let screen = "$ git status\nOn branch main\n% swift build\nBuild complete!"
        #expect(ShellCommand.runnable(tag: "console", text: screen) == "git status\nswift build")
        #expect(ShellCommand.runnable(tag: "console", text: "nothing typed") == nil)
    }

    @Test func eachLineIsTypedWithReturn() {
        #expect(ShellCommand.typed("cd Web\nnpm test") == Data("cd Web\rnpm test\r".utf8))
    }

    @Test func theTailIsPlainTextAndBounded() {
        let printed = "\r\n\u{1B}]0;title\u{07}\u{1B}[1;31merror:\u{1B}[0m it broke\r\n"
            + "50%\r100%\r\n" + (1...50).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n\r\n"
        let tail = ShellCommand.tail(Data(printed.utf8), lines: 3)
        #expect(tail == "line 48\nline 49\nline 50")
        let all = ShellCommand.tail(Data(printed.utf8), lines: 100)
        #expect(all.hasPrefix("error: it broke\n100%\nline 1\n"))
    }

    @Test func theReportHasTheCommandAndWhatItPrinted() {
        let report = ShellCommand.report(command: "make", printed: "error: no rule")
        #expect(report.contains("```sh\nmake\n```"))
        #expect(report.contains("```\nerror: no rule\n```"))
        #expect(ShellCommand.report(command: "true", printed: "").contains("(It printed nothing.)"))
    }

    @Test func sharedTellAgentActionBuildsTheReportFromRecentShellOutput() {
        let report = ShellCommandActions.report("make", recent: Data("error: no rule\n".utf8))
        #expect(report == ShellCommand.report(command: "make", printed: "error: no rule"))
        #expect(ShellCommandActions.report("true", recent: Data()).contains("(It printed nothing.)"))
        #expect(ShellCommandActions.unavailableMessage == "The session's shell did not start, so the command did not run.")
    }
}
