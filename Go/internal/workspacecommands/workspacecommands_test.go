package workspacecommands

// The command provider (#691), ported from the Swift WorkspaceCommandsTests (#1364): its
// configuration, its presets' command lines, and the contract's tools, driven in process.
// Commands either run in a real /bin/sh (true, false, files in a scratch folder) or go to a
// recorder that answers as a CLI would.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// recorder answers each command line with what answer says, and keeps every line given.
type recorder struct {
	mu     sync.Mutex
	lines  []string
	answer func(string) (int, string)
}

func (r *recorder) run(line string, _ time.Duration) Outcome {
	r.mu.Lock()
	r.lines = append(r.lines, line)
	r.mu.Unlock()
	status, output := r.answer(line)
	return Outcome{Status: status, Output: []byte(output)}
}

func (r *recorder) all() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.lines...)
}

func (r *recorder) has(line string) bool {
	for _, l := range r.all() {
		if l == line {
			return true
		}
	}
	return false
}

var quick = Timing{Quick: 5 * time.Second, Long: 5 * time.Second, PollEvery: 20 * time.Millisecond}

// j is JSON text decoded as the server decodes it.
func j(t *testing.T, text string) any {
	t.Helper()
	v, err := decode([]byte(text))
	if err != nil {
		t.Fatalf("%s: %v", text, err)
	}
	return v
}

func config(t *testing.T, text string) Config {
	t.Helper()
	c, err := From(j(t, text))
	if err != nil {
		t.Fatalf("%s: %v", text, err)
	}
	return c
}

func refused(t *testing.T, text, want string) {
	t.Helper()
	_, err := From(j(t, text))
	if err == nil || err.Error() != want {
		t.Errorf("%s: %v, want %q", text, err, want)
	}
}

func server(t *testing.T, text string, timing Timing, run Runner) *Server {
	t.Helper()
	return NewServer(config(t, text), timing, run, "test")
}

