import Foundation
import Testing
@testable import AgentsKitCore

/// Why Agents Host's login items aren't running, read from launchd (#678).
@Suite("Agents Host's job diagnosis")
struct HostJobDiagnosisTests {
    private let running = """
    gui/501/com.alexecollins.agentshost.daemon = {
    \tactive count = 1
    \tstate = running

    \targuments = {
    \t\tagentsd
    \t}
    \tLWCR = {
    \t\t"vers" => 1
    \t}
    \truns = 20
    \tpid = 43038
    \tendpoints = {
    \t\t"x" = {
    \t\t\tstate = active
    \t\t}
    \t}
    \tjob state = running
    \tproperties = partial import | keepalive | runatload | has LWCR
    }
    """

    private let spawnFailed = """
    gui/501/com.alexecollins.agentshost.control = {
    \tactive count = 0
    \tstate = not running
    \truns = 3
    \tlast exit code = 78: EX_CONFIG
    \tjob state = spawn failed
    \tproperties = keepalive | runatload | needs LWCR update
    }
    """

    @Test func aRunningJobHasItsPidAndNoFailure() {
        let job = LaunchJobState.parse(running, exitStatus: 0)
        #expect(job.running)
        #expect(job.pid == 43038)
        #expect(job.runs == 20)
        #expect(!job.needsLWCRUpdate)
        #expect(HostJobFailure.diagnose(job, login: .enabled) == nil)
    }

    @Test func nestedStatesAreNotTheJobs() {
        let job = LaunchJobState.parse(running, exitStatus: 0)
        #expect(job.state == "running")
    }

    @Test func aSpawnFailedJobSaysItsExitAndConstraint() {
        let job = LaunchJobState.parse(spawnFailed, exitStatus: 0)
        #expect(!job.running)
        #expect(job.state == "spawn failed")
        #expect(job.lastExitCode == 78)
        #expect(job.lastExit == "78: EX_CONFIG")
        #expect(job.needsLWCRUpdate)
        #expect(job.summary == "spawn failed, last exit 78: EX_CONFIG, 3 runs, needs LWCR update")
        // The constraint is the cause to name: Repair re-registers it.
        #expect(HostJobFailure.diagnose(job, login: .enabled) == .staleRegistration)
    }

    @Test func exit78WithoutTheConstraintCouldNotStart() {
        var job = LaunchJobState.parse(spawnFailed, exitStatus: 0)
        job.needsLWCRUpdate = false
        let failure = HostJobFailure.diagnose(job, login: .enabled)
        #expect(failure == .couldNotStart(lastExit: "78: EX_CONFIG"))
        #expect(failure?.repairable == true)
        #expect(failure?.reason("The control plane").hasPrefix("macOS couldn’t start the control plane (last exit 78: EX_CONFIG).") == true)
    }

    @Test func anUnknownLabelIsNotLoaded() {
        let job = LaunchJobState.parse("Could not find service \"x\" in domain for user gui: 501", exitStatus: 113)
        #expect(job == .notLoaded)
        #expect(job.summary == "not loaded")
        #expect(HostJobFailure.diagnose(job, login: .notRegistered) == .notRegistered)
        // Registered with macOS and unknown to launchd: the registration is stale.
        #expect(HostJobFailure.diagnose(job, login: .enabled) == .staleRegistration)
    }

    @Test func approvalComesFirstAndIsNotRepaired() {
        let failure = HostJobFailure.diagnose(.notLoaded, login: .requiresApproval)
        #expect(failure == .needsApproval)
        #expect(failure?.repairable == false)
    }

    @Test func betweenStartsWithNothingAgainstItIsStillStarting() {
        let job = LaunchJobState(loaded: true, state: "spawn scheduled", runs: 1)
        #expect(HostJobFailure.diagnose(job, login: .enabled) == nil)
    }

    @Test func aJobThatKeepsExitingSaysSo() {
        let job = LaunchJobState(loaded: true, state: "not running", lastExitCode: 1, lastExit: "1", runs: 4)
        #expect(HostJobFailure.diagnose(job, login: .scratch) == .keepsStopping(lastExit: "1"))
    }

    @Test func codesKeysAndTokensAreRedacted() {
        let text = """
        joining with agents-control:2:h:abcDEF123456
        secretKey=AKIAABCDEFGH token: "xyz" password = hunter2
        signature 3q2+7wABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd==
        log at /Users/alex/Library/Application Support/Agents Control/control.log
        connection refused at 127.0.0.1:8791
        """
        let out = DiagnosticRedaction.redact(text)
        #expect(!out.contains("abcDEF123456"))
        #expect(!out.contains("AKIAABCDEFGH"))
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("xyz"))
        #expect(!out.contains("3q2+7wABCDEF"))
        #expect(out.contains("agents-control:<redacted>"))
        #expect(out.contains("/Users/alex/Library/Application Support/Agents Control/control.log"))
        #expect(out.contains("connection refused at 127.0.0.1:8791"))
    }
}
