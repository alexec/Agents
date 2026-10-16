package providers

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

// What a draft's check may run without asking (#858, FR-013, FR-014), and what its agent
// never sees (FR-022). Ports DraftSafetyTests.swift.

func safetyMap(list string, arguments any, start, stop string) any {
	call := map[string]any{"tool": list, "items": "", "id": "id", "name": "name", "state": "state"}
	if arguments != nil {
		call["arguments"] = arguments
	}
	return map[string]any{"list": call, "start": map[string]any{"tool": start}, "stop": map[string]any{"tool": stop}}
}

func TestListTools(t *testing.T) {
	for name, runs := range map[string]bool{
		"droplet-list": true, "list_droplets": true, "getInstances": true, "describe-workspaces": true,
		"droplets": false, "droplet-delete": false, "power-off-droplet": false, "list-and-reboot": false,
		"compose-down": false, "listAndTerminate": false,
	} {
		if (ListTool(safetyMap(name, nil, "power-on", "power-off"), nil) == Run) != runs {
			t.Errorf("%s", name)
		}
	}
}

func TestOtherReasonsAreAsked(t *testing.T) {
	if v := ListTool(safetyMap("list-x", nil, "list-x", "power-off"), nil); v.Ask != "list-x is the map’s start as well" {
		t.Errorf("%q", v.Ask)
	}
	destructive := []any{map[string]any{"name": "droplet-list", "annotations": map[string]any{"destructiveHint": true}}}
	if ListTool(safetyMap("droplet-list", nil, "a", "b"), destructive) == Run {
		t.Error("destructive")
	}
	writes := []any{map[string]any{"name": "droplet-list", "annotations": map[string]any{"readOnlyHint": false}}}
	if ListTool(safetyMap("droplet-list", nil, "a", "b"), writes) == Run {
		t.Error("writes")
	}
	if ListTool(safetyMap("droplet-list", map[string]any{"url": "https://x.example/${TOKEN}"}, "a", "b"), nil) == Run {
		t.Error("carries out")
	}
	if ListTool(safetyMap("droplet-list", map[string]any{"PerPage": 200}, "a", "b"), nil) != Run {
		t.Error("a page size")
	}
}

func TestCommands(t *testing.T) {
	for line, runs := range map[string]bool{
		"cws list": true, "cws ls --all": true, "cws status devstack-1": true, "cws get workspaces -o json": true,
		"cws list; rm -rf ~": false, "cws list | sh": false, "cws list > out": false, "cws list $(id)": false,
		"cws list --endpoint https://x.example": false, "cws list $TOKEN": false, "cws destroy all": false,
		"cws start x": false, "cws restart": false, "cws prune": false, "other list": false, "cws workspaces": false,
		"cws list\nrm x": false, "cws `list`": false,
	} {
		if (Command(line, "cws") == Run) != runs {
			t.Errorf("%q", line)
		}
	}
}

func TestAConfigsCheckRunsItsListOrEachStatusOrAPresetsOwn(t *testing.T) {
	if CommandsVerdict(mustParse(`{"preset": "docker", "containers": ["x"]}`), "docker") != Run ||
		CommandsVerdict(mustParse(`{"list": "cws list", "columns": ["id"]}`), "cws") != Run ||
		CommandsVerdict(mustParse(`{"workspaces": [{"name": "a", "status": "cws status a"}, {"name": "b", "status": "cws stop b"}]}`), "cws") == Run ||
		CommandsVerdict(mustParse(`{"workspaces": [{"name": "a", "start": "cws start a"}]}`), "cws") != Run {
		t.Error("configs")
	}
}

func TestHelpWords(t *testing.T) {
	seen := "Commands: list start stop destroy workspace-list"
	for _, ok := range [][]string{{}, {"list"}, {"start"}, {"workspace-list"}} {
		if HelpWords(ok, seen) != "" {
			t.Errorf("%v refused", ok)
		}
	}
	for _, bad := range [][]string{{"--yes"}, {"destroy"}, {"delete"}, {"frobnicate"}, {"list", "list", "list", "list"}, {"list;"}} {
		if HelpWords(bad, seen) == "" {
			t.Errorf("%v runs", bad)
		}
	}
}

func TestRedaction(t *testing.T) {
	redact := NewRedaction(map[string]string{"TOKEN": "dop_v1_abc/def+ghi", "PIN": "1234", "EMPTY": ""})
	for in, want := range map[string]string{
		"Bearer dop_v1_abc/def+ghi failed":                                         "Bearer ${TOKEN} failed",
		"t=dop_v1_abc%2Fdef%2Bghi":                                                 "t=${TOKEN}",
		"Basic " + base64.StdEncoding.EncodeToString([]byte("dop_v1_abc/def+ghi")): "Basic ${TOKEN}",
		"pin 1234 at port 12345":                                                   "pin ${PIN} at port 12345",
		"nothing here":                                                             "nothing here",
	} {
		if got := redact.Text(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
	got := redact.Value(mustParse(`{"a": ["dop_v1_abc/def+ghi", 3], "dop_v1_abc/def+ghi": true}`))
	if !jsonEqual(got, mustParse(`{"a": ["${TOKEN}", 3], "${TOKEN}": true}`)) {
		t.Errorf("%v", got)
	}
}

func TestSecretsAreLaidOverAndTakenAway(t *testing.T) {
	home := t.TempDir()
	s := NewSecrets(home)
	if err := s.Set("p", map[string]string{"A": "1", "B": "2"}); err != nil {
		t.Fatal(err)
	}
	s.Set("p", map[string]string{"A": "", "C": "3"})
	again := NewSecrets(home)
	if v := again.Values("p"); len(v) != 2 || v["B"] != "2" || v["C"] != "3" {
		t.Errorf("%v", v)
	}
	again.Remove("p")
	if v := NewSecrets(home).Values("p"); len(v) != 0 {
		t.Errorf("%v", v)
	}
	if info, err := os.Stat(filepath.Join(home, SecretsFileName)); err != nil || info.Mode().Perm() != 0o600 {
		t.Errorf("%v", err)
	}
	// As Swift writes it.
	os.WriteFile(filepath.Join(home, SecretsFileName), []byte("{\n  \"q\" : {\n    \"T\" : \"x\\/y\"\n  }\n}"), 0o600)
	if NewSecrets(home).Values("q")["T"] != "x/y" {
		t.Error("Swift's file not read")
	}
}