// call is a tools/call's result, round-tripped through JSON as a client reads it.
func call(t *testing.T, s *Server, tool string, arguments string) map[string]any {
	t.Helper()
	if arguments == "" {
		arguments = "{}"
	}
	result, err := s.Handle("tools/call", map[string]any{"name": tool, "arguments": j(t, arguments)})
	if err != nil {
		t.Fatalf("%s: %v", tool, err)
	}
	var out map[string]any
	if err := json.Unmarshal(encode(result), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// at is the value at a path, as the tests read results.
func at(v any, path string) any { return PathValue(path, v) }

// same is whether got, as JSON, is want's JSON.
func same(t *testing.T, got any, want string) {
	t.Helper()
	var w any
	if err := json.Unmarshal([]byte(want), &w); err != nil {
		t.Fatal(err)
	}
	var g any
	_ = json.Unmarshal(encode(got), &g)
	if !reflect.DeepEqual(g, w) {
		t.Errorf("got %s\nwant %s", encode(got), want)
	}
}

func text(result map[string]any) any { return at(result, "content[0].text") }

// Configuration

func TestWrittenOutWorkspacesTakeTheirNameAsID(t *testing.T) {
	c := config(t, `{"workspaces":[{"name":"devstack","start":"cws start","stop":"cws stop"}]}`)
	if len(c.Workspaces) != 1 || c.Workspaces[0].ID != "devstack" || c.Workspaces[0].Commands.Status != "" {
		t.Errorf("%+v", c.Workspaces)
	}
}

func TestRefusesWhatCannotRun(t *testing.T) {
	refused(t, `{}`, "give workspaces, a list command, or a preset")
	refused(t, `{"workspaces":[{"name":"devstack","start":"x"}]}`, "devstack: no stop command")
	refused(t, `{"list":"x","columns":["name"],"start":"a","stop":"b"}`, "columns must name an id column")
	refused(t, `{"workspaces":[{"name":"a","start":"x","stop":"y"}],"states":{"on":"up"}}`,
		"states.on must be one of running, starting, stopping, stopped, unknown")
	refused(t, `{"preset":"vagrant"}`, "no preset vagrant; there are docker, doctl, codespaces, coder, gcloud-workstations, digitalocean-api, codespaces-api, coder-api, aws-ec2-api, gcp-compute-api")
	refused(t, `[]`, "the configuration must be a JSON object")
	refused(t, `{"list":"x","start":"a","stop":"b"}`, "a list needs columns, or json paths")
	refused(t, `{"list":"x","json":{"name":"n"},"start":"a","stop":"b"}`, "json needs an id path")
	refused(t, `{"workspaces":[{"name":"a","start":"x","stop":"y"},{"name":"a","start":"x","stop":"y"}]}`, "two workspaces are called a")
	if _, err := Parse(""); err == nil || err.Error() != "WORKSPACE_COMMANDS_CONFIG isn't JSON" {
		t.Errorf("%v", err)
	}
}

func TestStatesAreMatchedWithoutCaseOrSpace(t *testing.T) {
	c := config(t, `{"workspaces":[{"name":"a","start":"x","stop":"y"}],"states":{"Exited":"stopped"}}`)
	for said, want := range map[string]State{" exited\n": Stopped, "RUNNING": Running, "on fire": Unknown} {
		if got := c.StateFor(said); got != want {
			t.Errorf("%q: %s, want %s", said, got, want)
		}
	}
}

func TestTemplateValuesAreOneShellWord(t *testing.T) {
	if got := Fill("cws start ${name}", map[string]string{"name": "x'; rm -rf / #"}, true); got != `cws start 'x'\''; rm -rf / #'` {
		t.Error(got)
	}
	if got := Fill("${user}@${ip}", map[string]string{"user": "root", "ip": "10.0.0.2"}, false); got != "root@10.0.0.2" {
		t.Error(got)
	}
	// A name with no value is left for the shell: a secret in the environment.
	if got := Fill(`curl -H "Authorization: ${TOKEN}" ${id}`, map[string]string{"id": "7"}, true); got != `curl -H "Authorization: ${TOKEN}" '7'` {
		t.Error(got)
	}
	// An unclosed ${ is left as it is.
	if got := Fill("a ${id} ${b", map[string]string{"id": "1"}, false); got != "a 1 ${b" {
		t.Error(got)
	}
}

func TestPathsReadNestedValues(t *testing.T) {
	v := j(t, `{"networks":{"v4":[{"ip_address":"1.2.3.4"}]},"id":12,"up":true}`)
	if s, _ := PathText("networks.v4[0].ip_address", v); s != "1.2.3.4" {
		t.Error(s)
	}
	if s, _ := PathText("id", v); s != "12" {
		t.Error(s)
	}
	if s, _ := PathText("up", v); s != "true" {
		t.Error(s)
	}
	if PathValue("networks.v6[0]", v) != nil || PathValue("networks.v4[1]", v) != nil {
		t.Error("a missing path has a value")
	}
	if PathValue("", v) == nil {
		t.Error("an empty path is not the value")
	}
}

// Presets

func TestNoPresetAsksForSudo(t *testing.T) {
	configs := []string{
		`{"preset":"docker","containers":["agents-devbox"]}`,
		`{"preset":"docker"}`,
		`{"preset":"doctl","tag":"agents"}`,
		`{"preset":"codespaces"}`,
		`{"preset":"coder"}`,
		`{"preset":"gcloud-workstations","cluster":"c","config":"f","region":"r"}`,
		`{"preset":"digitalocean-api","tag":"agents"}`,
		`{"preset":"codespaces-api"}`,
		`{"preset":"coder-api","url":"https://coder.example"}`,
		`{"preset":"aws-ec2-api","region":"us-east-1"}`,
		`{"preset":"gcp-compute-api","project":"p","zone":"z"}`,
	}
	for _, text := range configs {
		c := config(t, text)
		var commands []Commands
		for _, w := range c.Workspaces {
			commands = append(commands, w.Commands)
		}
		var lines []string
		if c.Listing != nil {
			commands = append(commands, c.Listing.Commands)
			lines = append(lines, c.Listing.Command)
		}
		for _, cs := range commands {
			lines = append(lines, cs.Start, cs.Stop, cs.Status)
		}
		for _, l := range lines {
			if strings.Contains(l, "sudo") {
				t.Errorf("%s: %s", text, l)
			}
		}
	}
	if len(PresetNames) != len(configs)-1 {
		t.Errorf("%d presets", len(PresetNames))
	}
}

func TestDockerRunsTheContainersCommands(t *testing.T) {
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "docker inspect") {
			return 0, "exited\n"
		}
		return 0, ""
	}}
	s := server(t, `{"preset":"docker","containers":["agents-devbox"],"ssh":"alex@127.0.0.1 -p 2222"}`, quick, r.run)
	list := call(t, s, "workspaces_list", "")
	same(t, list["structuredContent"], `{"contract":1,"workspaces":[{"id":"agents-devbox","name":"agents-devbox","state":"stopped",
		"ssh":"alex@127.0.0.1 -p 2222","tunnel":false}]}`)
	if got := r.all(); !reflect.DeepEqual(got, []string{"docker inspect -f '{{.State.Status}}' 'agents-devbox'"}) {
		t.Errorf("%q", got)
	}
}

