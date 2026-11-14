package lineage

import (
	"reflect"
	"slices"

	"github.com/agentloops-dev/agent-loops/Go/internal/repoalias"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A cost ledger names a repo that moved by its name now (#5332), as Files does its nodes
// (#4957): a PR banked before the move and its links after it are one node, so its sessions,
// its merge and its cost count once, under one name.

// AliasRefText is a ref in the full form by its repo's name now; a ref it cannot read, as it is.
func AliasRefText(ref string) string {
	r, err := wire.ParseRef(ref)
	if err != nil {
		return ref
	}
	if moved := repoalias.Ref(r); moved != r && moved.Check() == nil {
		return moved.String()
	}
	return ref
}

// AliasCostNode is c with every ref by its repo's name now: its repo, the issues it fixes, what
// it is part of, its parent, its sessions and the PR it reverts. canon names its node.
func AliasCostNode(c wire.LineageCostNode, canon func(wire.LineageNode) wire.LineageNode) wire.LineageCostNode {
	c.Node = canon(c.Node)
	text := func(p *string) *string {
		if p == nil {
			return nil
		}
		s := AliasRefText(*p)
		return &s
	}
	list := func(l []string) []string {
		if l == nil {
			return nil
		}
		out := make([]string, len(l))
		for i, s := range l {
			out[i] = AliasRefText(s)
		}
		return out
	}
	c.Repo, c.Parent, c.Reverts = text(c.Repo), text(c.Parent), text(c.Reverts)
	c.Fixes, c.PartOf, c.Sessions = list(c.Fixes), list(c.PartOf), list(c.Sessions)
	return c
}

// MergeCostNodes is one node of a and b, the same node under two names: their cost and failed
// checks added, the earliest start and the latest change, its issues, releases and sessions
// once, and every other field from the one changed last, or from the other when that one has
// none.
func MergeCostNodes(a, b wire.LineageCostNode) wire.LineageCostNode {
	newer, older := a, b
	if b.LastAt > a.LastAt {
		newer, older = b, a
	}
	out := newer
	v, o := reflect.ValueOf(&out).Elem(), reflect.ValueOf(older)
	for i := range v.NumField() {
		if v.Field(i).IsZero() {
			v.Field(i).Set(o.Field(i))
		}
	}
	out.Banked = wire.LineageCost{}
	AddCost(&out.Banked, newer.Banked)
	AddCost(&out.Banked, older.Banked)
	if newer.FailedChecks != nil && older.FailedChecks != nil {
		n := *newer.FailedChecks + *older.FailedChecks
		out.FailedChecks = &n
	}
	earliest := func(x, y *wire.Date) *wire.Date {
		if x == nil || (y != nil && *y < *x) {
			return y
		}
		return x
	}
	out.FirstAt = earliest(newer.FirstAt, older.FirstAt)
	out.StartedAt = earliest(newer.StartedAt, older.StartedAt)
	out.OpenedAt = earliest(newer.OpenedAt, older.OpenedAt)
	union := func(x, y []string) []string {
		if x == nil && y == nil {
			return nil
		}
		u := slices.Concat(x, y)
		slices.Sort(u)
		return slices.Compact(u)
	}
	out.Fixes = union(newer.Fixes, older.Fixes)
	out.PartOf = union(newer.PartOf, older.PartOf)
	out.Sessions = union(newer.Sessions, older.Sessions)
	return out
}
