package lineage

import (
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Node refs in the full form (#4800, spec 4724-event-bus, "A ref"): every node is written as
// provider:type:topic#id, and read through RefOf, which takes the old form (spec
// 2348-lineage, "Node refs") for one release.

// NodeOf is the node of kind for r.
func NodeOf(kind string, r wire.Ref) wire.LineageNode {
	return wire.LineageNode{Kind: kind, Ref: r.String()}
}

// RefOf is a node's ref, parsed: the full form, or an old form read through
// wire.RefFromLineage. ok is false for a ref in neither.
func RefOf(n wire.LineageNode) (wire.Ref, bool) {
	return wire.RefFromLineage(n.Kind, n.Ref, wire.RefContext{})
}

// RefOfText is RefOf for a ref with no kind: the full form, or the old form of a session
// (session:<id>), an issue or a pull request (github:owner/repo#12, gitlab:group/repo!12),
// a Linear or a Jira issue.
func RefOfText(ref string) (wire.Ref, bool) {
	if r, err := wire.ParseRef(ref); err == nil {
		return r, true
	}
	kind := KindIssue
	switch {
	case strings.HasPrefix(ref, "session:"):
		kind = KindSession
	case strings.HasPrefix(ref, "gitlab:") && strings.Contains(ref, "!"):
		kind = KindPR
	}
	return wire.RefFromLineage(kind, ref, wire.RefContext{})
}

// SessionID is the agent id of a session's ref, agents:session:<topic>#<id> (session:<id> in
// the old form).
func SessionID(ref string) (string, bool) {
	r, ok := RefOfText(ref)
	if !ok || r.Provider != "agents" || r.Type != "session" {
		return "", false
	}
	return r.ID, true
}

// SessionNode is a session's node, agents:session:<topic>#<id>: topic is the repo of its
// folder, "" when it has none. The store's Canon names it as the store does.
func SessionNode(topic, id string) wire.LineageNode {
	return NodeOf(KindSession, wire.Ref{Provider: "agents", Type: "session", Topic: strings.ToLower(topic), ID: id})
}

// RepoNode is the rollup node of the repo or tracker a ref is in (KindRepo):
// <provider>:repo:#<topic>, such as github:repo:#alexec/agents or linear:repo:#eng.
func RepoNode(r wire.Ref) wire.LineageNode {
	return NodeOf(KindRepo, wire.Ref{Provider: r.Provider, Type: "repo", ID: r.Topic})
}

// FullRefText is a ref with no kind in the full form: an old form read as kind's, given the
// topic of an agents node; a ref it does not know as it is.
func FullRefText(kind, ref, topic string) string {
	if r, ok := wire.RefFromLineage(kind, ref, wire.RefContext{Topic: topic}); ok {
		return r.String()
	}
	return ref
}

// FullRepoText is a cost node's repo in the full form: github:alexec/agents is
// github:repo:#alexec/agents, folder:<name> folder:repo:#<name>.
func FullRepoText(repo string) string {
	if strings.HasPrefix(repo, "folder:") && !strings.Contains(repo, "#") {
		name := strings.TrimPrefix(repo, "folder:")
		if r := (wire.Ref{Provider: "folder", Type: "repo", ID: name}); r.Check() == nil {
			return r.String()
		}
		return repo
	}
	return FullRefText(KindRepo, repo, "")
}

// FullCostNode is c with every ref in the full form (#4800): its node, repo, the issues it
// fixes, what it is part of, its parent and its sessions. topic is the project of an agents
// node in the old form, by its kind and id; it can be nil.
func FullCostNode(c wire.LineageCostNode, topic Topics) wire.LineageCostNode {
	agentsTopic := func(kind, ref string) string {
		if topic == nil {
			return ""
		}
		if r, ok := wire.RefFromLineage(kind, ref, wire.RefContext{}); ok && r.Provider == "agents" {
			return topic(kind, r.ID)
		}
		return ""
	}
	c.Node = Full(c.Node, agentsTopic(c.Node.Kind, c.Node.Ref))
	if c.Repo != nil {
		repo := FullRepoText(*c.Repo)
		c.Repo = &repo
	}
	if c.Parent != nil {
		p := FullRefText(KindIssue, *c.Parent, "")
		c.Parent = &p
	}
	if c.Fixes != nil {
		fixes := make([]string, len(c.Fixes))
		for i, f := range c.Fixes {
			fixes[i] = FullRefText(KindIssue, f, "")
		}
		c.Fixes = fixes
	}
	partOf := make([]string, len(c.PartOf))
	for i, p := range c.PartOf {
		kind := KindRelease
		if strings.Contains(p, "/milestone/") {
			kind = removedKindMilestone
		}
		partOf[i] = FullRefText(kind, p, "")
	}
	if c.PartOf != nil {
		c.PartOf = partOf
	}
	if c.Sessions != nil {
		sessions := make([]string, len(c.Sessions))
		for i, s := range c.Sessions {
			sessions[i] = FullRefText(KindSession, s, agentsTopic(KindSession, s))
		}
		c.Sessions = sessions
	}
	return c
}

// Names is the one name of each node in a set of links (#4800): the full ref form, and for an
// agents node (a session, a workflow, a workflow's run) the first topic seen for its id, so a
// session named with its project and without one is one node. The control plane's merged copy
// names its nodes with it, as Files does its own.
type Names struct{ topics map[string]string }

// Name is n in the full form, with the topic kept for an agents node's id; the first time an
// agents node is named, its topic is kept.
func (m *Names) Name(n wire.LineageNode) wire.LineageNode {
	n = Full(n, "")
	r, ok := ParseNode(n)
	if !ok || r.Provider != "agents" {
		return n
	}
	if m.topics == nil {
		m.topics = map[string]string{}
	}
	topic, known := m.topics[agentsKey(r)]
	if !known {
		m.topics[agentsKey(r)] = r.Topic
		return n
	}
	if topic != r.Topic {
		r.Topic = topic
		n.Ref = r.String()
	}
	return n
}

// Ask is n as Name names it, keeping no topic: a node asked for, not one in the links.
func (m *Names) Ask(n wire.LineageNode) wire.LineageNode {
	n = Full(n, "")
	r, ok := ParseNode(n)
	if !ok || r.Provider != "agents" {
		return n
	}
	if topic, known := m.topics[agentsKey(r)]; known && topic != r.Topic {
		r.Topic = topic
		n.Ref = r.String()
	}
	return n
}

// SameRepo says two repos are the same, either in the old form or the full one, in any case.
func SameRepo(a, b string) bool { return strings.EqualFold(FullRepoText(a), FullRepoText(b)) }
