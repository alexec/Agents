package wire

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

// Every row of the spec's ref table (specs/4724-event-bus/spec.md, "A ref") parses to its
// parts and writes back as the full form, lower case but for the id.
func TestParseRefSpecTable(t *testing.T) {
	for _, tc := range []struct {
		in, out string
		want    Ref
	}{
		{"github:pr:alexec/agents#4702", "", Ref{"github", "pr", "alexec/agents", "4702"}},
		{"github:issue:alexec/agents#4724", "", Ref{"github", "issue", "alexec/agents", "4724"}},
		{"github:branch:alexec/agents#agents/fix-640", "", Ref{"github", "branch", "alexec/agents", "agents/fix-640"}},
		{"github:run:alexec/agents#19283746", "", Ref{"github", "run", "alexec/agents", "19283746"}},
		{"gitlab:mr:group/sub/repo#45", "", Ref{"gitlab", "mr", "group/sub/repo", "45"}},
		{"jira:issue:ABC#ABC-9", "jira:issue:abc#ABC-9", Ref{"jira", "issue", "abc", "ABC-9"}},
		{"linear:issue:ENG#ENG-4", "linear:issue:eng#ENG-4", Ref{"linear", "issue", "eng", "ENG-4"}},
		{"slack:message:T01ABC/C02DEF#1699999999.000100", "slack:message:t01abc/c02def#1699999999.000100", Ref{"slack", "message", "t01abc/c02def", "1699999999.000100"}},
		{"email:message:alex@example.com#<Ab.C@mail.example.com>", "", Ref{"email", "message", "alex@example.com", "<Ab.C@mail.example.com>"}},
		{"agents:session:alexec/agents#7F3C-ab", "", Ref{"agents", "session", "alexec/agents", "7F3C-ab"}},
		{"agents:machine:#mac-mini", "", Ref{"agents", "machine", "", "mac-mini"}},
		// The id can hold # and / (and :); the first # ends the topic.
		{"github:branch:alexec/agents#a/b#c:d", "", Ref{"github", "branch", "alexec/agents", "a/b#c:d"}},
		{"GitHub:PR:Alexec/Agents#4702", "github:pr:alexec/agents#4702", Ref{"github", "pr", "alexec/agents", "4702"}},
	} {
		got, err := ParseRef(tc.in)
		if err != nil {
			t.Errorf("ParseRef(%q): %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("ParseRef(%q) = %#v, want %#v", tc.in, got, tc.want)
		}
		out := tc.out
		if out == "" {
			out = tc.in
		}
		if got.String() != out {
			t.Errorf("ParseRef(%q).String() = %q, want %q", tc.in, got.String(), out)
		}
		again, err := ParseRef(got.String())
		if err != nil || again != got {
			t.Errorf("ParseRef(%q) again = %#v, %v", got.String(), again, err)
		}
	}
}

func TestParseRefRefuses(t *testing.T) {
	for _, in := range []string{
		"",
		"github:pr:alexec/agents",     // no #
		"github:pr:alexec/agents#",    // no id
		"github:alexec/agents#4702",   // lineage's old form: ParseShortRef's
		"github:pr:x:alexec/agents#1", // topic with :
		"git hub:pr:alexec/agents#1",  // provider with a space
		"github:p_r:alexec/agents#1",  // type with _
		":pr:alexec/agents#1",         // no provider
		"github::alexec/agents#1",     // no type
		"#4702",                       // a short form
		"github:pr:" + strings.Repeat("a", MaxRefLength) + "#1",
	} {
		if r, err := ParseRef(in); err == nil {
			t.Errorf("ParseRef(%q) = %#v, want an error", in, r)
		}
	}
}

func TestRefJSON(t *testing.T) {
	type holder struct {
		Subject Ref  `json:"subject"`
		Other   *Ref `json:"other,omitempty"`
	}
	var h holder
	if err := json.Unmarshal([]byte(`{"subject":"github:PR:alexec/agents#4702"}`), &h); err != nil {
		t.Fatal(err)
	}
	if h.Subject != (Ref{"github", "pr", "alexec/agents", "4702"}) {
		t.Fatalf("subject = %#v", h.Subject)
	}
	b, err := json.Marshal(h)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"subject":"github:pr:alexec/agents#4702"}` {
		t.Fatalf("json = %s", b)
	}
	if err := json.Unmarshal([]byte(`{"subject":"#4702"}`), &h); err == nil {
		t.Fatal("a short form on the wire: want an error")
	}
	if _, err := json.Marshal(holder{}); err == nil {
		t.Fatal("an empty ref: want an error")
	}
}

func TestParseShortRef(t *testing.T) {
	forge := func(provider, topic, id string) (string, error) {
		if id == "404" {
			return "", errors.New("not found")
		}
		if id == "7" {
			return "pr", nil
		}
		return "issue", nil
	}
	origin := RefContext{Provider: "github", Topic: "alexec/agents", TypeOf: forge}
	for _, tc := range []struct {
		in   string
		c    RefContext
		want string
	}{
		{"github:pr:alexec/agents#4702", RefContext{}, "github:pr:alexec/agents#4702"},
		{"#123", origin, "github:issue:alexec/agents#123"},
		{"#7", origin, "github:pr:alexec/agents#7"},
		{"P#123", origin, "github:pr:alexec/agents#123"},
		{"p#123", origin, "github:pr:alexec/agents#123"},
		{"P#45", RefContext{Provider: "gitlab", Topic: "group/sub/repo"}, "gitlab:mr:group/sub/repo#45"},
		{"Owner/Repo#123", origin, "github:issue:owner/repo#123"},
		{"github:Alexec/Agents#7", RefContext{TypeOf: forge}, "github:pr:alexec/agents#7"},
		{"  #123 ", origin, "github:issue:alexec/agents#123"},
	} {
		got, err := ParseShortRef(tc.in, tc.c)
		if err != nil {
			t.Errorf("ParseShortRef(%q): %v", tc.in, err)
			continue
		}
		if got.String() != tc.want {
			t.Errorf("ParseShortRef(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
	for _, tc := range []struct {
		in string
		c  RefContext
	}{
		{"#123", RefContext{}},                                 // no origin
		{"P#123", RefContext{Provider: "github"}},              // no topic
		{"owner/repo#1", RefContext{}},                         // no provider
		{"#123", RefContext{Provider: "github", Topic: "a/b"}}, // the forge cannot say
		{"#404", origin},                                       // the forge failed
		{"123", origin},                                        // no #
		{"#", origin},                                          // no id
		{"X#123", origin},                                      // not a short form
	} {
		if r, err := ParseShortRef(tc.in, tc.c); err == nil {
			t.Errorf("ParseShortRef(%q) = %q, want an error", tc.in, r)
		}
	}
	if _, err := ParseShortRef("#1", RefContext{}); !errors.Is(err, ErrNoOrigin) {
		t.Errorf("#1 with no origin: %v, want ErrNoOrigin", err)
	}
}

func TestRefFromLineage(t *testing.T) {
	c := RefContext{Topic: "Alexec/Agents"}
	for _, tc := range []struct{ kind, old, want string }{
		{"issue", "github:alexec/agents#123", "github:issue:alexec/agents#123"},
		{"pr", "github:alexec/Agents#4702", "github:pr:alexec/agents#4702"},
		{"issue", "gitlab:group/sub/repo#9", "gitlab:issue:group/sub/repo#9"},
		{"pr", "gitlab:group/sub/repo!45", "gitlab:mr:group/sub/repo#45"},
		{"pr", "forgejo:owner/repo#3", "forgejo:pr:owner/repo#3"},
		{"issue", "linear:ENG-4", "linear:issue:eng#ENG-4"},
		{"issue", "jira:ABC-9", "jira:issue:abc#ABC-9"},
		{"issue", "azureboards:project#12", "azureboards:issue:project#12"},
		{"session", "session:7F3C0000-0000-0000-0000-000000000001", "agents:session:alexec/agents#7F3C0000-0000-0000-0000-000000000001"},
		{"pr", "github:pr:alexec/agents#4702", "github:pr:alexec/agents#4702"},
	} {
		got, ok := RefFromLineage(tc.kind, tc.old, c)
		if !ok || got.String() != tc.want {
			t.Errorf("RefFromLineage(%q, %q) = %q, %v, want %q", tc.kind, tc.old, got, ok, tc.want)
		}
	}
	for _, tc := range []struct{ kind, old string }{
		{"file", "file:/tmp/a.md"},
		{"release", "github:alexec/agents/release/v1.0.0"},
		{"issue", "linear:"},
		{"issue", "linear:ENG"},
		{"issue", "github:alexec/agents"},
		{"session", "nonsense"},
	} {
		if r, ok := RefFromLineage(tc.kind, tc.old, c); ok {
			t.Errorf("RefFromLineage(%q, %q) = %q, want not ok", tc.kind, tc.old, r)
		}
	}
	if r, _ := RefFromLineage("session", "session:abc", RefContext{}); r.String() != "agents:session:#abc" {
		t.Errorf("a session with no project = %q", r)
	}
}
