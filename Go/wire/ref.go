package wire

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// Ref names one thing so that a person can read it and an agent can parse it (#4727, spec
// 4724-event-bus, "A ref"):
//
//	ref      = provider ":" type ":" topic "#" id
//	provider = [a-z0-9-]+       github, gitlab, jira, linear, slack, email, sentry, agents
//	type     = [a-z0-9-]+       pr, issue, branch, commit, run, message, session, machine
//	topic    = any text without ":" or "#"; can be empty
//	id       = any text (the first "#" ends the topic; the id can hold "#" and "/")
//
// For example github:pr:alexec/agents#4702, jira:issue:abc#ABC-9, agents:machine:#mac-mini.
// Provider, type and topic are lower case; the id keeps its case. On the wire a Ref is its
// text, as String writes it. The same parser is in TypeScript (Web/src/protocol/ref.ts) and
// Swift (AgentsKitCore's WireRef).
type Ref struct {
	Provider string
	Type     string
	Topic    string
	ID       string
}

// MaxRefLength bounds a ref's text, so one line that holds one stays small.
const MaxRefLength = 512

var refWord = regexp.MustCompile(`^[a-z0-9-]+$`)

// ParseRef reads a ref in the full form, provider:type:topic#id. It lowers the case of the
// provider, the type and the topic. A short form is ParseShortRef's.
func ParseRef(s string) (Ref, error) {
	if len(s) > MaxRefLength {
		return Ref{}, fmt.Errorf("ref: longer than %d bytes", MaxRefLength)
	}
	head, id, ok := strings.Cut(s, "#")
	if !ok {
		return Ref{}, fmt.Errorf("ref %q: want provider:type:topic#id, such as github:pr:alexec/agents#4702", s)
	}
	parts := strings.Split(head, ":")
	if len(parts) != 3 {
		return Ref{}, fmt.Errorf("ref %q: want provider:type:topic#id, such as github:pr:alexec/agents#4702", s)
	}
	r := Ref{Provider: strings.ToLower(parts[0]), Type: strings.ToLower(parts[1]), Topic: strings.ToLower(parts[2]), ID: id}
	if err := r.Check(); err != nil {
		return Ref{}, err
	}
	return r, nil
}

// Check says what is wrong with a ref, or nil.
func (r Ref) Check() error {
	switch {
	case !refWord.MatchString(r.Provider):
		return fmt.Errorf("ref: provider %q: want lower case letters, digits and -", r.Provider)
	case !refWord.MatchString(r.Type):
		return fmt.Errorf("ref: type %q: want lower case letters, digits and -", r.Type)
	case strings.ContainsAny(r.Topic, ":#"):
		return fmt.Errorf("ref: topic %q: holds : or #", r.Topic)
	case r.Topic != strings.ToLower(r.Topic):
		return fmt.Errorf("ref: topic %q: want lower case", r.Topic)
	case r.ID == "":
		return errors.New("ref: no id after #")
	case len(r.String()) > MaxRefLength:
		return fmt.Errorf("ref: longer than %d bytes", MaxRefLength)
	}
	return nil
}

// String is the ref's full form, provider:type:topic#id.
func (r Ref) String() string { return r.Provider + ":" + r.Type + ":" + r.Topic + "#" + r.ID }

// IsZero says whether the ref is empty.
func (r Ref) IsZero() bool { return r == Ref{} }

// MarshalText writes the full form; encoding/json uses it.
func (r Ref) MarshalText() ([]byte, error) {
	if err := r.Check(); err != nil {
		return nil, err
	}
	return []byte(r.String()), nil
}

// UnmarshalText reads the full form only: what the app writes. A person's short form goes
// through ParseShortRef first.
func (r *Ref) UnmarshalText(b []byte) error {
	v, err := ParseRef(string(b))
	if err != nil {
		return err
	}
	*r = v
	return nil
}

// RefContext is what a short form leaves out: the folder's origin and the forge's answer.
type RefContext struct {
	// Provider and Topic are the folder's origin, such as github and alexec/agents.
	Provider string
	Topic    string
	// TypeOf is the forge's answer for a number whose form does not say its type, such as
	// "pr" or "issue" for #123 on GitHub. Nil, or "", makes such a form an error.
	TypeOf func(provider, topic, id string) (string, error)
}

// ErrNoOrigin is a short form that needs the folder's origin when the context has none.
var ErrNoOrigin = errors.New("ref: the short form needs the folder's origin (provider and topic)")

