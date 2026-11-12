// Package repoalias keeps the repos whose owner moved (#4957): an old full name and the new
// one, such as alexec/agents and agentloops-dev/agents, as the forge's own redirect said it.
// Refs are read and matched by the new name (Ref, Topic, SameRepo), so a ref stored before
// the move and an event after it name one thing. The stored files are not written again.
//
// The book is one for the process: the daemon loads it at start (Load), and adds to it when
// GitHub's GET /repos/<old> answers with another full_name (Add).
package repoalias

import (
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Most bounds the aliases kept; past it, a new one is not added.
const Most = 1_000

// maxHops bounds a chain of moves (a to b, then b to c).
const maxHops = 8

// Alias is one repo that moved, on one provider. From and To are lower case.
type Alias struct {
	Provider string    `json:"provider"`
	From     string    `json:"from"`
	To       string    `json:"to"`
	At       time.Time `json:"at"`
}

var (
	mu      sync.RWMutex
	aliases = map[string]Alias{} // by key(provider, from)
)

func key(provider, from string) string {
	return strings.ToLower(provider) + ":" + strings.ToLower(from)
}

// Set replaces the book with list: for Load and tests.
func Set(list []Alias) {
	m := make(map[string]Alias, len(list))
	for _, a := range list {
		if a, ok := clean(a); ok && len(m) < Most {
			m[key(a.Provider, a.From)] = a
		}
	}
	mu.Lock()
	aliases = m
	mu.Unlock()
}

// All is every alias, by provider and old name.
func All() []Alias {
	mu.RLock()
	out := make([]Alias, 0, len(aliases))
	for _, a := range aliases {
		out = append(out, a)
	}
	mu.RUnlock()
	sort.Slice(out, func(i, j int) bool {
		return out[i].Provider+":"+out[i].From < out[j].Provider+":"+out[j].From
	})
	return out
}

func clean(a Alias) (Alias, bool) {
	a.Provider, a.From, a.To = strings.ToLower(a.Provider), strings.ToLower(strings.Trim(a.From, "/")), strings.ToLower(strings.Trim(a.To, "/"))
	ok := a.Provider != "" && a.From != "" && a.To != "" && a.From != a.To &&
		!strings.ContainsAny(a.From+a.To, ":# ") && strings.Contains(a.From, "/") && strings.Contains(a.To, "/")
	return a, ok
}

// Add keeps that from moved to to on provider, and says whether the book changed. A move back
// (to is an old name of from) removes the alias that pointed the other way.
func Add(provider, from, to string, at time.Time) bool {
	a, ok := clean(Alias{Provider: provider, From: from, To: to, At: at})
	if !ok {
		return false
	}
	mu.Lock()
	defer mu.Unlock()
	if old, known := aliases[key(a.Provider, a.From)]; known && old.To == a.To {
		return false
	}
	if _, known := aliases[key(a.Provider, a.From)]; !known && len(aliases) >= Most {
		return false
	}
	delete(aliases, key(a.Provider, a.To))
	aliases[key(a.Provider, a.From)] = a
	return true
}

// Topic is the repo's name now on provider: the new name, lower case, when it moved; else
// topic as it is. A provider that is not a forge (agents, folder) takes any forge's alias for
// the same path, since its topic is a folder's repo.
func Topic(provider, topic string) string {
	if topic == "" {
		return topic
	}
	mu.RLock()
	defer mu.RUnlock()
	if len(aliases) == 0 {
		return topic
	}
	provider = strings.ToLower(provider)
	name, moved := strings.ToLower(topic), false
	for range maxHops {
		a, ok := aliases[key(provider, name)]
		if !ok && (provider == "agents" || provider == "folder") {
			a, ok = anyProvider(name)
		}
		if !ok {
			break
		}
		name, moved = a.To, true
	}
	if !moved {
		return topic
	}
	return name
}

// anyProvider is an alias of name on some forge, the first by provider. Under mu.
func anyProvider(name string) (Alias, bool) {
	var found Alias
	ok := false
	for _, a := range aliases {
		if a.From == name && (!ok || a.Provider < found.Provider) {
			found, ok = a, true
		}
	}
	return found, ok
}

// Ref is r by its repo's name now: the topic, and the id of a repo's own ref
// (github:repo:#alexec/agents).
func Ref(r wire.Ref) wire.Ref {
	if r.Topic != "" {
		r.Topic = Topic(r.Provider, r.Topic)
	}
	if r.Type == "repo" && r.Topic == "" {
		r.ID = Topic(r.Provider, r.ID)
	}
	return r
}

// SameRepo is whether a and b name one repo on provider, either name before or after a
// move, in any case.
func SameRepo(provider, a, b string) bool {
	return strings.EqualFold(Topic(provider, a), Topic(provider, b))
}

type file struct {
	Aliases []Alias `json:"aliases"`
}

// Load reads the book from path; a missing file is an empty book.
func Load(path string) error {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		Set(nil)
		return nil
	}
	if err != nil {
		return err
	}
	var f file
	if err := json.Unmarshal(b, &f); err != nil {
		return err
	}
	Set(f.Aliases)
	return nil
}

// Save writes the book to path, through a temporary file and a rename.
func Save(path string) error {
	b, err := json.MarshalIndent(file{Aliases: All()}, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteAtomically(path, append(b, '\n'), 0o600)
}
