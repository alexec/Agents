package agentsd

import (
	"sort"

	"github.com/alexec/agents/Go/wire"
)

// The person's own pass-through list (#727, #998 FR-011a; #2957): your layer's
// environment.passThrough and environment.runtimes name the variables of this machine's
// environment that runtimes get beyond the built-in allowlist (allowed in runtimes.go) and
// each runtime's own names. Names only, never values. names go to every runtime, the
// runtimes map to that runtime only; * at the end is a prefix. Before this slice these were
// <settings>/runtime-environment.json, read once into your layer on the first start
// (FR-012) and not read again. The organisation's policy (environment.passThrough) cuts
// the list: a name it does not allow is not passed, and settings/passThrough marks it.

// passThroughFile is the old file's name, read once into your layer on the first start
// (FR-012, policyyours.go's firstStartMoveLocked) and not read again.
const passThroughFile = "runtime-environment.json"

// passThroughList is your layer's environment rule, in the file's old shape, kept for the
// rest of this file's logic.
type passThroughList struct {
	Names    []string
	Runtimes map[string][]string
}

func (d *Daemon) readPassThrough() passThroughList {
	e := d.yourPolicyRules().Environment
	if e == nil {
		return passThroughList{}
	}
	return passThroughList{Names: e.PassThrough, Runtimes: e.Runtimes}
}

// passThrough is the names a runtime gets from the person's list, as the policy allows.
func (d *Daemon) passThrough(runtimeID string) []string {
	l := d.readPassThrough()
	p := d.orgPolicy()
	var out []string
	for _, n := range append(append([]string{}, l.Names...), l.Runtimes[runtimeID]...) {
		if n != "" && passThroughAllowed(p, n) {
			out = append(out, n)
		}
	}
	return out
}

// passedThrough is environment's test for one of the person's names: the same name, or a
// prefix with * at the end.
func passedThrough(names []string, name string) bool {
	for _, n := range names {
		if nameMatches(n, name) {
			return true
		}
	}
	return false
}

// passThroughState is settings/passThrough: every name of the person's list, each marked
// when the policy refuses it.
func (d *Daemon) passThroughState() wire.PassThroughState {
	l := d.readPassThrough()
	p := d.orgPolicy()
	out := wire.PassThroughState{Names: []wire.PassThroughName{}}
	add := func(name, runtime string) {
		n := wire.PassThroughName{Name: name}
		if runtime != "" {
			n.Runtime = &runtime
		}
		if !passThroughAllowed(p, name) {
			n.SetBy = setBy(orgLayerRef(p), "environment.passThrough", passThroughWords)
		}
		out.Names = append(out.Names, n)
	}
	for _, n := range l.Names {
		add(n, "")
	}
	ids := make([]string, 0, len(l.Runtimes))
	for id := range l.Runtimes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		for _, n := range l.Runtimes[id] {
			add(n, id)
		}
	}
	return out
}
