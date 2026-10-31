package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"

	"github.com/alexec/agents/Go/wire"
)

// The person's own pass-through list (#727, #998 FR-011a): <settings>/runtime-environment.json
// names the variables of this machine's environment that runtimes get beyond the built-in
// allowlist (allowed in runtimes.go) and each runtime's own names. Names only, never values:
//
//	{"names": ["AWS_PROFILE", "MY_*"], "runtimes": {"claude": ["ANTHROPIC_MODEL"]}}
//
// names go to every runtime, runtimes.<id> to that runtime only; * at the end is a prefix.
// The organisation's policy (environment.passThrough) cuts the list: a name it does not
// allow is not passed, and settings/passThrough marks it.

const passThroughFile = "runtime-environment.json"

type passThroughList struct {
	Names    []string            `json:"names"`
	Runtimes map[string][]string `json:"runtimes"`
}

func (d *Daemon) readPassThrough() passThroughList {
	var l passThroughList
	if b, err := os.ReadFile(filepath.Join(d.SettingsDir, passThroughFile)); err == nil {
		json.Unmarshal(b, &l)
	}
	return l
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
			n.SetBy = setBy("environment.passThrough", passThroughWords)
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
