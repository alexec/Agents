package mcpevents

import (
	"slices"
	"strings"
)

// pr.blocked (#5321): an open pull request that cannot merge until its author acts. Every
// forge server reads what it can of a PR into a Blocking; Blocked makes its state for
// Poller.Diff, so the reasons, the ids and the payload are the same on every forge.

// The reasons of pr.blocked, in the order its payload lists them.
const (
	ReasonConflict            = "conflict"
	ReasonRequiredCheckFailed = "required_check_failed"
	ReasonChangesRequested    = "changes_requested"
	ReasonAutomergeDisabled   = "automerge_disabled"
	ReasonBehind              = "behind"
)

// BlockedReasons are every reason, in order.
var BlockedReasons = []string{ReasonConflict, ReasonRequiredCheckFailed, ReasonChangesRequested, ReasonAutomergeDisabled, ReasonBehind}

// FailedCheck is a required check that failed on the PR's head: its name and where to see it.
type FailedCheck struct {
	Name string
	URL  string
}

// Blocking is what a forge says of one open pull request: why it cannot merge until its
// author acts. A check that still runs, or a PR that waits for a person's approval, is no
// reason: that needs the person, or time, not the author.
type Blocking struct {
	HeadSHA          string
	Conflict         bool
	FailedChecks     []FailedCheck
	ChangesRequested bool
	// ReviewURL is the review that asks for changes, when the forge says one.
	ReviewURL         string
	AutomergeDisabled bool
	// Behind: the base's rule wants the branch up to date with its base, and it is not.
	Behind bool
	// ChecksRunning: a required check still runs on the head. A required check that failed
	// on the same head at the last poll is still a reason, so a rerun that fails again on the
	// same head raises no second event.
	ChecksRunning bool
	// Unknown: the forge still works out whether it can merge (after a push or a new base).
	// It keeps the state it had at the last poll.
	Unknown bool
}

// Reasons are its reasons, in order.
func (b Blocking) Reasons() []string {
	var out []string
	if b.Conflict {
		out = append(out, ReasonConflict)
	}
	if len(b.FailedChecks) > 0 {
		out = append(out, ReasonRequiredCheckFailed)
	}
	if b.ChangesRequested {
		out = append(out, ReasonChangesRequested)
	}
	if b.AutomergeDisabled {
		out = append(out, ReasonAutomergeDisabled)
	}
	if b.Behind {
		out = append(out, ReasonBehind)
	}
	return out
}

// BlockedState is pr.blocked's state of one PR, for a Diff State: its id, whether it is
// blocked, its envelope key (the head and the reasons), and the data the forge adds to its PR.
type BlockedState struct {
	ID   string
	On   bool
	Key  string
	Data map[string]any
}

// Blocked is the state of a PR as b says. prefix is its id without the state, as
// "pr.blocked:owner/name:12"; was are the ids of the last poll's cursor (what was blocked
// then). The id holds the head and the reasons, so a new head or a new set of reasons is a
// new event, and the same head with the same reasons is not.
func Blocked(prefix string, b Blocking, was []string) BlockedState {
	if b.Unknown {
		for _, id := range was {
			if key, ok := strings.CutPrefix(id, prefix+":"); ok {
				return BlockedState{ID: id, On: true, Key: key}
			}
		}
		return BlockedState{ID: prefix + ":", Key: ""}
	}
	reasons := b.Reasons()
	if b.ChecksRunning && !slices.Contains(reasons, ReasonRequiredCheckFailed) {
		head := prefix + ":" + b.HeadSHA + ":"
		for _, id := range was {
			if rest, ok := strings.CutPrefix(id, head); ok && slices.Contains(strings.Split(rest, ","), ReasonRequiredCheckFailed) {
				reasons = append(reasons, ReasonRequiredCheckFailed)
				reasons = ordered(reasons)
				break
			}
		}
	}
	key := b.HeadSHA + ":" + strings.Join(reasons, ",")
	checks := []any{}
	for _, c := range b.FailedChecks {
		checks = append(checks, map[string]any{"name": c.Name, "url": c.URL})
	}
	list := []any{}
	for _, r := range reasons {
		list = append(list, r)
	}
	data := map[string]any{"headSha": b.HeadSHA, "reasons": list, "failedChecks": checks}
	if b.ChangesRequested && b.ReviewURL != "" {
		data["reviewUrl"] = b.ReviewURL
	}
	return BlockedState{ID: prefix + ":" + key, On: len(reasons) > 0, Key: key, Data: data}
}

func ordered(reasons []string) []string {
	var out []string
	for _, r := range BlockedReasons {
		if slices.Contains(reasons, r) {
			out = append(out, r)
		}
	}
	return out
}

// BlockedPayload is pr.blocked's payload schema, with pr the forge's own PR schema.
func BlockedPayload(pr map[string]any) map[string]any {
	str := map[string]any{"type": "string"}
	return map[string]any{"type": "object", "properties": map[string]any{
		"pr": pr, "headSha": str, "blockedAt": str,
		"reasons": map[string]any{"type": "array", "items": map[string]any{"type": "string", "enum": BlockedReasons}},
		"failedChecks": map[string]any{"type": "array", "items": map[string]any{"type": "object",
			"properties": map[string]any{"name": str, "url": str}}},
		"reviewUrl": str,
	}}
}

// BlockedDescription is pr.blocked's description; reads says which reasons the forge reads
// and how.
func BlockedDescription(reads string) string {
	return "An open pull request went into a state where it cannot merge until its author acts: reasons are one or more of " +
		"conflict, required_check_failed (failedChecks names them), changes_requested (reviewUrl is the review), automerge_disabled " +
		"(the forge turned auto-merge off) and behind (the base's rule wants the branch up to date, and it is not). " +
		"Raised when the PR goes from not blocked to blocked, or when its head or its set of reasons changes; never twice for the same head and reasons, " +
		"so a rerun that fails again on the same head is no new one. A check still running, a draft, and a PR that waits for a person's approval " +
		"(labelled needs-approval, or a review a person must give) are no reason. " + reads
}

// SkipsBlocked is whether a PR is never blocked: a draft, or one labelled needs-approval,
// which waits for a person, not its author.
func SkipsBlocked(draft bool, labels []string) bool {
	return draft || slices.Contains(labels, "needs-approval")
}

// CursorIDs are the ids in p's cursor, none on a first poll or a cursor this server did not
// give (Diff refuses that one).
func (pl Poller) CursorIDs(p Params) []string {
	if p.FirstPoll() {
		return nil
	}
	c, bad := pl.Decode(p.Cursor)
	if bad != nil {
		return nil
	}
	return c.IDs
}
