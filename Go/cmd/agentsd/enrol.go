package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd"
	"github.com/alexec/agents/Go/internal/controllink"
)

// enrolEvery is how often a host that could not enrol tries again, or looks for a new code.
var enrolEvery = 5 * time.Second

// enrol uses the host code until the control plane admits the host. A code it refuses for
// good (expired, spent, unknown) is not tried again (#1770): that is said once, and the host
// waits for a new code in codeFile, where an install leaves it. Anything else, such as no
// answer, is tried again every enrolEvery. It returns nil when ctx ends first.
func enrol(ctx context.Context, code string, codeFile string,
	try func(context.Context, *controllink.Code) (*controllink.Membership, error)) *controllink.Membership {
	refused := ""
	for {
		if refused == "" {
			c, err := controllink.ParseCode(code)
			if err != nil {
				log.Printf("the host code: %v; waiting for a new one in %s", err, codeFile)
				refused = code
			} else if member, err := try(ctx, c); err == nil {
				return member
			} else if why, ok := refusedForGood(err); ok {
				log.Printf("could not enrol: the control plane refused the host code (%s); waiting for a new one in %s", why, codeFile)
				refused = code
			} else {
				log.Printf("could not enrol: %v; trying again in %s", err, enrolEvery)
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(enrolEvery):
		}
		if refused != "" {
			if b, err := os.ReadFile(codeFile); err == nil {
				if fresh := strings.TrimSpace(string(b)); fresh != "" && fresh != refused {
					log.Printf("a new host code: enrolling with it")
					code, refused = fresh, ""
				}
			}
		}
	}
}

// refusedForGood says why the control plane will never take this code again.
func refusedForGood(err error) (string, bool) {
	// A code for another control plane than the one the organisation pins (#998, FR-027).
	var pinned *agentsd.PinRefused
	if errors.As(err, &pinned) {
		return pinned.Words, true
	}
	var r *controllink.Refusal
	if !errors.As(err, &r) {
		return "", false
	}
	switch r.Reason {
	case controllink.Expired, controllink.Spent, controllink.Unknown, controllink.Forgotten, controllink.BadProof:
		return r.Reason, true
	}
	return "", false
}

// joinStatusFile is HostJoinFile.name (#113): how this host's join stands, for Agents Host
// and the control plane beside it, which show its problem while it keeps failing.
const joinStatusFile = "control-join.json"

// writeJoinStatus is HostJoinFile.write: the uplink's state and why its last dial failed,
// so a host refused for ever says why where a person looks (#1996). Dates without
// fractions, as Swift's ISO 8601 decoder reads them.
func writeJoinStatus(root string, connected bool, problem string) {
	type status struct {
		Member    bool    `json:"member"`
		Connected bool    `json:"connected"`
		Problem   *string `json:"problem,omitempty"`
		At        string  `json:"at"`
	}
	said := status{Member: true, Connected: connected, At: time.Now().UTC().Format(time.RFC3339)}
	if problem != "" {
		said.Problem = &problem
	}
	data, err := json.Marshal(struct {
		PID    int    `json:"pid"`
		Status status `json:"status"`
	}{os.Getpid(), said})
	if err != nil {
		return
	}
	file := filepath.Join(root, joinStatusFile)
	if err := os.WriteFile(file+".tmp", data, 0o600); err == nil {
		os.Rename(file+".tmp", file)
	}
}
