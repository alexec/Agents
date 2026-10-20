package main

import (
	"context"
	"errors"
	"log"
	"os"
	"strings"
	"time"

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
