package bitbucketmcp

import (
	"encoding/json"

	"github.com/alexec/agents/Go/internal/mcpevents"
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

// args are an event's checked arguments. pr is a pull request's number, named as
// the github server names it.
type args struct {
	repo, branch, label string
	pr, issue           int
	anyone, mine        bool
}

// check reads raw (null or missing as {}) and checks it: no unknown keys, types, shapes.
func check(s schema, raw json.RawMessage) (args, *rpcError) {
	v, bad := s.Check(raw)
	if bad != nil {
		return args{}, bad
	}
	return args{repo: v.String("repo"), branch: v.String("branch"), label: v.String("label"),
		pr: v.Int("pr"), issue: v.Int("issue"), anyone: v.Bool("anyone"), mine: v.Bool("mine")}, nil
}
