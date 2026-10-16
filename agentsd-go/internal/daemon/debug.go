package daemon

import (
	"context"
	"encoding/json"
	"os"
	"time"

	"github.com/alexec/agents/agentsd-go/internal/safe"
)

// debug/panic forces a panic, to prove the recovers and the supervisor (#1125). It is there only
// with AGENTS_DEBUG_PANIC=1 in the host's environment.
//
//	where "handler":   in this handler; the caller gets -32603 and the host goes on
//	where "goroutine": in a guarded goroutine; logged, the host goes on
//	where "timer":     in a guarded timer, 100 ms later; logged, the host goes on
//	where "bare":      in an unguarded goroutine, as a missed spot would: the process dies, and
//	                   the supervisor starts it again
func (d *Daemon) debugMethods() {
	if os.Getenv("AGENTS_DEBUG_PANIC") != "1" {
		return
	}
	d.Handle("debug/panic", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[struct {
			Where string `json:"where"`
		}](p)
		switch r.Where {
		case "goroutine":
			safe.Go("debug goroutine", func() { panic("forced in a goroutine") })
		case "timer":
			time.AfterFunc(100*time.Millisecond, safe.Func("debug timer", func() { panic("forced in a timer") }))
		case "bare":
			go func() { time.Sleep(100 * time.Millisecond); panic("forced in an unguarded goroutine") }()
		default:
			panic("forced in a handler")
		}
		return map[string]any{"where": r.Where, "panicsSoFar": safe.Panics.Load()}, nil
	})
	d.Handle("debug/panics", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		return map[string]any{"panics": safe.Panics.Load(), "pid": os.Getpid()}, nil
	})
}
