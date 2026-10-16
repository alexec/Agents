package service

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

// Methods is ControlMethods.swift: what the control plane answers itself, and what it does
// with a host's channel 0. What needs ssh, a provider or Slack is refused in the words
// the Swift control plane uses where it cannot do them either.
type Methods struct {
	s *Service
}

var own = map[string]bool{
	"control/status": true, "hosts/list": true, "hosts/startEnroll": true, "hosts/install": true,
	"hosts/checkAgain": true, "hosts/update": true, "hosts/remove": true, "hosts/setRelay": true,
	"hosts/lendSignIn": true, "hosts/detect": true, "hosts/sshHosts": true, "control/setProjectDetection": true,
	"clients/list": true, "clients/startPairing": true, "clients/stopPairing": true, "clients/setGrant": true,
	"clients/forget": true, "clients/connections": true, "clients/forgetSelf": true,
	"devices/list": true, "devices/startPairing": true, "devices/stopPairing": true, "devices/forget": true,
	"hosts/lastHeard": true, "channels/get": true, "channels/set": true,
}

var workspaceMethods = map[string]bool{
	"providers/list": true, "providers/add": true, "providers/update": true, "providers/remove": true,
	"providers/refresh": true, "hosts/link": true, "hosts/unlink": true, "hosts/setWorkspaceOptions": true,
	"hosts/start": true, "hosts/stop": true, "hosts/keep": true, "hosts/listKept": true, "hosts/dropKept": true,
	"hosts/retryKept": true, "providers/options": true, "providers/create": true, "hosts/deleteWorkspace": true,
	"providers/draftStart": true, "providers/draftCancel": true, "providers/draftAnswer": true, "providers/runtimes": true,
}

func (m *Methods) Handles(method string) bool {
	// A bare daemon/ping from today's Remote is the home host's: that is how it knows its Mac is there.
	return method != "daemon/ping" && (own[method] || workspaceMethods[method])
}

var defaultDetection = json.RawMessage(`{"enabled":true,"paths":["~","~/src","~/code","~/projects","~/Developer","~/dev","~/git"]}`)

func ctx() context.Context {
	c, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	time.AfterFunc(31*time.Second, cancel)
	return c
}

func storeFailure(err error) error {
	if store.IsConflict(err) {
		return fail(changedElsewhere, "Someone changed that at the same time, so nothing was changed. Try again.")
	}
	if _, ok := err.(*store.UnavailableError); ok {
		return fail(storeUnavailable, "The control plane can't reach where it keeps its records (%v). Nothing was changed.", err)
	}
	return err
}

func (m *Methods) Handle(method string, params json.RawMessage, caller Caller) (any, error) {
	result, err := m.answer(method, params, caller)
	if err != nil {
		if _, ok := err.(*rpcError); !ok {
			err = storeFailure(err)
		}
	}
	return result, err
}

func param(params json.RawMessage, key string) string {
	var o map[string]any
	json.Unmarshal(params, &o)
	s, _ := o[key].(string)
	return s
}

