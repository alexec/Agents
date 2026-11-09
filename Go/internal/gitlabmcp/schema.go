package gitlabmcp

import (
	"encoding/json"
	"regexp"
	"strings"

	"github.com/alexec/agents/Go/internal/mcpevents"
)

// issueRefPattern is an issue as fixes takes it: "#12", or "group/project#12", subgroups
// too (#3797).
var issueRefPattern = regexp.MustCompile(`^([A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+)?#[1-9][0-9]*$`)

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

// args are an event's checked arguments. pr is a merge request's number (its iid), named as
// the github server names it.
type args struct {
	project, branch, label string
	pr                     int
	issues                 []int
	fixes                  []string
	anyone, mine, all      bool
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

// closesOne is whether m's description closes one of the issues fixes asks for, "#12" being
// the project's own (#3797): any merge request, when fixes is not given.
func (a args) closesOne(m MR) bool {
	if len(a.fixes) == 0 {
		return true
	}
	full := func(ref string) string {
		if strings.HasPrefix(ref, "#") {
			ref = a.project + ref
		}
		return strings.ToLower(ref)
	}
	for _, f := range m.Fixes {
		for _, want := range a.fixes {
			if full(f) == full(want) {
				return true
			}
		}
	}
	return false
}

// byMe is whether m is the connection's owner's, when mine asks for only theirs (#3797):
// one of their open merge requests, or one they wrote, merged or closed now.
func (a args) byMe(m MR, yours *Yours) bool {
	if !a.mine {
		return true
	}
	return yours != nil && (yours.owns(m.Number) || m.Author != "" && strings.EqualFold(m.Author, yours.Login))
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{project: v.String("project"), branch: v.String("branch"), label: v.String("label"),
		pr: v.Int("pr"), issues: v.Ints("issue"), fixes: v.Strings("fixes"),
		anyone: v.Bool("anyone"), mine: v.Bool("mine"), all: v.Bool("any")}, nil
}
