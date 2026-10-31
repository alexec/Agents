package providers

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "write testdata/wire.golden from what providers say now")

// What machine providers say on the wire, byte for byte (#1313): each method's answer or
// refusal, a host's channel-0 answers, a linked host's workspace and what every window is
// told. Only a provider's random id, a date's value and a UUID are masked. testdata/wire.golden
// was made from the hand-written wire types before they moved to Go/wire.
func TestProvidersWireIsWhatItWas(t *testing.T) {
	h := newHarness(t)
	h.router.setOnline(devbox, true)
	var out []string
	say := func(what string, v any, err error) {
		if err != nil {
			if f := failureOf(err); f != nil {
				b, _ := json.Marshal(f)
				out = append(out, what+" refused\n"+string(b))
				return
			}
			out = append(out, what+" failed\n"+err.Error())
			return
		}
		b, _ := json.Marshal(v)
		out = append(out, what+"\n"+string(b))
	}
	answer := func(method string, params any) {
		v, err := h.call(method, params)
		say(method, v, err)
	}
	hostSaid := func(method, params string) {
		v, err := h.providers.HostSaid(devbox, method, json.RawMessage(params))
		say(method+" (host)", v, err)
	}

	id := h.add()
	answer(MethodProvidersList, nil)
	answer(MethodHostsLink, map[string]any{"host": devbox, "provider": id, "workspace": "agents-devbox", "startWhenUsed": true})
	answer(MethodHostsSetOptions, map[string]any{"host": devbox, "stopWhenIdleMinutes": 30, "startForSchedules": true})
	answer(MethodProvidersOptions, map[string]any{"id": id})
	answer(MethodHostsListKept, map[string]any{})
	answer(MethodHostsDropKept, map[string]any{"host": devbox, "id": "D0000000-0000-4000-8000-000000000001"})
	answer(MethodHostsLink, map[string]any{"host": "nobody", "provider": id, "workspace": "agents-devbox"})
	answer(MethodProvidersRemove, map[string]any{"id": "nothing-0000"})
	answer(MethodProvidersUpdate, map[string]any{"name": "x"})
	answer(MethodHostsUnlink, map[string]any{"nothing": true})
	hostSaid(MethodHostStatus, `{"idle":true,"running":[],"schedule":{"at":812345678.5,"workflow":"nightly"}}`)
	hostSaid(MethodHostMachines, `{"agent":"Claude (fix-login)","method":"machines/forAgent","params":{}}`)
	hostSaid(MethodHostMachines, `{"agent":"Claude (fix-login)","method":"providers/list","params":{}}`)
	answer(MethodProvidersList, nil)

	time.Sleep(100 * time.Millisecond)
	h.router.mu.Lock()
	seen := map[string]bool{}
	var told []string
	for _, b := range h.router.broadcasts {
		if !seen[b] {
			seen[b] = true
			told = append(told, b)
		}
	}
	h.router.mu.Unlock()
	sort.Strings(told)

	masked := func(s string) string {
		s = strings.ReplaceAll(s, id, "<provider>")
		s = goldenUUID.ReplaceAllString(s, "<UUID>")
		s = goldenLowerUUID.ReplaceAllString(s, "<uuid>")
		return goldenDates.ReplaceAllString(s, `"$1":<date>`)
	}
	for i := range out {
		out[i] = masked(out[i])
	}
	once := map[string]bool{}
	var heard []string
	for _, b := range told {
		if b = masked(b); !once[b] {
			once[b] = true
			heard = append(heard, b)
		}
	}
	sort.Strings(heard)
	told = heard
	got := strings.Join(out, "\n\n") + "\n\n# told every window\n\n" + strings.Join(told, "\n") + "\n"

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

var (
	goldenUUID      = regexp.MustCompile(`[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}`)
	goldenLowerUUID = regexp.MustCompile(`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`)
	goldenDates     = regexp.MustCompile(`"(listedAt|since|at|wakeAt|nextWorkflowAt)":-?[0-9][0-9.eE+-]*`)
)
