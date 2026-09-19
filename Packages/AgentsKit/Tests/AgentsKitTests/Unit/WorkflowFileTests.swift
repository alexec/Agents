import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a workflow file says, and what happens to one that cannot say it.
///
/// The line this suite is really about is the one between a file that is broken and a
/// file that is from the future. The first needs somebody; the second needs leaving
/// alone. Treating them the same is how a format stops being able to grow.
@Suite("Reading a workflow file")
struct WorkflowFileTests {
    private let project = URL(filePath: "/tmp/a-project")

    private func parse(_ text: String, id: String = "morning-build-check") -> Workflow {
        WorkflowFile.parse(text, workflowID: id, in: project)
    }

    // MARK: The documented shape

    private let sample = """
        ---
        name: Morning build check
        on:
          - schedule:
              at: [":00", ":30"]
              between: "09:00-18:00"
              days: [mon, tue, wed, thu, fri]
        agent: new
        ---

        Check whether the build is still green. If it isn't, find out what broke it
        and tell me in one paragraph. Don't fix anything.
        """

    @Test func theSampleFromTheContractReadsAsWritten() {
        let workflow = parse(sample)
        #expect(workflow.problem == nil)
        #expect(workflow.name == "Morning build check")
        #expect(workflow.mode == .new)
        #expect(workflow.triggers.count == 1)
        guard let schedule = workflow.schedules.first else {
            Issue.record("expected a schedule")
            return
        }
        #expect(schedule.minutes == [0, 30])
        #expect(schedule.hours == 9...18)
        #expect(schedule.days == Weekday.weekdays)
        #expect(workflow.prompt.hasPrefix("Check whether the build is still green"))
        #expect(workflow.prompt.hasSuffix("Don't fix anything."))
    }

    @Test func theSummaryReadsLikeSomethingAPersonWouldSay() {
        // One renderer, read by the project-page row and by the confirmation an agent's
        // write raises. If this reads badly, both read badly.
        #expect(parse(sample).summary == "Every weekday on the hour and half hour between 9am and 6pm, in a new agent")
    }

    @Test func theNameFallsBackToTheFileName() {
        let workflow = parse("""
            ---
            on: agent-finished
            ---

            Say something.
            """, id: "review-what-just-finished")
        #expect(workflow.name == "Review what just finished")
    }