// ParseShortRef reads a ref as a person or an agent types it, and gives the full ref:
//
//	github:pr:alexec/agents#123  the full form, as ParseRef
//	#123                         the origin's topic; the type from the forge
//	P#123                        the origin's topic; a pull request (mr on GitLab)
//	owner/repo#123               the origin's provider; the type from the forge
//	github:owner/repo#123        lineage's form: the type from the forge
func ParseShortRef(s string, c RefContext) (Ref, error) {
	s = strings.TrimSpace(s)
	if len(s) > MaxRefLength {
		return Ref{}, fmt.Errorf("ref: longer than %d bytes", MaxRefLength)
	}
	head, id, ok := strings.Cut(s, "#")
	if !ok || id == "" {
		return Ref{}, fmt.Errorf("ref %q: want provider:type:topic#id, #123, P#123 or owner/repo#123", s)
	}
	var provider, topic, typ string
	switch colons := strings.Count(head, ":"); {
	case colons == 2:
		return ParseRef(s)
	case colons == 1:
		provider, topic, _ = strings.Cut(head, ":")
	case head == "" || strings.EqualFold(head, "P"):
		if c.Provider == "" || c.Topic == "" {
			return Ref{}, ErrNoOrigin
		}
		provider, topic = c.Provider, c.Topic
		if head != "" {
			typ = PullType(provider)
		}
	case strings.Contains(head, "/"):
		if c.Provider == "" {
			return Ref{}, ErrNoOrigin
		}
		provider, topic = c.Provider, head
	default:
		return Ref{}, fmt.Errorf("ref %q: want provider:type:topic#id, #123, P#123 or owner/repo#123", s)
	}
	provider, topic = strings.ToLower(provider), strings.ToLower(topic)
	if typ == "" {
		var err error
		if typ, err = typeFromForge(provider, topic, id, c); err != nil {
			return Ref{}, err
		}
	}
	r := Ref{Provider: provider, Type: strings.ToLower(typ), Topic: topic, ID: id}
	return r, r.Check()
}

func typeFromForge(provider, topic, id string, c RefContext) (string, error) {
	if c.TypeOf == nil {
		return "", fmt.Errorf("ref %s:%s#%s: the forge must say whether it is an issue or a pull request", provider, topic, id)
	}
	typ, err := c.TypeOf(provider, topic, id)
	if err != nil {
		return "", err
	}
	if typ == "" {
		return "", fmt.Errorf("ref %s:%s#%s: the forge did not say its type", provider, topic, id)
	}
	return typ, nil
}

// PullType is a provider's type for a pull request: "mr" on GitLab, "pr" elsewhere.
func PullType(provider string) string {
	if strings.EqualFold(provider, "gitlab") {
		return "mr"
	}
	return "pr"
}

// RefFromLineage reads a lineage node's ref in the form it had before #4727 (spec
// 2348-lineage, "Node refs"), given the node's kind, and gives the full ref. A ref in the
// full form already is read as ParseRef reads it. ok is false for a form it does not know;
// the caller keeps that one as it is. c.Topic is the project of a session, which the old
// form did not say; it can be empty.
//
//	issue github:alexec/agents#123   github:issue:alexec/agents#123
//	pr    github:alexec/agents#123   github:pr:alexec/agents#123
//	pr    gitlab:group/repo!45       gitlab:mr:group/repo#45
//	issue linear:ENG-4               linear:issue:eng#ENG-4
//	issue jira:ABC-9                 jira:issue:abc#ABC-9
//	issue azureboards:project#12     azureboards:issue:project#12
//	session session:<id>             agents:session:<c.Topic>#<id>
func RefFromLineage(kind, old string, c RefContext) (Ref, bool) {
	if r, err := ParseRef(old); err == nil {
		return r, true
	}
	scheme, rest, ok := strings.Cut(old, ":")
	if !ok || rest == "" || !refWord.MatchString(scheme) {
		return Ref{}, false
	}
	var r Ref
	switch {
	case kind == "session" && scheme == "session":
		r = Ref{Provider: "agents", Type: "session", Topic: strings.ToLower(c.Topic), ID: rest}
	case kind == "issue" && (scheme == "linear" || scheme == "jira"):
		team, _, ok := strings.Cut(rest, "-")
		if !ok || team == "" {
			return Ref{}, false
		}
		r = Ref{Provider: scheme, Type: "issue", Topic: strings.ToLower(team), ID: rest}
	case kind == "pr" && scheme == "gitlab" && strings.Contains(rest, "!"):
		i := strings.LastIndex(rest, "!")
		r = Ref{Provider: scheme, Type: "mr", Topic: strings.ToLower(rest[:i]), ID: rest[i+1:]}
	case kind == "issue" || kind == "pr":
		i := strings.LastIndex(rest, "#")
		if i < 0 {
			return Ref{}, false
		}
		typ := kind
		if kind == "pr" {
			typ = PullType(scheme)
		}
		r = Ref{Provider: scheme, Type: typ, Topic: strings.ToLower(rest[:i]), ID: rest[i+1:]}
	default:
		return Ref{}, false
	}
	if r.Check() != nil {
		return Ref{}, false
	}
	return r, true
}