func TestDockerWithNoContainersListsTheLabelledOnes(t *testing.T) {
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "docker ps") {
			return 0, "devbox\trunning\talex@127.0.0.1 -p 2222\nbuild\texited\t\n"
		}
		return 0, ""
	}}
	s := server(t, `{"preset":"docker","containers":[],"ssh":"agents@build.local"}`, quick, r.run)
	list := call(t, s, "workspaces_list", "")
	same(t, at(list, "structuredContent.workspaces"), `[
		{"id":"devbox","name":"devbox","state":"running","ssh":"alex@127.0.0.1 -p 2222","tunnel":false},
		{"id":"build","name":"build","state":"stopped","ssh":"agents@build.local","tunnel":false}]`)
	want := []string{`docker ps -a --filter label=agents.workspace --format '{{.Names}}\t{{.State}}\t{{.Label "agents.ssh"}}'`}
	if got := r.all(); !reflect.DeepEqual(got, want) {
		t.Errorf("%q", got)
	}
}

func TestDockerWithNoSSHLineLeavesAnUnlabelledContainerWithoutOne(t *testing.T) {
	r := &recorder{answer: func(string) (int, string) { return 0, "build\texited\t\n" }}
	s := server(t, `{"preset":"docker"}`, quick, r.run)
	same(t, at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces"),
		`[{"id":"build","name":"build","state":"stopped","tunnel":false}]`)
}

