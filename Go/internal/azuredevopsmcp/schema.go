package azuredevopsmcp

import (
	"encoding/json"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
)

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

// args are an event's checked arguments. pr is a pull request's number and run a build's
// id, named as the github server names them; pipeline is a pipeline's name.
type args struct {
	repo, branch, pipeline string
	// deploy narrows deploy.* by environment, tier and component (#5244).
	deploy            mcpevents.DeployFilter
	run               int
	prs               []int
	fixes             []string
	anyone, mine, all bool
}

// workItemRefPattern is a work item as fixes takes it: "#12" (#3797).
var workItemRefPattern = regexp.MustCompile(`^#[1-9][0-9]*$`)

// closesOne is whether m's description closes one of the work items fixes asks for (#3797):
// any pull request, when fixes is not given.
func (a args) closesOne(m PR) bool {
	if len(a.fixes) == 0 {
		return true
	}
	for _, f := range m.Fixes {
		if contains(a.fixes, f) {
			return true
		}
	}
	return false
}

// byMe is whether m is the token's owner's, when mine asks for only theirs (#3797): one of
// their active pull requests, or one they opened, completed or abandoned now.
func (a args) byMe(m PR, yours *Yours) bool {
	if !a.mine {
		return true
	}
	return yours != nil && (yours.owns(m.Number) || m.AuthorID != "" && strings.EqualFold(m.AuthorID, yours.ID))
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{repo: v.String("repo"), branch: v.String("branch"), pipeline: v.String("pipeline"),
		deploy: mcpevents.DeployFilterOf(v),
		prs:    v.Ints("pr"), run: v.Int("run"), fixes: v.Strings("fixes"),
		anyone: v.Bool("anyone"), mine: v.Bool("mine"), all: v.Bool("any")}, nil
}

// wantsPR is whether the pull request numbered n is one pr asks for (#5436): any, when pr is
// not given.
func (a args) wantsPR(n int) bool { return mcpevents.Wants(a.prs, n) }
