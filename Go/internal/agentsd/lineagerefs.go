package agentsd

import (
	"slices"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Lineage refs in the full form (#4800, spec 4724-event-bus, "A ref"): each node is written as
// provider:type:topic#id, and read through lineage.RefOf, which takes the old form for one
// release.

// numberedNode is the topic and number of a node of one of kinds on provider: an issue's or a
// pull request's, such as forgejo:pr:owner/repo#12.
func numberedNode(n wire.LineageNode, provider string, kinds ...string) (string, int, bool) {
	if !slices.Contains(kinds, n.Kind) {
		return "", 0, false
	}
	r, ok := lineage.RefOf(n)
	if !ok || r.Provider != provider || r.Topic == "" {
		return "", 0, false
	}
	number, err := strconv.Atoi(r.ID)
	if err != nil || number <= 0 {
		return "", 0, false
	}
	return r.Topic, number, true
}

// numbered is the node of an issue (kind issue) or a pull request (kind pr) on provider, in
// topic, by its number: forgejo:pr:owner/repo#12.
func numbered(kind, provider, topic string, number int) wire.LineageNode {
	typ := lineage.KindIssue
	if kind == lineage.KindPR {
		typ = wire.PullType(provider)
	}
	return lineage.NodeOf(kind, wire.Ref{Provider: provider, Type: typ, Topic: strings.ToLower(topic), ID: strconv.Itoa(number)})
}

// keyedIssue is a Linear or Jira issue's node by its key: linear:issue:eng#ENG-4.
func keyedIssue(provider, key string) wire.LineageNode {
	team, _, _ := strings.Cut(key, "-")
	return lineage.NodeOf(lineage.KindIssue, wire.Ref{Provider: provider, Type: "issue", Topic: strings.ToLower(team), ID: key})
}

// keyOfIssue is the key of a Linear or Jira issue's node on provider: ENG-4 of
// linear:issue:eng#ENG-4 (linear:ENG-4 in the old form).
func keyOfIssue(n wire.LineageNode, provider string) (string, bool) {
	r, ok := lineage.RefOf(n)
	if !ok || r.Provider != provider || r.Type != "issue" {
		return "", false
	}
	return r.ID, true
}
