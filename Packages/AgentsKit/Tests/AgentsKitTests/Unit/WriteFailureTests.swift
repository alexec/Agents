import Foundation
import Testing
@testable import AgentsKitCore

/// A full disk and a refused folder, in words (#88).
struct WriteFailureTests {
    @Test func aFullDiskSaysWhatWasNotKeptAndWhatToDo() throws {
        let error = CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/tmp/x/projects.json"])
        let failure = try #require(WriteFailure(error, keeping: "the project list", machine: "Your Mac"))
        #expect(failure.cause == .diskFull)
        #expect(failure.path == "/tmp/x/projects.json")
        #expect(failure.message == "Your Mac is out of disk space, so the project list could not be saved. Free some space, then try again.")
    }

    @Test func anErrnoUnderACocoaErrorIsFound() throws {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                            userInfo: [NSUnderlyingErrorKey: posix, NSFilePathErrorKey: "/tmp/t.jsonl"])
        let failure = try #require(WriteFailure(error, keeping: "a line of the chat"))
        #expect(failure.cause == .diskFull)
        #expect(failure.path == "/tmp/t.jsonl")
    }

    @Test func aRefusedFolderIsNamedWithTheHomeAsATilde() throws {
        let home = NSHomeDirectory()
        let folder = (home.hasSuffix("/") ? home : home + "/") + "Code/app"
        let error = CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: folder])
        let failure = try #require(WriteFailure(error, keeping: "the workflow", machine: "Your Mac"))
        #expect(failure.cause == .notAllowed)
        #expect(failure.message.hasPrefix("Agents is not allowed to write to “~/Code/app”, so the workflow could not be saved."))
    }

    @Test func posixErrorsMapToTheirCauses() {
        #expect(WriteFailure(POSIXError(.EDQUOT), keeping: "it")?.cause == .diskFull)
        #expect(WriteFailure(POSIXError(.EACCES), keeping: "it")?.cause == .notAllowed)
        #expect(WriteFailure(POSIXError(.EPERM), keeping: "it")?.cause == .notAllowed)
        #expect(WriteFailure(POSIXError(.EROFS), keeping: "it")?.cause == .readOnly)
    }

    @Test func anythingElseIsNotDressedUpAsAdvice() {
        #expect(WriteFailure(CocoaError(.fileReadCorruptFile), keeping: "it") == nil)
        #expect(WriteFailure(POSIXError(.ENOENT), keeping: "it") == nil)
        #expect(WriteFailure(gitMessage: "fatal: invalid reference: main", keeping: "it") == nil)
    }

    @Test func gitsOwnWordsAreRead() {
        let full = "error: unable to write file .git/index: No space left on device"
        #expect(WriteFailure(gitMessage: full, keeping: "the worktree")?.cause == .diskFull)
        let refused = "fatal: could not create leading directories of '/x/y': Permission denied"
        #expect(WriteFailure(gitMessage: refused, keeping: "the worktree")?.cause == .notAllowed)
    }
}