    @Test func bareTriggersNeedNoSettings() {
        let workflow = parse("""
            ---
            on:
              - agent-finished
              - agent-stopped
            agent: triggering
            ---

            Look at what happened.
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.agentFinished, .agentStopped])
        #expect(workflow.mode == .triggering)
    }

    @Test func workflowCompletedTakesAnOptionalName() {
        let anyOne = parse("---\non: workflow-completed\n---\n\nGo.")
        #expect(anyOne.triggers == [.workflowCompleted(id: nil)])
        let namedOne = parse("""
            ---
            on:
              - workflow-completed:
                  id: morning-build-check
            ---

            Go.
            """)
        #expect(namedOne.triggers == [.workflowCompleted(id: "morning-build-check")])
    }

    @Test func commentsAndBlankLinesAreNotContent() {
        let workflow = parse("""
            ---
            # what this is for
            on:

              - agent-finished   # every time
            ---

            Go.
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.agentFinished])
    }

    // MARK: Files from the future

    @Test func anUnknownTriggerIsInertRatherThanBroken() {
        let workflow = parse("""
            ---
            on:
              - deploys-finished:
                  environment: production
            ---

            Check the deploy.
            """)
        #expect(workflow.problem == .triggerNotSupported("deploys-finished"))
        #expect(!workflow.canFire)
        // Kept whole, with what it came with, so a later version finds it unchanged.
        #expect(workflow.triggers == [.unrecognised(name: "deploys-finished",
                                                    keys: ["environment": .string("production")])])
    }

    @Test func anUnknownModeIsInertRatherThanBroken() {
        let workflow = parse("---\non: agent-finished\nagent: swarm\n---\n\nGo.")
        #expect(workflow.problem == .unsupportedMode("swarm"))
        #expect(!workflow.canFire)
    }

    @Test func aWorkflowWithOneKnownTriggerAmongUnknownOnesStillFires() {
        let workflow = parse("""
            ---
            on:
              - deploys-finished
              - agent-finished
            ---

            Go.
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.canFire)
        #expect(workflow.supportedTriggers == [.agentFinished])
    }

    @Test func unknownTopLevelKeysAreKeptRatherThanDropped() {
        let workflow = parse("""
            ---
            on: agent-finished
            retries: 3
            ---

            Go.
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.unknownFields["retries"] == .string("3"))
    }

    // MARK: Files that are broken

    @Test func aFileWithNoMetadataBlockIsUnreadable() {
        let workflow = parse("Just a prompt, with nothing above it.")
        #expect(workflow.problem == .unreadable("This file does not start with a metadata block"))
    }

    @Test func anUnclosedMetadataBlockIsUnreadable() {
        let workflow = parse("---\non: agent-finished\n\nGo.")
        #expect(workflow.problem == .unreadable("The metadata block is never closed"))
    }

    @Test func aMissingOnKeyIsUnreadable() {
        let workflow = parse("---\nagent: new\n---\n\nGo.")
        #expect(workflow.problem == .unreadable("The metadata does not say what makes this run"))
    }

    @Test func anEmptyBodyIsUnreadable() {
        // A workflow with nothing to say is a scheduled no-op.
        let workflow = parse("---\non: agent-finished\n---\n\n   \n")
        #expect(workflow.problem == .unreadable("There is no prompt under the metadata"))
    }

    @Test func aFinerScheduleThanAHalfHourIsRefusedRatherThanRounded() {
        let workflow = parse("""
            ---
            on:
              - schedule:
                  at: [":15"]
            ---

            Go.
            """)
        guard case .unreadable(let why) = workflow.problem else {
            Issue.record("expected unreadable, got \(String(describing: workflow.problem))")
            return
        }
        #expect(why.contains("\":15\""))
        #expect(why.contains("\":00\" and \":30\""))
    }

    @Test func aScheduleWithNoTimeIsUnreadable() {
        let workflow = parse("---\non:\n  - schedule:\n      days: [mon]\n---\n\nGo.")
        #expect(workflow.problem == .unreadable("A schedule must say what time with `at:`"))
    }

    @Test func aRangeThatIsNotOneIsUnreadable() {
        let workflow = parse("""
            ---
            on:
              - schedule:
                  at: [":00"]
                  between: "tea time"
            ---

            Go.
            """)
        guard case .unreadable(let why) = workflow.problem else {
            Issue.record("expected unreadable")
            return
        }
        #expect(why.contains("tea time"))
    }

    @Test func aDayThatIsNotOneIsUnreadable() {
        let workflow = parse("""
            ---
            on:
              - schedule:
                  at: [":00"]
                  days: [caturday]
            ---

            Go.
            """)
        #expect(workflow.problem == .unreadable("\"caturday\" is not a day of the week"))
    }

    // MARK: On disk

    @Test func aFileIsReadFromTheProjectsWorkflowFolder() throws {
        let project = URL.temporaryDirectory.appending(path: "wf-\(UUID().uuidString)")
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: "standup-notes", in: project)
        try Data(sample.utf8).write(to: url)

        let workflow = WorkflowFile.read(url, in: project)
        #expect(workflow.workflowID == "standup-notes")
        #expect(workflow.problem == nil)
        #expect(workflow.folder == Project.standardize(project))
    }

    @Test func aHorizontalRuleInTheBodyIsNotAMetadataFence() {
        // The positional rule, which is the one that is easy to get backwards and eats
        // the top of a document when you do.
        let workflow = parse("""
            ---
            on: agent-finished
            ---

            First paragraph.

            ---

            Second paragraph.
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.prompt.contains("---"))
        #expect(workflow.prompt.contains("Second paragraph."))
    }
}
