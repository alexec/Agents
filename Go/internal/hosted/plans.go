package hosted

import (
	"fmt"
	"time"
)

// Plans (#2224, spec 1003 FR-020): each account has one, and agents-hosted holds its
// control plane to its limits (limits.go). Changing a number here is the whole change.

// Plan is a plan's name and limits.
type Plan struct {
	// The name an account's record keeps: "free" or "pro".
	ID string
	// The name a person reads.
	Name string
	// Machines joined and clients paired.
	Machines, Clients int
	// WebSockets open at once at the account's control plane.
	Connections int
	// The account's whole store, in bytes.
	Storage int64
	// How long its events (the audit) are kept.
	EventsKept time.Duration
	// Agents running at once (#2243): the control plane refuses to start one more.
	AgentsRunning int
}

const (
	PlanFree = "free"
	PlanPro  = "pro"
	day      = 24 * time.Hour
	gigabyte = int64(1) << 30
)

var plans = map[string]Plan{
	PlanFree: {ID: PlanFree, Name: "Free", Machines: 2, Clients: 5, Connections: 20, Storage: 1 * gigabyte,
		EventsKept: 7 * day, AgentsRunning: 3},
	PlanPro: {ID: PlanPro, Name: "Pro", Machines: 20, Clients: 50, Connections: 200, Storage: 20 * gigabyte,
		EventsKept: 90 * day, AgentsRunning: 30},
}

// PlanOf is an account's plan: free when it names none, or one not known.
func PlanOf(acc *Account) Plan {
	if acc != nil {
		if p, ok := plans[acc.Plan]; ok {
			return p
		}
	}
	return plans[PlanFree]
}

// ValidPlan says whether id names a plan.
func ValidPlan(id string) bool {
	_, ok := plans[id]
	return ok
}

// LimitError is a refusal at a plan's limit, in the words a person reads (FR-022).
type LimitError struct {
	Plan  Plan
	Limit string
	// What the plan allows, in words: "2 machines".
	Allows string
	// What to do instead of upgrading: "Remove one".
	Do string
	// Where to upgrade: the account page.
	Account string
}

func (e *LimitError) Error() string {
	return fmt.Sprintf("Your %s plan allows %s. %s, or upgrade at %s.", e.Plan.Name, e.Allows, e.Do, e.Account)
}

// bytesText is a size in words: "1 GB", "120 MB".
func bytesText(n int64) string {
	switch {
	case n >= gigabyte && n%gigabyte == 0:
		return fmt.Sprintf("%d GB", n/gigabyte)
	case n >= gigabyte:
		return fmt.Sprintf("%.1f GB", float64(n)/float64(gigabyte))
	case n >= 1<<20:
		return fmt.Sprintf("%d MB", n>>20)
	case n >= 1<<10:
		return fmt.Sprintf("%d KB", n>>10)
	}
	return fmt.Sprintf("%d bytes", n)
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}
