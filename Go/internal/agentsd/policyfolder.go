package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/policylayers"
	"github.com/alexec/agents/Go/wire"
)

// A folder's own layer (#2957, US3): .agents/policy.json, committed with the folder's
// code. It is a guarded file (guarded.go, #502), with a tighter-only fast path (research
// R10): a change from outside the app that only tightens a rule applies at once; one that
// loosens any rule, or that is not a valid layer, waits for the person's OK, as every other
// guarded file does (Allow, Keep <old>/Undo, Show Change). The app's own write
// (policy/setFolder) always approves itself, as approveWrite does for any guarded file.

// validPolicyRules says whether data reads as a layer policylayers.Validate accepts.
func validPolicyRules(data []byte) bool {
	_, err := policylayers.Validate(data)
	return err == nil
}

// folderApprovedRules is the folder's approved copy, decoded (data-model.md "A folder's
// layer"): empty when there is none yet, or the last approved content fails to decode (it
// never should, since only valid content is ever approved).
func (d *Daemon) folderApprovedRules(folder string) wire.PolicyRules {
	d.guardedMu.Lock()
	s, _ := d.stateOf(folder, folderPolicyFile)
	approved := s.ApprovedContent
	d.guardedMu.Unlock()
	if len(approved) == 0 {
		return wire.PolicyRules{}
	}
	rules, err := policylayers.Validate(approved)
	if err != nil {
		return wire.PolicyRules{}
	}
	return rules
}

// checkFolderPolicyGuarded is checkGuarded for .agents/policy.json: a change from outside
// the app applies at once when it is never looser than the approved copy (policylayers.
// Looser), or when it is invalid (so the folder is never left with no file at all reading
// as empty rules); it waits, with the last approved copy applying, when it loosens any
// rule. Called instead of checkGuarded's own switch, which decides by whether an agent is
// working there: that question does not apply to a folder's own rules.
func (d *Daemon) checkFolderPolicyGuarded(folder string) {
	digest, data := diskRead(folder, folderPolicyFile)
	d.guardedMu.Lock()
	s, known := d.stateOf(folder, folderPolicyFile)
	moved, tightened := false, false
	switch {
	case !known && (len(data) == 0 || validPolicyRules(data)):
		// First seen: a missing file sets nothing, and a file already there (committed
		// before this machine ever looked) is trusted only when it is valid.
		s.ApprovedDigest, s.ApprovedContent, moved = digest, data, true
	case same(s.ApprovedDigest, digest):
		if s.Pending != nil {
			s.Pending, moved = nil, true
		}
	case s.Pending != nil && same(s.Pending.Digest, digest):
		// Already pending this exact change.
	default:
		var approved wire.PolicyRules
		if s.ApprovedContent != nil {
			approved, _ = policylayers.Validate(s.ApprovedContent)
		}
		next, err := policylayers.Validate(data)
		if err == nil && !policylayers.Looser(approved, next) {
			s.ApprovedDigest, s.ApprovedContent, s.Pending = digest, data, nil
			tightened, moved = true, true
		} else {
			s.Pending = &guardedPending{Digest: digest, Since: now(), ChangedByIDs: []wire.UUID{}, ChangedBy: []string{}}
			moved = true
		}
	}
	if moved {
		d.saveGuarded()
	}
	d.guardedMu.Unlock()
	if !moved {
		return
	}
	if tightened {
		log.Printf("policy.folderTightened: %s", folder)
		d.policyChanged()
		tellPolicyEffectiveChanged(d, folder)
	}
	d.guardedFilesMoved(folder)
}