func (m *Methods) answer(method string, params json.RawMessage, caller Caller) (any, error) {
	s := m.s
	switch method {
	case "control/status":
		settings := s.records.Settings()
		st := map[string]any{"name": settings.Name, "version": Version, "machineID": settings.MachineID,
			"startedAt": records.RefDate(s.started), "port": s.cfg.Port, "awayFromHome": false, "you": caller.Client}
		if settings.HomeHost != nil {
			st["homeHost"] = *settings.HomeHost
		}
		if s.web != nil {
			st["web"] = s.web
		}
		if j := s.thisMacHost(); j != nil {
			st["thisMacHost"] = j
		}
		st["projectDetection"] = defaultDetection
		if settings.ProjectDetection != nil {
			st["projectDetection"] = settings.ProjectDetection
		}
		for _, h := range s.records.Hosts() {
			if h.Relay != nil && *h.Relay {
				st["relayKey"] = h.PublicKey
				st["awayFromHome"] = true
				break
			}
		}
		return st, nil
	case "hosts/list":
		var out []map[string]any
		for _, h := range s.records.Hosts() {
			out = append(out, m.hostRow(h))
		}
		if out == nil {
			out = []map[string]any{}
		}
		return out, nil
	case "clients/list", "devices/list":
		out := []map[string]any{}
		for _, c := range s.records.Clients() {
			out = append(out, c.Wire())
		}
		return out, nil
	case "clients/connections":
		relay := ""
		for _, h := range s.records.Hosts() {
			if h.Relay != nil && *h.Relay {
				relay = h.Name
				break
			}
		}
		out := []map[string]any{}
		for client, relayed := range s.router.Connections() {
			row := map[string]any{"client": client, "relayed": relayed}
			if relayed && relay != "" {
				row["through"] = relay
			}
			out = append(out, row)
		}
		sort.Slice(out, func(i, j int) bool { return out[i]["client"].(string) < out[j]["client"].(string) })
		return out, nil
	case "clients/startPairing":
		return s.codes.Issue(ctx(), false, param(params, "kind") == "browser", lifetime)
	case "devices/startPairing":
		return s.codes.Issue(ctx(), false, false, lifetime)
	case "clients/stopPairing", "devices/stopPairing":
		return map[string]any{}, nil
	case "clients/setGrant":
		return nil, fail(notSupported, "Every paired client may do everything now, so there is no grant to change. Update this window to lose the choice.")
	case "clients/forget", "devices/forget":
		id := param(params, "client")
		if id == "" {
			id = param(params, "id")
		}
		if id == "" {
			return nil, fail(invalidParams, "Which client?")
		}
		return map[string]any{}, m.forget(strings.ToUpper(id), 0)
	case "clients/forgetSelf":
		return map[string]any{}, m.forget(caller.Client, 200*time.Millisecond)
	case "hosts/startEnroll":
		return s.codes.Issue(ctx(), true, false, lifetime)
	case "hosts/install":
		return m.install(params)
	case "hosts/detect", "hosts/sshHosts", "hosts/update", "hosts/checkAgain":
		return nil, fail(notSupported, "This control plane cannot do that yet.")
	case "control/setProjectDetection":
		var req struct {
			Enabled bool     `json:"enabled"`
			Paths   []string `json:"paths"`
		}
		if json.Unmarshal(params, &req) != nil {
			return nil, fail(invalidParams, "Those parameters are not a ProjectDetection.")
		}
		var kept []string
		for _, p := range req.Paths {
			if p = strings.TrimSpace(p); p != "" {
				kept = append(kept, p)
			}
		}
		req.Paths = kept
		raw, _ := json.Marshal(req)
		_, err := s.records.ChangeSettings(ctx(), func(st *records.Settings) { st.ProjectDetection = raw })
		return req, err
	case "hosts/lendSignIn":
		var req struct {
			Host, From, Runtime string
			Allowed             bool
		}
		json.Unmarshal(params, &req)
		rec := s.records.Host(req.Host)
		if rec == nil || s.records.Host(req.From) == nil {
			return nil, fail(noSuchHost, "No such host.")
		}
		if rec.SignInFrom == nil {
			rec.SignInFrom = map[string]string{}
		}
		if req.Allowed {
			rec.SignInFrom[req.Runtime] = req.From
		} else {
			delete(rec.SignInFrom, req.Runtime)
		}
		if len(rec.SignInFrom) == 0 {
			rec.SignInFrom = nil
		}
		return map[string]any{}, s.records.SaveHost(ctx(), *rec)
	case "hosts/setRelay":
		var req struct {
			Host  string
			Relay bool
		}
		json.Unmarshal(params, &req)
		return map[string]any{}, m.setRelay(req.Host, req.Relay)
	case "hosts/remove":
		host := param(params, "host")
		ok, err := s.records.RemoveHost(ctx(), host)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, fail(noSuchHost, "No host is called %s.", host)
		}
		s.router.ForgetHost(host)
		return map[string]any{}, nil
	case "hosts/lastHeard":
		host := param(params, "host")
		if s.records.Host(host) == nil {
			return nil, fail(noSuchHost, "No host is called %s.", host)
		}
		// What each host last listed (#962) is not kept by this spike.
		return map[string]any{"host": host}, nil
	case "channels/get":
		return json.RawMessage(`{"slack":{"enabled":false,"memberID":"","appTokenSet":false,"botTokenSet":false,"status":"off","detail":"Channels need a control plane with one copy, for now.","available":false}}`), nil
	case "channels/set":
		return nil, fail(notSupported, "Channels need a control plane with one copy, for now.")
	}
	if workspaceMethods[method] {
		return nil, fail(providersNeedOneCopy, "Workspace providers need a control plane with one copy, for now.")
	}
	return nil, fail(methodNotFound, "No such method: %s", method)
}

func (m *Methods) forget(id string, delay time.Duration) error {
	if err := m.s.records.Forget(ctx(), id); err != nil {
		return err
	}
	go func() {
		time.Sleep(delay)
		m.s.router.ForgetClient(id)
		m.s.router.BroadcastControl("control/clientChanged", map[string]any{"client": id, "removed": true})
	}()
	return nil
}

func (m *Methods) setRelay(host string, relay bool) error {
	rec := m.s.records.Host(host)
	if rec == nil {
		return fail(noSuchHost, "No host is called %s.", host)
	}
	if rec.Relay == nil {
		return fail(invalidParams, "%s does not relay.", rec.Name)
	}
	if *rec.Relay == relay {
		return nil
	}
	rec.Relay = &relay
	if err := m.s.records.SaveHost(ctx(), *rec); err != nil {
		return err
	}
	m.s.router.SetRelay(host, &relay)
	return nil
}