func TestDoctlListsByTagAndReachesTheDropletByItsAddress(t *testing.T) {
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "doctl compute droplet list") {
			return 0, "4101  devbox  off  203.0.113.7\n4102  build  active  203.0.113.8\n"
		}
		return 0, ""
	}}
	s := server(t, `{"preset":"doctl","tag":"agents"}`, quick, r.run)
	same(t, at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces"), `[
		{"id":"4101","name":"devbox","state":"stopped","ssh":"root@203.0.113.7","tunnel":false},
		{"id":"4102","name":"build","state":"running","ssh":"root@203.0.113.8","tunnel":false}]`)
	if got := r.all()[0]; got != "doctl compute droplet list --tag-name 'agents' --format ID,Name,Status,PublicIPv4 --no-header" {
		t.Error(got)
	}
}

func TestPresetsCommandLines(t *testing.T) {
	doctl := config(t, `{"preset":"doctl","tag":"agents"}`).Listing
	if doctl.Commands.Start != "doctl compute droplet-action power-on ${id} --wait" ||
		doctl.Commands.Stop != "doctl compute droplet-action power-off ${id} --wait" {
		t.Errorf("%+v", doctl.Commands)
	}
	codespaces := config(t, `{"preset":"codespaces","repo":"alexec/Agents"}`).Listing
	if codespaces.Command != "gh codespace list --repo 'alexec/Agents' --json name,displayName,state" ||
		codespaces.Commands.Start != "gh codespace ssh -c ${id} -- true" ||
		codespaces.Commands.Stop != "gh codespace stop -c ${id}" || !codespaces.Commands.Tunnel {
		t.Errorf("%+v", codespaces)
	}
	coder := config(t, `{"preset":"coder"}`).Listing
	if coder.Command != "coder list -o json" || coder.Commands.Start != "coder start -y ${id}" || *coder.Commands.SSH != "coder.${name}" {
		t.Errorf("%+v", coder)
	}
	gcloud := config(t, `{"preset":"gcloud-workstations","cluster":"c","config":"f","region":"r"}`).Listing
	if gcloud.Command != "gcloud workstations list --cluster='c' --config='f' --region='r' --format='value(name.basename(),state)'" ||
		gcloud.Commands.Start != "gcloud workstations start ${id} --cluster='c' --config='f' --region='r'" {
		t.Errorf("%+v", gcloud)
	}
	inProject := config(t, `{"preset":"gcloud-workstations","cluster":"c","config":"f","region":"r","project":"p"}`).Listing
	if inProject.Commands.Stop != "gcloud workstations stop ${id} --cluster='c' --config='f' --region='r' --project='p'" {
		t.Errorf("%+v", inProject)
	}
	refused(t, `{"preset":"doctl"}`, "the doctl preset needs a tag")
	refused(t, `{"preset":"gcloud-workstations","cluster":"c","config":"f"}`, "the gcloud-workstations preset needs region")
}

func TestCoderStatesComeFromItsJSON(t *testing.T) {
	r := &recorder{answer: func(string) (int, string) {
		return 0, `[{"name":"dev","latest_build":{"status":"stopped"}},{"name":"ci","latest_build":{"status":"running"}}]`
	}}
	list := call(t, server(t, `{"preset":"coder"}`, quick, r.run), "workspaces_list", "")
	if at(list, "structuredContent.workspaces[0].state") != "stopped" || at(list, "structuredContent.workspaces[1].state") != "running" {
		t.Errorf("%v", list)
	}
	if at(list, "structuredContent.workspaces[0].ssh") != "coder.dev" {
		t.Errorf("%v", list)
	}
}

func TestAListingThatIsNotJSONSaysWhere(t *testing.T) {
	r := &recorder{answer: func(string) (int, string) { return 0, "nope" }}
	list := call(t, server(t, `{"list":"cli ls","json":{"items":"data","id":"name"},"start":"a","stop":"b"}`, quick, r.run), "workspaces_list", "")
	if list["isError"] != true || text(list) != "The list command's output isn't a JSON array at data." {
		t.Errorf("%v", list)
	}
}

// The server

// fileBacked is a workspace whose state is a file: start makes it, stop takes it away.
func fileBacked(t *testing.T, start string) *Server {
	marker := ShellQuoted(filepath.Join(t.TempDir(), "up"))
	if start == "" {
		start = "touch " + marker
	} else {
		start = strings.ReplaceAll(start, "MARKER", marker)
	}
	c, err := From(map[string]any{"workspaces": []any{map[string]any{
		"name": "devbox", "start": start, "stop": "rm -f " + marker,
		"status": "test -e " + marker + " && echo running || echo stopped"}}})
	if err != nil {
		t.Fatal(err)
	}
	return NewServer(c, quick, Shell, "test")
}

func toolNames(t *testing.T, s *Server) []string {
	result, err := s.Handle("tools/list", nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range result.(map[string]any)["tools"].([]any) {
		names = append(names, tool.(map[string]any)["name"].(string))
	}
	return names
}

func TestListsToolsOfTheContract(t *testing.T) {
	if got := toolNames(t, fileBacked(t, "")); !reflect.DeepEqual(got, []string{"workspaces_list", "workspace_start", "workspace_stop"}) {
		t.Errorf("%q", got)
	}
}

func TestStartsAndStopsThroughTheShell(t *testing.T) {
	s := fileBacked(t, "")
	if got := at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces[0].state"); got != "stopped" {
		t.Error(got)
	}
	started := call(t, s, "workspace_start", `{"id":"devbox"}`)
	if started["isError"] != nil || at(started, "structuredContent.workspace.state") != "running" {
		t.Errorf("%v", started)
	}
	stopped := call(t, s, "workspace_stop", `{"id":"devbox"}`)
	if at(stopped, "structuredContent.workspace.state") != "stopped" {
		t.Errorf("%v", stopped)
	}
}

func TestStartWaitsForTheStatusToSayRunning(t *testing.T) {
	// The start returns at once; the workspace is up a moment later, as a cloud one is.
	s := fileBacked(t, "(sleep 0.3; touch MARKER) >/dev/null 2>&1 &")
	if got := at(call(t, s, "workspace_start", `{"id":"devbox"}`), "structuredContent.workspace.state"); got != "running" {
		t.Error(got)
	}
}

func TestAFailedStartSaysWhyInTheCommandsWords(t *testing.T) {
	result := call(t, fileBacked(t, "echo 'Error: droplet is locked' >&2; exit 1"), "workspace_start", `{"id":"devbox"}`)
	if result["isError"] != true || text(result) != "Error: droplet is locked" {
		t.Errorf("%v", result)
	}
}

func TestAMissingCLIIsNamed(t *testing.T) {
	result := call(t, fileBacked(t, "no-such-cli-691 start devbox"), "workspace_start", `{"id":"devbox"}`)
	if text(result) != "no-such-cli-691 isn't installed where the control plane runs." {
		t.Errorf("%v", result)
	}
}

func TestASilentFailureSaysItsStatus(t *testing.T) {
	result := call(t, fileBacked(t, "exit 3"), "workspace_start", `{"id":"devbox"}`)
	if text(result) != "exit exited with 3." {
		t.Errorf("%v", result)
	}
}

func TestAStartThatNeverComesUpTimesOut(t *testing.T) {
	s := server(t, `{"workspaces":[{"name":"devbox","start":"true","stop":"true","status":"echo starting"}]}`,
		Timing{Quick: 5 * time.Second, Long: 300 * time.Millisecond, PollEvery: 50 * time.Millisecond}, Shell)
	if got := text(call(t, s, "workspace_start", `{"id":"devbox"}`)); got != "devbox was still starting after 0 seconds." {
		t.Error(got)
	}
}

func TestACommandPastItsDeadlineIsStopped(t *testing.T) {
	s := server(t, `{"workspaces":[{"name":"devbox","start":"sleep 30","stop":"true"}]}`,
		Timing{Quick: 5 * time.Second, Long: 300 * time.Millisecond, PollEvery: 50 * time.Millisecond}, Shell)
	began := time.Now()
	if got := text(call(t, s, "workspace_start", `{"id":"devbox"}`)); got != "Starting devbox took longer than 0 seconds." {
		t.Error(got)
	}
	if time.Since(began) > 10*time.Second {
		t.Error("the stopped command was waited on")
	}
}

func TestWithoutAStatusTheLastActionIsTheState(t *testing.T) {
	s := server(t, `{"workspaces":[{"name":"devstack","start":"true","stop":"true"}]}`, quick, Shell)
	if got := at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces[0].state"); got != "unknown" {
		t.Error(got)
	}
	call(t, s, "workspace_start", `{"id":"devstack"}`)
	if got := at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces[0].state"); got != "running" {
		t.Error(got)
	}
}

func TestAnUnknownWorkspaceIsRefused(t *testing.T) {
	if got := text(call(t, fileBacked(t, ""), "workspace_start", `{"id":"nope"}`)); got != "There is no workspace nope." {
		t.Error(got)
	}
}

func TestASecretReachesTheCommandFromTheEnvironment(t *testing.T) {
	// The control plane passes secrets as the server's environment; commands inherit it.
	t.Setenv("WORKSPACE_COMMANDS_TEST_TOKEN", "hunter2")
	s := server(t, `{"workspaces":[{"name":"devbox","start":"test \"$WORKSPACE_COMMANDS_TEST_TOKEN\" = hunter2","stop":"true"}]}`, quick, Shell)
	result := call(t, s, "workspace_start", `{"id":"devbox"}`)
	if result["isError"] != nil || strings.Contains(string(encode(result)), "hunter2") {
		t.Errorf("%v", result)
	}
}

func TestAListingIsCutAt200(t *testing.T) {
	var rows []string
	for i := 1; i <= 250; i++ {
		rows = append(rows, fmt.Sprintf("w%d stopped", i))
	}
	r := &recorder{answer: func(string) (int, string) { return 0, strings.Join(rows, "\n") }}
	s := server(t, `{"list":"cloud ls","columns":["id","state"],"start":"cloud up ${id}","stop":"cloud down ${id}"}`, quick, r.run)
	if got := at(call(t, s, "workspaces_list", ""), "structuredContent.workspaces").([]any); len(got) != 200 {
		t.Error(len(got))
	}
}

func TestTheLastColumnTakesTheRestOfTheLine(t *testing.T) {
	if got := splitColumns("devbox  running  alex@host -p 2222", 2); !reflect.DeepEqual(got, []string{"devbox", "running", " alex@host -p 2222"}) {
		t.Errorf("%q", got)
	}
	if got := splitColumns("build\texited\t", 2); !reflect.DeepEqual(got, []string{"build", "exited"}) {
		t.Errorf("%q", got)
	}
	if got := splitColumns("  a b", 5); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Errorf("%q", got)
	}
}

// Arguments and the wire

func TestArgumentsAreChecked(t *testing.T) {
	s := fileBacked(t, "")
	for args, want := range map[string]string{
		`{}`:               "missing id",
		`{"id":null}`:      "missing id",
		`{"id":7}`:         "id must be a string",
		`{"id":"a","x":1}`: "unknown argument x; takes id",
		`{"id":"` + strings.Repeat("a", 513) + `"}`: "id is over 512 characters",
	} {
		_, err := s.Handle("tools/call", map[string]any{"name": "workspace_start", "arguments": j(t, args)})
		var rpc *RPCError
		if !errors.As(err, &rpc) || rpc.Code != -32602 || rpc.Message != want {
			t.Errorf("%s: %v, want %q", args, err, want)
		}
	}
	_, err := s.Handle("tools/call", map[string]any{"name": "nope"})
	if err == nil || err.Error() != "no tool nope" {
		t.Error(err)
	}
}

func TestServesJSONRPCOnStdio(t *testing.T) {
	s := fileBacked(t, "")
	in := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}`,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		``,
		`not json`,
		`{"jsonrpc":"2.0","id":"p","method":"ping"}`,
		`{"jsonrpc":"2.0","id":3,"method":"nope"}`,
		`[{"jsonrpc":"2.0","id":4,"method":"ping"},{"jsonrpc":"2.0","method":"x"}]`,
		`{"jsonrpc":"2.0","id":5,"result":{}}`,
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"workspace_start","arguments":{"id":"devbox"}}}`,
		`{"jsonrpc":"2.0","id":7,"method":"ping","params":{"pad":"` + strings.Repeat("x", MaxLine) + `"}}`,
	}, "\n") + "\n"
	var out bytes.Buffer
	if err := s.Serve(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	answers := map[string]map[string]any{}
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		var v any
		if err := json.Unmarshal([]byte(line), &v); err != nil {
			t.Fatalf("%s: %v", line, err)
		}
		if batch, ok := v.([]any); ok {
			if len(batch) != 1 {
				t.Errorf("batch: %s", line)
			}
			v = batch[0]
		}
		m := v.(map[string]any)
		key := fmt.Sprint(m["id"])
		if m["id"] == nil {
			key = fmt.Sprint(at(m, "error.message"))
		}
		answers[key] = m
	}
	if len(answers) != 7 {
		t.Errorf("%d answers: %s", len(answers), out.String())
	}
	if at(answers["1"], "result.protocolVersion") != "2025-06-18" || at(answers["1"], "result.serverInfo.name") != "workspace-commands" {
		t.Errorf("%v", answers["1"])
	}
	if at(answers["parse error"], "error.code") != float64(-32700) || at(answers["message too large"], "error.code") != float64(-32600) {
		t.Errorf("%v", answers)
	}
	if at(answers["3"], "error.code") != float64(-32601) || answers["4"]["result"] == nil || answers["p"]["result"] == nil {
		t.Errorf("%v", answers)
	}
	if at(answers["6"], "result.structuredContent.workspace.state") != "running" {
		t.Errorf("%v", answers["6"])
	}
}

func TestAnUnknownProtocolVersionGetsTheNewest(t *testing.T) {
	result, _ := fileBacked(t, "").Handle("initialize", map[string]any{"protocolVersion": "1999-01-01"})
	same(t, result.(map[string]any)["protocolVersion"], `"`+ProtocolVersions[0]+`"`)
	same(t, result.(map[string]any)["capabilities"], `{"tools":{}}`)
}

// Making and deleting workspaces (US5): a listing's create and delete commands, with the
// form's options and the first-boot command filled in as single shell words.

// made is a CLI whose list is what has been made.
type made struct {
	mu    sync.Mutex
	names []string
}

func (m *made) add(name string) { m.mu.Lock(); m.names = append(m.names, name); m.mu.Unlock() }
func (m *made) remove(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var kept []string
	for _, n := range m.names {
		if n != name {
			kept = append(kept, n)
		}
	}
	m.names = kept
}
func (m *made) list(sep string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	var lines []string
	for _, n := range m.names {
		lines = append(lines, n+sep+n+sep+"off")
	}
	return strings.Join(lines, "\n")
}

const makingConfig = `{"list":"cli list","columns":["id","name","state"],
	"start":"cli start ${id}","stop":"cli stop ${id}","states":{"off":"stopped"},
	"create":"cli make ${name} --size ${size} --user-data ${firstBoot}",
	"delete":"cli delete ${id}",
	"options":{"type":"object","properties":{"size":{"type":"string","title":"Size","enum":["small","big"]}}}}`

func TestOffersTheToolsItCanAnswer(t *testing.T) {
	m := &made{}
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "cli list") {
			return 0, m.list(" ")
		}
		return 0, ""
	}}
	s := server(t, makingConfig, quick, r.run)
	want := []string{"workspaces_list", "workspace_start", "workspace_stop", "workspace_options", "workspace_create", "workspace_delete"}
	if got := toolNames(t, s); !reflect.DeepEqual(got, want) {
		t.Errorf("%q", got)
	}
	if got := at(call(t, s, "workspace_options", ""), "structuredContent.schema.properties.size.title"); got != "Size" {
		t.Error(got)
	}
}

func TestMakesOneWithItsChoicesAndFindsItInTheList(t *testing.T) {
	m := &made{}
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "cli list") {
			return 0, m.list(" ")
		}
		if strings.HasPrefix(line, "cli make") {
			m.add("build-2")
		}
		return 0, ""
	}}
	s := server(t, `{"list":"cli list","columns":["id","name","state"],
		"start":"cli start ${id}","stop":"cli stop ${id}","states":{"off":"stopped"},
		"create":"cli make ${name} --size ${size} --user-data ${firstBoot}"}`, quick, r.run)
	answer := call(t, s, "workspace_create", `{"name":"build-2","options":{"size":"big"},
		"firstBoot":"curl -fsSL https://x/install.sh | sh -s -- 'code; rm -rf'"}`)
	if at(answer, "structuredContent.workspace.id") != "build-2" || at(answer, "structuredContent.firstBootRuns") != true {
		t.Errorf("%v", answer)
	}
	// The first-boot command is one word, whatever it holds.
	if want := `cli make 'build-2' --size 'big' --user-data 'curl -fsSL https://x/install.sh | sh -s -- '\''code; rm -rf'\'''`; !r.has(want) {
		t.Errorf("%q", r.all())
	}
	// A second with the same name is refused.
	again := call(t, s, "workspace_create", `{"name":"build-2"}`)
	if again["isError"] != true || text(again) != "There is already a workspace called build-2." {
		t.Errorf("%v", again)
	}
}