// folderPolicyState is policy/folder: the folder's approved layer, a waiting change, and
// why a pending change is invalid, when that is why it is pending.
func (d *Daemon) folderPolicyState(folder string) (wire.PolicyFolderState, error) {
	if _, ok := d.summaryFor(folder); !ok {
		return wire.PolicyFolderState{}, noSuchFolder(folder + " is not a folder.")
	}
	d.checkFolderPolicyGuarded(folder)
	out := wire.PolicyFolderState{Rules: d.folderApprovedRules(folder)}
	for _, c := range d.guardedFileChanges(folder) {
		if c.Path != folderPolicyFile {
			continue
		}
		pending := c
		out.Pending = &pending
		if c.Digest != nil {
			if _, data := diskRead(folder, folderPolicyFile); data != nil {
				if _, err := policylayers.Validate(data); err != nil {
					s := err.Error()
					out.Invalid = &s
				}
			}
		}
		break
	}
	return out, nil
}

// folderPolicyOrdered is .agents/policy.json's bytes, in FR-014's stable order: only the
// rules the folder sets, sorted keys, two-space indents, a trailing newline, so a diff
// shows only the changed rule. PolicyRules' fields keep struct order when marshaled
// directly, so the round trip through a generic map[string]any is what gives every
// object's keys the sorted order encoding/json already gives a map.
func folderPolicyOrdered(rules wire.PolicyRules) ([]byte, error) {
	raw, err := json.Marshal(rules)
	if err != nil {
		return nil, err
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, err
	}
	out, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(out, '\n'), nil
}

// setFolderPolicy is policy/setFolder (#2957, FR-014): writes .agents/policy.json in the
// stable order and approves it at once, as the app's own writes to a guarded file always
// are. A value looser than the person's own effective value outside this folder is kept in
// the file (so a looser folder still reads back what the person chose) but marked capped
// in the result's caller (policy/folder, Agents > Policy); this method itself only writes
// and approves.
func (d *Daemon) setFolderPolicy(r wire.SetFolderPolicyRequest) (wire.PolicyRules, error) {
	folder := store.FolderPath(r.Folder)
	if _, ok := d.summaryFor(folder); !ok {
		return wire.PolicyRules{}, noSuchFolder(folder + " is not a folder.")
	}
	raw, err := json.Marshal(r.Rules)
	if err != nil {
		return wire.PolicyRules{}, Invalid("%v", err)
	}
	if _, err := policylayers.Validate(raw); err != nil {
		return wire.PolicyRules{}, Invalid("%v", err)
	}
	if !isDir(folder) {
		return wire.PolicyRules{}, noSuchFolder(folder + " is not there, so its policy cannot be written.")
	}
	b, err := folderPolicyOrdered(r.Rules)
	if err != nil {
		return wire.PolicyRules{}, Invalid("%v", err)
	}
	path := filepath.Join(folder, folderPolicyFile)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return wire.PolicyRules{}, &Error{Code: CodeInternal, Message: folderPolicyFile + " could not be written: " + err.Error()}
	}
	if err := store.WriteAtomically(path, b, 0o644); err != nil {
		return wire.PolicyRules{}, &Error{Code: CodeInternal, Message: folderPolicyFile + " could not be written: " + err.Error()}
	}
	d.approveWrite(folder, folderPolicyFile)
	d.guardedFilesMoved(folder)
	d.policyChanged()
	tellPolicyEffectiveChanged(d, folder)
	return r.Rules, nil
}

// tellPolicyEffectiveChanged is policy/effectiveChanged for folder's own layer (contracts/
// policy-layers-api.md): clients watching that folder call policy/effective again.
func tellPolicyEffectiveChanged(d *Daemon, folder string) {
	f := store.FolderURL(folder)
	Broadcast(d, wire.NotifyPolicyEffectiveChanged, wire.PolicyEffectiveRequest{Folder: &f})
}

func (d *Daemon) registerPolicyFolder() {
	On(d, wire.CallPolicyFolder, func(_ context.Context, c *Client, r wire.PolicyFolderRequest) (wire.PolicyFolderState, error) {
		return d.folderPolicyState(store.FolderPath(r.Folder))
	})
	On(d, wire.CallPolicySetFolder, func(_ context.Context, c *Client, r wire.SetFolderPolicyRequest) (wire.PolicyRules, error) {
		return d.setFolderPolicy(r)
	})
}
