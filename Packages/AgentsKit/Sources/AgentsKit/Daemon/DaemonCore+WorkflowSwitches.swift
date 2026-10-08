import Foundation

/// A workflow's Enabled switch and its archive live in its own file (#125).
///
/// `enabled: false` and `archived: true` in the front matter, written by the app one key
/// at a time, so the choice travels with the project to every clone and host and shows
/// in its history. What stays here is what only this host saw: who turned it off, and
/// what the person approved.
extension DaemonCore {
    /// Write `edited` over a workflow's file, as the app's own change.
    ///
    /// Approval and the off reason are of the file's bytes, so both are carried over to
    /// the new bytes when they held for the old ones: the app changed one key the person
    /// asked for, not the workflow. A file that was waiting still waits.
    ///
    /// `carryApproval: false` leaves the new bytes waiting even if the old were approved:
    /// an agent's settings change is not the person's.
    ///
    /// Returns the new digest, or nil when nothing needed writing.
    @discardableResult
    func rewriteWorkflowFile(_ workflow: Workflow, to edited: String, from original: String,
                             in records: inout WorkflowRecords,
                             carryApproval: Bool = true) throws -> String? {
        guard edited != original else { return nil }
        let url = WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
        let before = ContentDigest.sha256(Data(original.utf8))
        let after = ContentDigest.sha256(Data(edited.utf8))
        do {
            try Data(edited.utf8).write(to: url, options: .atomic)
        } catch {
            if let failure = WriteFailure(error, keeping: url.lastPathComponent) { throw Self.refusal(failure) }
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "\(url.lastPathComponent) could not be written: \(error.localizedDescription)")
        }
        records.update(folder: workflow.folder, workflowID: workflow.workflowID) {
            if carryApproval, $0.approvedDigest == before {
                $0.approvedDigest = after
                // A refusal for waiting belonged to the file before this one.
                if case .refused(.awaitingApproval, _, _) = $0.lastOutcome { $0.lastOutcome = nil }
            }
            if $0.offDigest == before { $0.offDigest = after }
            // A denial on this host is of the bytes too (#391), and the person's own.
            if carryApproval, $0.deniedDigest == before { $0.deniedDigest = after }
        }
        return after
    }

    /// Edit one workflow's front matter with `change`, refusing in the person's words
    /// when the file cannot be read or edited exactly. Nothing is written on a refusal.
    @discardableResult
    func editWorkflowFile(_ workflow: Workflow, in records: inout WorkflowRecords,
                          _ change: (String) throws -> String) throws -> (digest: String?, text: String) {
        let url = WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
        guard let original = try? String(contentsOf: url, encoding: .utf8) else {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "\(url.lastPathComponent) could not be read.")
        }
        let edited: String
        do {
            edited = try change(original)
        } catch let refusal as FrontMatterEdit.Refusal {
            throw JSONRPCError(code: DaemonAPI.Failure.workflowUnreadable,
                               message: "\(url.lastPathComponent) was not changed: \(refusal.message).")
        }
        let digest = try rewriteWorkflowFile(workflow, to: edited, from: original, in: &records)
        return (digest ?? ContentDigest.sha256(Data(original.utf8)), edited)
    }

    /// The switch and archive kept in `workflows.json` before #125, written into each
    /// workflow's file once, then forgotten here.
    ///
    /// A file that already says the same is left alone. A file that is gone has nothing
    /// to carry. A project folder that is not there keeps its state for a later start,
    /// as does a file whose front matter cannot be edited exactly.
    func migrateWorkflowSwitchesToFiles() {
        var records = workflowStore.load()
        var touched: Set<URL> = []
        var changed = false
        for state in records.states {
            guard let legacy = state.legacy else { continue }
            guard Self.isDirectory(state.folder) else { continue }
            let url = WorkflowFile.url(for: state.workflowID, in: state.folder)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else {
                // Removed since: nothing left to say it about.
                records.update(folder: state.folder, workflowID: state.workflowID) { $0.legacy = nil }
                changed = true
                continue
            }
            let workflow = WorkflowFile.parse(original, workflowID: state.workflowID, in: state.folder)
            let off = legacy.isOff(fileSaysOff: workflow.isOff)
            do {
                var edited = try WorkflowSwitches.setting(enabled: !off, in: original)
                edited = try WorkflowSwitches.setting(archived: legacy.isArchived, in: edited)
                let digest = try rewriteWorkflowFile(workflow, to: edited, from: original, in: &records)
                    ?? ContentDigest.sha256(Data(original.utf8))
                records.update(folder: state.folder, workflowID: state.workflowID) {
                    $0.legacy = nil
                    $0.offBy = off ? legacy.offBy : nil
                    $0.offDigest = off && legacy.offBy != nil ? digest : nil
                }
                touched.insert(state.folder)
                changed = true
                DaemonLog.shared.write("wrote \(state.workflowID)'s switch and archive into its file")
            } catch {
                DaemonLog.shared.write("could not write \(state.workflowID)'s switch into its file yet: \(error)")
            }
        }
        guard changed else { return }
        keepQuietly("workflow history") { try workflowStore.save(records) }
        for folder in touched where workflows[folder] != nil { loadWorkflows(in: folder) }
    }
}