func TestDeletesByItsListingsValues(t *testing.T) {
	m := &made{}
	m.add("build-2")
	r := &recorder{answer: func(line string) (int, string) {
		if strings.HasPrefix(line, "cli list") {
			return 0, m.list(" ")
		}
		if strings.HasPrefix(line, "cli delete") {
			m.remove("build-2")
		}
		return 0, ""
	}}
	s := server(t, `{"list":"cli list","columns":["id","name","state"],
		"start":"cli start ${id}","stop":"cli stop ${id}",
		"create":"cli make ${name}","delete":"cli delete ${id}"}`, quick, r.run)
	answer := call(t, s, "workspace_delete", `{"id":"build-2"}`)
	if answer["isError"] == true || !r.has("cli delete 'build-2'") {
		t.Errorf("%v %q", answer, r.all())
	}
	// The list doesn't show it, as this CLI makes nothing.
	other := call(t, s, "workspace_create", `{"name":"other"}`)
	if other["isError"] != true || text(other) != "other was made, but the list doesn't show it yet." {
		t.Errorf("%v", other)
	}
}

func TestDockerWithAnImageMakesAndDeletesLabelledContainers(t *testing.T) {
	m := &made{}
	r := &recorder{answer: func(line string) (int, string) {
		switch {
		case strings.HasPrefix(line, "docker ps"):
			return 0, m.list("\t")
		case strings.HasPrefix(line, "docker run"):
			m.add("build-2")
		case strings.HasPrefix(line, "docker rm"):
			m.remove("build-2")
		}
		return 0, ""
	}}
	s := server(t, `{"preset":"docker","image":"agents-devbox:latest"}`, quick, r.run)
	if got := at(call(t, s, "workspace_options", ""), "structuredContent.schema.properties.image.default"); got != "agents-devbox:latest" {
		t.Error(got)
	}
	// The image left out takes the form's default.
	answer := call(t, s, "workspace_create", `{"name":"build-2","firstBoot":"curl -fsSL https://x/install.sh | sh"}`)
	if at(answer, "structuredContent.firstBootRuns") != true {
		t.Errorf("%v", answer)
	}
	if want := `docker run -d --name 'build-2' --label agents.workspace 'agents-devbox:latest' && docker exec 'build-2' sh -c 'curl -fsSL https://x/install.sh | sh'`; !r.has(want) {
		t.Errorf("%q", r.all())
	}
	call(t, s, "workspace_delete", `{"id":"build-2"}`)
	if !r.has("docker rm -f -v 'build-2'") {
		t.Errorf("%q", r.all())
	}
	// Without an image, or with named containers, it makes nothing.
	if config(t, `{"preset":"docker"}`).Making.Create != "" || config(t, `{"preset":"docker","containers":["a"],"image":"x"}`).Making.Create != "" {
		t.Error("docker makes workspaces without an image")
	}
}

func TestCreateNeedsAListing(t *testing.T) {
	refused(t, `{"workspaces":[{"name":"a","start":"x","stop":"y"}],"create":"make"}`,
		"create and delete need a list command, which finds what they made")
	refused(t, `{"list":"l","columns":["id"],"start":"x","stop":"y","options":{"type":"object"}}`,
		"options are for a create command, and there is none")
}
