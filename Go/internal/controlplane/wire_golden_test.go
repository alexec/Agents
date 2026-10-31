package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

var update = flag.Bool("update", false, "write testdata/wire.golden from what the control plane says now")

// What the control plane says, byte for byte, to a window and to a host (#1313): the
// answers to its own methods, the notifications a window hears, and the lines a relay
// host and a plain host read on their uplinks. Only what changes from run to run (ids, a
// date's value, codes, keys, the port) is masked; the keys, their order, what is left out,
// a UUID's case and every other value are as written. testdata/wire.golden was made from
// the hand-written wire types before they moved to Go/wire, so this is the proof that the
// move changed no byte.
func TestTheWireIsWhatItWas(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx := context.Background()
	// Hosts that say no list, as the golden was made before capabilities (#1748).
	home := p.olderHost("MACHINE-1")
	box := p.olderHost("MACHINE-2")
	relayID, relay := p.rawHost("relay mac", true)
	plainID, plain := p.rawHost("plain mac", false)
	member, window := p.client("Golden window")
	// A phone that may notify, so the relay host hears a device and a delivery.
	phone, err := controllink.PairClient(ctx, p.code(false), "phone")
	if err != nil {
		t.Fatal(err)
	}
	yes := true
	if err := p.s.Records().ChangeClient(ctx, phone.Client, func(c *records.ClientRecord) bool {
		c.Kind, c.MayNotify = records.KindIPhone, &yes
		return true
	}); err != nil {
		t.Fatal(err)
	}
	p.s.tellRelayDevices()
	readUntil(t, relay, phone.Client)

	var out []string
	say := func(what, line string) { out = append(out, what+"\n"+pretty(line, "")) }
	answer := func(method string, params any) {
		c, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		got, err := window.Call(c, "", method, params)
		if err != nil {
			say(method+" refused", err.Error())
			return
		}
		// A list's order follows random ids: its rows are sorted once masked.
		var rows []json.RawMessage
		if strings.HasPrefix(string(got), "[") && json.Unmarshal(got, &rows) == nil {
			masked := make([]string, len(rows))
			for i, r := range rows {
				masked[i] = "  " + mask(pretty(string(r), "  "), p, box.member.Host, relayID, plainID)
			}
			sort.Strings(masked)
			out = append(out, method+"\n[\n"+strings.Join(masked, ",\n")+"\n]")
			return
		}
		say(method, string(got))
	}

	answer("control/status", nil)
	answer("hosts/list", nil)
	answer("clients/list", nil)
	answer("devices/list", nil)
	answer("clients/connections", nil)
	answer("hosts/startEnroll", nil)
	answer("clients/startPairing", map[string]any{"kind": "browser"})
	answer("devices/startPairing", nil)
	answer("clients/stopPairing", nil)
	answer("hosts/lastHeard", map[string]any{"host": box.member.Host})
	answer("control/setFolderDetection", map[string]any{"enabled": true, "paths": []string{" ~/src ", "", "~/work"}})
	answer("hosts/lendSignIn", map[string]any{"host": box.member.Host, "from": home.member.Host, "runtime": "claude", "allowed": true})
	answer("hosts/lendGit", map[string]any{"host": box.member.Host, "from": home.member.Host, "server": "github.com", "allowed": true})
	answer("hosts/setRelay", map[string]any{"host": relayID, "relay": true})
	answer("control/status", nil)
	answer("hosts/list", nil)
	answer("clients/setGrant", map[string]any{"client": member.Client, "grant": "viewer"})
	answer("hosts/remove", map[string]any{"host": "nobody"})
	answer("hosts/update", map[string]any{"nothing": 1})
	answer("providers/list", nil)
	answer("nothing/here", nil)

	// A need, offered and taken back, as the relay host reads it.
	need := `{"need":{"id":{"permission":"E0000000-0000-4000-8000-000000000005"},"agentID":"A0000000-0000-4000-8000-000000000001",` +
		`"folder":"file:///work","kind":"permission","raisedAt":800000000.25,"headline":{"h1":"work","h2":"Fix","h3":"may run"}},"buzz":true,"waiting":1}`
	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(need)); err != nil {
		t.Fatal(err)
	}
	say("relay reads", readUntil(t, relay, "relay/deliver"))
	_, _ = p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(`{"withdraw":{"permission":"E0000000-0000-4000-8000-000000000005"},"waiting":0}`))
	say("relay reads", readUntil(t, relay, "relay/deliver"))

	// A window's call to a plain host opens a channel: the host reads the open frame.
	go func() { _, _ = window.Call(ctx, plainID, "daemon/ping", nil) }()
	say("host reads", readUntil(t, plain, `"open"`))

	// Every notification the window heard, once each, in order.
	time.Sleep(300 * time.Millisecond)
	heard := map[string]bool{}
	for {
		select {
		case n := <-window.Notes:
			if n.Host == "" {
				heard[n.Method+"\n"+pretty(string(n.Params), "")] = true
			}
			continue
		default:
		}
		break
	}
	var notes []string
	for n := range heard {
		notes = append(notes, mask(n, p, box.member.Host, relayID, plainID))
	}
	sort.Strings(notes)
	for i := range out {
		out[i] = mask(out[i], p, box.member.Host, relayID, plainID)
	}
	got := strings.Join(out, "\n\n") + "\n\n# notifications\n\n" + strings.Join(notes, "\n\n") + "\n"

	golden := filepath.Join("testdata", "wire.golden")
	if *update {
		_ = os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(golden, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(golden)
	if err != nil {
		t.Fatal(err)
	}
	if got != string(want) {
		gotLines, wantLines := strings.Split(got, "\n"), strings.Split(string(want), "\n")
		for i := range min(len(gotLines), len(wantLines)) {
			if gotLines[i] != wantLines[i] {
				t.Fatalf("line %d:\n got %s\nwant %s", i+1, gotLines[i], wantLines[i])
			}
		}
		t.Fatalf("got %d lines, want %d", len(gotLines), len(wantLines))
	}
}

// pretty is a JSON value with one key or item per line, so that two changes to one answer
// (a capability each, say) touch different lines of the golden file (#2020). It only adds
// space: the keys, their order and every value stay as written. Anything else is as it was.
func pretty(s, prefix string) string {
	var b bytes.Buffer
	if json.Indent(&b, []byte(s), prefix, "  ") != nil {
		return s
	}
	return b.String()
}

var (
	upperUUID = regexp.MustCompile(`[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}`)
	lowerUUID = regexp.MustCompile(`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	// A date's value changes; that it is a number, and where, does not.
	dates = regexp.MustCompile(`"(startedAt|paired|lastSeen|expires|at|heardAt|since|countedAt|forgottenAt)":( ?)-?[0-9][0-9.eE+-]*`)
	// Base64 keys and codes, which are new each run.
	secrets = regexp.MustCompile(`"(publicKey|relayKey|text|command)":( ?)"[^"]*"`)
	ports   = regexp.MustCompile(`"port":( ?)[0-9]+`)
)

func mask(s string, p *plane, hosts ...string) string {
	s = strings.ReplaceAll(s, p.url, "<url>")
	for i, h := range hosts {
		s = strings.ReplaceAll(s, `"`+h+`"`, `"<host `+string(rune('a'+i))+`>"`)
	}
	s = upperUUID.ReplaceAllString(s, "<UUID>")
	s = lowerUUID.ReplaceAllString(s, "<uuid>")
	s = dates.ReplaceAllString(s, `"$1":$2<date>`)
	s = secrets.ReplaceAllString(s, `"$1":$2"<secret>"`)
	return ports.ReplaceAllString(s, `"port":$1<port>`)
}
