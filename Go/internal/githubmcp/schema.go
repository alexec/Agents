package githubmcp

import (
	"encoding/json"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/mcpevents"
)

// issueRefPattern is an issue as fixes takes it: "#12", or "owner/repo#12" (#3797).
var issueRefPattern = regexp.MustCompile(`^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[1-9][0-9]*$`)

// rpcError is a JSON-RPC error answer: its code, message and optional data.
type rpcError = mcpevents.Error

func invalidParams(format string, args ...any) *rpcError {
	return mcpevents.InvalidParams(format, args...)
}

// property is one argument of an event.
type property = mcpevents.Property

// schema is an event's arguments, as the github server's: named properties in the order
// errors list them, none required, no others allowed.
type schema = mcpevents.Schema

// args are an event's checked arguments.
type args struct {
	repo, branch, label, workflow string
	pr, run                       int
	issues                        []int
	fixes                         []string
	anyone, mine, all             bool
}

// wantsIssue is whether the issue numbered n is one asked for: any, when none is.
func (a args) wantsIssue(n int) bool {
	if len(a.issues) == 0 {
		return true
	}
	for _, i := range a.issues {
		if i == n {
			return true
		}
	}
	return false
}

// closesOne is whether p's body closes one of the issues fixes asks for, "#12" being the
// repo's own (#3797): any PR, when fixes is not given.
func (a args) closesOne(p PR) bool {
	if len(a.fixes) == 0 {
		return true
	}
	full := func(ref string) string {
		if strings.HasPrefix(ref, "#") {
			ref = a.repo + ref
		}
		return strings.ToLower(ref)
	}
	for _, f := range p.Fixes {
		for _, want := range a.fixes {
			if full(f) == full(want) {
				return true
			}
		}
	}
	return false
}

// byMe is whether p is the connection's owner's, when mine asks for only theirs (#3797):
// one of their open PRs, or one they wrote, merged or closed now.
func (a args) byMe(p PR, yours *Yours) bool {
	if !a.mine {
		return true
	}
	return yours != nil && yours.ownsPR(p)
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{repo: v.String("repo"), branch: v.String("branch"), label: v.String("label"), workflow: v.String("workflow"),
		pr: v.Int("pr"), run: v.Int("run"), issues: v.Ints("issue"), fixes: v.Strings("fixes"),
		anyone: v.Bool("anyone"), mine: v.Bool("mine"), all: v.Bool("any")}, nil
}
