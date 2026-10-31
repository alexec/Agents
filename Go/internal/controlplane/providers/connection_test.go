package providers

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// Reading providers' tools (#691): ToolMappingTests and ShippedDigitalOceanMapTests.

func parsed(t *testing.T, text string) any {
	t.Helper()
	v, err := parseJSON([]byte(text))
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestTheContractsResultsAreRead(t *testing.T) {
	content, err := Content(parsed(t, `{"content": [{"type": "text", "text": "…"}],
		"structuredContent": {"contract": 1, "workspaces": [
			{"id": "a", "name": "devbox", "state": "stopped", "ssh": "alex@h -p 2222", "tunnel": true, "cost": "$1"},
			{"id": "b", "name": "odd", "state": "hibernating"},
			{"name": "no id"}]}}`))
	if err != nil {
		t.Fatal(err)
	}
	yes := true
	want := []MachineInfo{{ID: "a", Name: "devbox", State: "stopped", SSH: new("alex@h -p 2222"), Tunnel: &yes, Cost: new("$1")},
		{ID: "b", Name: "odd", State: "unknown"}}
	if got := ContractMapping.Workspaces(content); !reflect.DeepEqual(got, want) {
		t.Errorf("%+v", got)
	}
}

func TestAnErrorIsTheProvidersOwnWords(t *testing.T) {
	_, err := Content(parsed(t, `{"content": [{"type": "text", "text": "Error: droplet is locked\n"}], "isError": true}`))
	if err == nil || err.Error() != "Error: droplet is locked" {
		t.Errorf("%v", err)
	}
}

func TestAMapReadsAnotherServersTools(t *testing.T) {
	m, err := MapFrom(parsed(t, `{
		"list": {"tool": "droplet-list", "arguments": {"tag_name": "agents"}, "items": "droplets[]",
			"id": "id", "name": "name", "state": "status", "ssh": "root@{networks.v4[0].ip_address}",
			"states": {"active": "running", "off": "stopped"}},
		"start": {"tool": "droplet-actions-power-on", "arguments": {"droplet_id": "{id}"}},
		"stop": {"tool": "droplet-actions-power-off", "arguments": {"droplet_id": "{id}"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if m.Missing([]string{"droplet-list", "droplet-actions-power-on"}) != "droplet-actions-power-off" ||
		m.Missing([]string{"droplet-list", "droplet-actions-power-on", "droplet-actions-power-off"}) != "" {
		t.Error("missing")
	}
	if !jsonEqual(m.ArgumentsFor(m.Start, "4101"), map[string]any{"droplet_id": "4101"}) {
		t.Errorf("%v", m.ArgumentsFor(m.Start, "4101"))
	}
	found := m.Workspaces(parsed(t, `{"droplets": [
		{"id": 4101, "name": "devbox", "status": "off", "networks": {"v4": [{"ip_address": "203.0.113.7"}]}},
		{"id": 4102, "name": "build", "status": "active", "networks": {"v4": []}}]}`))
	want := []MachineInfo{{ID: "4101", Name: "devbox", State: "stopped", SSH: new("root@203.0.113.7")}, {ID: "4102", Name: "build", State: "running"}}
	if !reflect.DeepEqual(found, want) {
		t.Errorf("%+v", found)
	}
}

func TestAMapMissingWhatItNeedsIsRefused(t *testing.T) {
	_, err := MapFrom(parsed(t, `{"list": {"tool": "l", "id": "id", "name": "n", "state": "s"}, "start": {"tool": "s"}}`))
	if err == nil || err.Error() != "The tool map has no stop.tool." {
		t.Errorf("%v", err)
	}
	_, err = MapFrom(parsed(t, `{"list": {"tool": "l", "id": "id", "name": "n"}, "start": {"tool": "s"}, "stop": {"tool": "t"}}`))
	if err == nil || err.Error() != "The tool map has no list.state." {
		t.Errorf("%v", err)
	}
}

func TestAnSSHDestinationWithAPortBecomesOneWord(t *testing.T) {
	if SSHDestination("alex@127.0.0.1 -p 2222") != "ssh://alex@127.0.0.1:2222" || SSHDestination("devstack-1.cws") != "devstack-1.cws" {
		t.Error("ssh destination")
	}
}

func TestARecordsSecretsAreChecked(t *testing.T) {
	url := "https://coder.example/mcp"
	r := ProviderRecord{ID: "x", Name: "Coder", Kind: KindHTTP, URL: &url, Headers: map[string]string{"Authorization": "Bearer ${CODER_TOKEN}"}}
	if r.Problem() != "${CODER_TOKEN} isn’t one of its secrets." {
		t.Errorf("%q", r.Problem())
	}
	r.SecretNames = []string{"CODER_TOKEN"}
	if r.Problem() != "" {
		t.Errorf("%q", r.Problem())
	}
	bad := "coder.example"
	r.URL = &bad
	if r.Problem() != "The address must start with http:// or https://." {
		t.Errorf("%q", r.Problem())
	}
}

func TestAnHTTPProvidersSecretGoesInItsHeaders(t *testing.T) {
	url := "https://coder.example/mcp"
	r := ProviderRecord{ID: "x", Name: "Coder", Kind: KindHTTP, URL: &url, Headers: map[string]string{"Authorization": "Bearer ${CODER_TOKEN}"},
		SecretNames: []string{"CODER_TOKEN"}}
	server, err := serverFor(r, map[string]string{"CODER_TOKEN": "t0k"}, "")
	if err != nil || !server.HTTP || server.URL != url || server.Headers["Authorization"] != "Bearer t0k" {
		t.Errorf("%v %+v", err, server)
	}
	_, err = serverFor(ProviderRecord{ID: "y", Name: "d", Kind: KindCommands, Commands: map[string]any{"preset": "docker"}}, nil, "")
	if err == nil || err.Error() != "workspace-commands isn’t installed beside the control plane." {
		t.Errorf("%v", err)
	}
}

func TestAMapsArgumentsTakeTheNameAndTheChoices(t *testing.T) {
	m, err := MapFrom(parsed(t, `{
		"list": {"tool": "list_droplets", "items": "droplets", "id": "id", "name": "name", "state": "status"},
		"start": {"tool": "power_on", "arguments": {"droplet": "{id}"}},
		"stop": {"tool": "power_off", "arguments": {"droplet": "{id}"}},
		"create": {"tool": "create_droplet", "arguments": {"name": "{name}", "size": "{size}", "user_data": "{firstBoot}", "tags": ["agents"]}},
		"delete": {"tool": "delete_droplet", "arguments": {"droplet": "{id}"}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(m.Capabilities(), []string{"create", "delete"}) {
		t.Errorf("%v", m.Capabilities())
	}
	args := m.Arguments(*m.Create, map[string]any{"name": "b-2", "size": "big", "options": map[string]any{"size": "big"}})
	// No first boot given: left out, not sent empty.
	if !jsonEqual(args, map[string]any{"name": "b-2", "size": "big", "tags": []any{"agents"}}) {
		t.Errorf("%v", args)
	}
	if m.Missing([]string{"list_droplets", "power_on", "power_off", "create_droplet"}) != "delete_droplet" {
		t.Error("missing")
	}
}

func TestTheShippedDigitalOceanMap(t *testing.T) {
	m, err := MapFrom(ShippedDigitalOceanMap)
	if err != nil {
		t.Fatal(err)
	}
	if m.Missing([]string{"droplet-list", "power-on-droplet", "power-off-droplet", "droplet-delete", "droplet-create"}) != "" ||
		!reflect.DeepEqual(m.Capabilities(), []string{"delete"}) {
		t.Error("tools")
	}
	listed := m.Workspaces(parsed(t, `{"droplets": [{"id": 51234, "name": "agents-devbox", "status": "off",
		"networks": {"v4": [{"ip_address": "203.0.113.7", "type": "public"}]}, "size": {"price_hourly": 0.02976}}]}`))
	want := []MachineInfo{{ID: "51234", Name: "agents-devbox", State: "stopped", SSH: new("root@203.0.113.7"), Cost: new("$0.02976/hour while running")}}
	if !reflect.DeepEqual(listed, want) {
		t.Errorf("%+v", listed)
	}
	if string(rawOf(m.ArgumentsFor(m.Start, "51234"))) != `{"ID":51234}` || !jsonEqual(m.ArgumentsFor(m.List, ""), map[string]any{"PerPage": 200}) {
		t.Errorf("%s", rawOf(m.ArgumentsFor(m.Start, "51234")))
	}
}

// A provider that breaks the contract (#857): MisbehavingProviderTests, with this test
// binary as the stdio server (FAKE_PROVIDER says how it misbehaves).

func fakeProvider(mode string) {
	out := bufio.NewWriter(os.Stdout)
	var lock sync.Mutex
	send := func(m any) {
		lock.Lock()
		defer lock.Unlock()
		data, _ := json.Marshal(m)
		out.Write(append(data, '\n'))
		out.Flush()
	}
	answer := func(id any, content any, text *string, isError bool) {
		t := ""
		if text != nil {
			t = *text
		} else {
			data, _ := json.Marshal(content)
			t = string(data)
		}
		result := map[string]any{"content": []any{map[string]any{"type": "text", "text": t}}}
		if content != nil && text == nil {
			result["structuredContent"] = content
		}
		if isError {
			result["isError"] = true
		}
		send(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	item := func(extra map[string]any) map[string]any {
		out := map[string]any{"id": "devbox", "name": "devbox", "state": "stopped"}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}
	listing := func() any {
		switch mode {
		case "no-contract":
			return map[string]any{"workspaces": []any{item(nil)}}
		case "contract-2":
			return map[string]any{"contract": 2, "workspaces": []any{item(nil)}}
		case "odd-items":
			return map[string]any{"contract": 1, "workspaces": []any{item(map[string]any{"state": "Hibernating"}),
				map[string]any{"name": "no-id", "state": "running"}, item(map[string]any{"id": "", "name": "empty-id"}),
				item(map[string]any{"name": "twin", "state": "running"}), "not an object", item(map[string]any{"id": 7, "name": "numbered"})}}
		}
		return map[string]any{"contract": 1, "workspaces": []any{item(nil)}}
	}
	call := func(id any, tool string) {
		switch {
		case tool == "workspaces_list" && mode == "not-json":
			text := "devbox is stopped"
			answer(id, nil, &text, false)
		case tool == "workspaces_list":
			answer(id, listing(), nil, false)
		case mode == "crash" && tool == "workspace_start":
			os.Exit(3)
		case mode == "hang" && tool == "workspace_start":
			time.Sleep(30 * time.Second)
		case mode == "refuse":
			text := "Quota exceeded. " + strings.Repeat("x", 3000)
			answer(id, nil, &text, true)
		case mode == "silent-refusal":
			text := ""
			answer(id, nil, &text, true)
		case mode == "bare-start":
			answer(id, map[string]any{}, nil, false)
		default:
			state := "stopped"
			if tool == "workspace_start" {
				state = "running"
			}
			answer(id, map[string]any{"workspace": item(map[string]any{"state": state})}, nil, false)
		}
	}
	dropped := false // drops-stop: once the provider was added (its first call), workspace_stop goes
	in := bufio.NewReader(os.Stdin)
	for {
		line, err := in.ReadBytes('\n')
		if len(line) > 0 {
			var message map[string]any
			json.Unmarshal(line, &message)
			method, _ := message["method"].(string)
			id := message["id"]
			switch {
			case method == "initialize":
				if mode == "noise" {
					lock.Lock()
					out.WriteString("starting up...\n")
					out.Flush()
					lock.Unlock()
				}
				send(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"protocolVersion": mcpProtocolVersion,
					"capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "fake", "version": "1"}}})
			case method == "tools/list":
				names := []string{"workspaces_list", "workspace_start", "workspace_stop"}
				if mode == "no-stop" || dropped {
					names = names[:2]
				}
				var tools []any
				for _, n := range names {
					tools = append(tools, map[string]any{"name": n, "inputSchema": map[string]any{"type": "object"}})
				}
				send(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"tools": tools}})
			case method == "tools/call":
				params, _ := message["params"].(map[string]any)
				name, _ := params["name"].(string)
				if dropped && name == "workspace_stop" {
					send(map[string]any{"jsonrpc": "2.0", "id": id, "error": map[string]any{"code": -32602, "message": "Unknown tool: workspace_stop"}})
					continue
				}
				dropped = mode == "drops-stop"
				go call(id, name)
			case id != nil:
				send(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{}})
			}
		}
		if err != nil {
			return
		}
	}
}

func fake(t *testing.T, mode string, timing CallTiming) *Connection {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exe
	r := ProviderRecord{ID: "fake-" + mode, Name: "Fake", Kind: KindStdio, Command: &command, Args: []string{"-test.run=^$"}}
	c, err := NewConnection(r, map[string]string{"FAKE_PROVIDER": mode}, t.TempDir(), timing, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.End)
	return c
}

var fiveSeconds = CallTiming{Quick: 5 * time.Second, Long: 5 * time.Second}

func said(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestAWellBehavedOneIsReadAsTheContractSays(t *testing.T) {
	c := fake(t, "", fiveSeconds)
	checked, err := c.Check()
	if err != nil || len(checked.Workspaces) != 1 || checked.Workspaces[0].State != "stopped" {
		t.Fatalf("%v %+v", err, checked)
	}
	if w, err := c.Start("devbox"); err != nil || w == nil || w.State != "running" {
		t.Errorf("%v %+v", err, w)
	}
}

func TestAMissingToolIsNamed(t *testing.T) {
	_, err := fake(t, "no-stop", fiveSeconds).Check()
	if said(err) != "It isn’t a machine provider: it has no workspace_stop tool." {
		t.Errorf("%v", err)
	}
}

func TestAListWithoutItsContractOrWithAnUnknownOneIsRefused(t *testing.T) {
	if _, err := fake(t, "no-contract", fiveSeconds).Check(); said(err) != "Its workspaces_list doesn’t say which contract it follows." {
		t.Errorf("%v", err)
	}
	if _, err := fake(t, "contract-2", fiveSeconds).Check(); said(err) != "It follows contract 2; this control plane reads 1." {
		t.Errorf("%v", err)
	}
}

func TestOddItemsAreLeftOutOrReadAsUnknown(t *testing.T) {
	listed, err := fake(t, "odd-items", fiveSeconds).List()
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, w := range listed {
		names = append(names, w.Name)
	}
	// "twin" has devbox's id: a second workspace with an id already listed is left out.
	if !reflect.DeepEqual(names, []string{"devbox", "numbered"}) || listed[0].State != "unknown" || listed[1].ID != "7" {
		t.Errorf("%+v", listed)
	}
}

func TestTextThatIsNotJSONIsSaidSo(t *testing.T) {
	if _, err := fake(t, "not-json", fiveSeconds).List(); said(err) != "The provider’s answer isn’t JSON." {
		t.Errorf("%v", err)
	}
}

func TestALineThatIsNotJSONRPCIsPassedOver(t *testing.T) {
	if checked, err := fake(t, "noise", fiveSeconds).Check(); err != nil || len(checked.Workspaces) != 1 {
		t.Errorf("%v", err)
	}
}

func TestARefusalIsInItsOwnWordsCutAt1KB(t *testing.T) {
	_, err := fake(t, "refuse", fiveSeconds).Start("devbox")
	if !strings.HasPrefix(said(err), "Quota exceeded.") || len(said(err)) != 1024 {
		t.Errorf("%d %q", len(said(err)), said(err)[:20])
	}
	if _, err := fake(t, "silent-refusal", fiveSeconds).Start("devbox"); said(err) != "The provider said no, and not why." {
		t.Errorf("%v", err)
	}
}

func TestAStartWithoutItsWorkspaceIsNotAFailure(t *testing.T) {
	if w, err := fake(t, "bare-start", fiveSeconds).Start("devbox"); err != nil || w != nil {
		t.Errorf("%v %+v", err, w)
	}
}

func TestAHungStartRunsOutOfTimeAndTheNextCallStillWorks(t *testing.T) {
	c := fake(t, "hang", CallTiming{Quick: 5 * time.Second, Long: time.Second})
	if _, err := c.Start("devbox"); said(err) != "It didn’t answer in time." {
		t.Errorf("%v", err)
	}
	if listed, err := c.List(); err != nil || len(listed) != 1 {
		t.Errorf("%v", err)
	}
}

func TestACrashMidStartIsSaidAndTheNextCallStartsItAgain(t *testing.T) {
	c := fake(t, "crash", fiveSeconds)
	if _, err := c.Start("devbox"); said(err) == "" {
		t.Error("no failure")
	}
	if listed, err := c.List(); err != nil || len(listed) != 1 {
		t.Errorf("%v", err)
	}
}

func TestAToolDroppedAfterTheProviderWasAddedIsNamed(t *testing.T) {
	c := fake(t, "drops-stop", fiveSeconds)
	if _, err := c.Check(); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Stop("devbox"); said(err) != "Unknown tool: workspace_stop" {
		t.Errorf("%v", err)
	}
	if _, err := c.Check(); said(err) != "It isn’t a machine provider: it has no workspace_stop tool." {
		t.Errorf("%v", err)
	}
	if listed, err := c.List(); err != nil || len(listed) != 1 {
		t.Errorf("%v", err)
	}
}

func TestACommandThatIsNotThereCannotBeReached(t *testing.T) {
	command := "no-such-provider-command"
	c, _ := NewConnection(ProviderRecord{ID: "x", Name: "x", Kind: KindStdio, Command: &command}, nil, t.TempDir(), fiveSeconds, "", nil)
	defer c.End()
	if _, err := c.Check(); !strings.HasPrefix(said(err), "It can’t be reached: ") {
		t.Errorf("%v", err)
	}
}

// Streamable http: a session, an answer as an event stream, and a sign-in it wants.

func TestAnHTTPProviderIsReachedWithItsSession(t *testing.T) {
	var mu sync.Mutex
	var auth []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		auth = append(auth, r.Header.Get("Authorization"))
		mu.Unlock()
		if r.Method == http.MethodDelete {
			return
		}
		body, _ := io.ReadAll(r.Body)
		var m map[string]any
		json.Unmarshal(body, &m)
		id, hasID := m["id"]
		if !hasID {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		var result any
		switch m["method"] {
		case "initialize":
			w.Header().Set("Mcp-Session-Id", "s-1")
			result = map[string]any{"protocolVersion": mcpProtocolVersion}
		case "tools/list":
			if r.Header.Get("Mcp-Session-Id") != "s-1" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			result = map[string]any{"tools": []any{map[string]any{"name": "workspaces_list"}, map[string]any{"name": "workspace_start"},
				map[string]any{"name": "workspace_stop"}}}
		case "tools/call":
			result = map[string]any{"structuredContent": map[string]any{"contract": 1, "workspaces": []any{
				map[string]any{"id": "w", "name": "w", "state": "running"}}}}
		}
		data, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "event: message\ndata: %s\n\n", data)
	}))
	defer server.Close()
	url := server.URL
	r := ProviderRecord{ID: "h", Name: "H", Kind: KindHTTP, URL: &url, Headers: map[string]string{"Authorization": "Bearer ${T}"}, SecretNames: []string{"T"}}
	c, err := NewConnection(r, map[string]string{"T": "t0k"}, t.TempDir(), fiveSeconds, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	checked, err := c.Check()
	if err != nil || len(checked.Workspaces) != 1 {
		t.Fatalf("%v %+v", err, checked)
	}
	c.End()
	mu.Lock()
	defer mu.Unlock()
	for _, a := range auth {
		if a != "Bearer t0k" {
			t.Errorf("auth %q", a)
		}
	}
}

func TestAnHTTPProviderThatWantsASignInSaysSo(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(401) }))
	defer server.Close()
	url := server.URL
	c, _ := NewConnection(ProviderRecord{ID: "h", Name: "H", Kind: KindHTTP, URL: &url}, nil, t.TempDir(), fiveSeconds, "", nil)
	if _, err := c.Check(); said(err) != "It wants a sign-in, which providers can’t do yet: give it a token as a secret." {
		t.Errorf("%v", err)
	}
}