// hostRow is one hosts/list row, as it stands now.
func (m *Methods) hostRow(h records.HostRecord) map[string]any {
	d := m.s.router.Described(h.ID)
	row := map[string]any{"id": h.ID, "name": h.Name, "platform": h.Platform, "version": h.Version,
		"state": d["state"], "reach": "dialOut"}
	if h.MachineID != nil {
		row["machineID"] = *h.MachineID
	}
	if h.Relay != nil {
		row["relay"] = *h.Relay
	}
	if h.SignInFrom != nil {
		row["signInFrom"] = h.SignInFrom
	}
	return row
}

func (m *Methods) HostSaid(host, method string, params json.RawMessage) (any, error) {
	s := m.s
	switch method {
	case "control/ping", "projects/detected", "attention/need", "host/status":
		// attention/need: no relay host carries notices from this spike (see the report).
		return map[string]any{}, nil
	case "host/hello":
		var hello struct {
			Version   string  `json:"version"`
			Platform  string  `json:"platform"`
			MachineID string  `json:"machineID"`
			Name      *string `json:"name"`
			Relay     *bool   `json:"relay"`
		}
		if json.Unmarshal(params, &hello) != nil {
			return nil, fail(invalidParams, "Those parameters are not a HostHello.")
		}
		known := s.records.Host(host)
		rec := records.HostRecord{ID: host, Name: host}
		if known != nil {
			rec = *known
		}
		rec.Version, rec.Platform = hello.Version, hello.Platform
		mid := hello.MachineID
		rec.MachineID = &mid
		if hello.Name != nil {
			rec.Name = *hello.Name
		}
		if err := s.records.SaveHost(ctx(), rec); err != nil {
			return nil, storeFailure(err)
		}
		// The home host is where a device's plain connection goes: the host on the control
		// plane's own machine, or the first host to join until one on its machine does.
		if hello.Relay == nil || !*hello.Relay {
			settings := s.records.Settings()
			onThisMachine := hello.MachineID == settings.MachineID
			homeIsHere := false
			if settings.HomeHost != nil {
				if h := s.records.Host(*settings.HomeHost); h != nil && h.MachineID != nil {
					homeIsHere = *h.MachineID == settings.MachineID
				}
			}
			if settings.HomeHost == nil || (onThisMachine && *settings.HomeHost != host && !homeIsHere) {
				if _, err := s.records.ChangeSettings(ctx(), func(st *records.Settings) { st.HomeHost = &host }); err != nil {
					return nil, storeFailure(err)
				}
				s.router.SetHomeHost(host)
			}
		}
		s.router.BroadcastControl("control/hostChanged", s.router.Described(host))
		return map[string]any{}, nil
	case "relay/switch":
		var req struct{ Relay bool }
		json.Unmarshal(params, &req)
		return map[string]any{}, m.setRelay(host, req.Relay)
	case "host/workspaces", "host/providerDraft":
		return nil, fail(providersNeedOneCopy, "Workspace providers need a control plane with one copy, for now.")
	case "tunnel/open":
		var req struct{ Runtime, Ref string }
		json.Unmarshal(params, &req)
		rec := s.records.Host(host)
		if rec == nil || rec.SignInFrom[req.Runtime] == "" {
			s.records.Load(ctx())
			rec = s.records.Host(host)
		}
		if rec == nil || rec.SignInFrom[req.Runtime] == "" {
			return nil, fail(notPermitted, "No host lends this host its %s sign-in.", req.Runtime)
		}
		if !s.router.OpenTunnel(host, rec.SignInFrom[req.Runtime], req.Runtime, req.Ref) {
			return nil, fail(hostOffline, "The host that lends this sign-in is offline.")
		}
		return map[string]any{}, nil
	}
	return nil, fail(methodNotFound, "No such method: %s", method)
}

// thisMacHost is the join of the host beside it (#113), from its root's control-join.json,
// when the daemon that wrote it is still running.
func (s *Service) thisMacHost() any {
	if s.cfg.HostRoot == "" {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(s.cfg.HostRoot, "control-join.json"))
	if err != nil {
		return nil
	}
	var f struct {
		PID    int             `json:"pid"`
		Status json.RawMessage `json:"status"`
	}
	if json.Unmarshal(b, &f) != nil || syscall.Kill(f.PID, 0) != nil {
		return nil
	}
	// The file's date is ISO 8601; the wire's is a Double.
	var st map[string]any
	json.Unmarshal(f.Status, &st)
	if at, ok := st["at"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, at); err == nil {
			st["at"] = records.RefDate(t)
		}
	}
	return st
}
