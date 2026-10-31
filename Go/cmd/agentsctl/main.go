// agentsctl is a client of a control plane, as the window is one, for driving hosts in a
// walk without the screen (#1125's spike, kept for #1136's proofs). Not shipped.
//
//	agentsctl pair [-kind iPhone] '<client code>'     keeps ~/.agents-go/ctl.json
//	agentsctl hosts                                   control/status's hosts
//	agentsctl call [-host H] METHOD ['{json}']        one request; prints the result
//	agentsctl watch [-host H]                         prints notifications
//	agentsctl lend -host H [-from mac]                lends -from's Claude sign-in to H (Lending.swift by hand)
//	agentsctl turn -host H -runtime claude -cwd PATH [-allow] 'prompt'
//	                                                  starts an agent, follows it to its end, prints it
//	agentsctl device -host H -token T                 a device's stand-in (#1507): gives its push
//	                                                  token, says it may be notified, stays
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

func file() string {
	if f := os.Getenv("AGENTSCTL"); f != "" {
		return f
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".agents-go", "ctl.json")
}

func die(f string, a ...any) {
	fmt.Fprintf(os.Stderr, f+"\n", a...)
	os.Exit(1)
}

func session(ctx context.Context) *controllink.Session {
	b, err := os.ReadFile(file())
	if err != nil {
		die("not paired: agentsctl pair '<client code>' (%v)", err)
	}
	var m controllink.ClientMembership
	json.Unmarshal(b, &m)
	s, err := controllink.DialClient(ctx, &m)
	if err != nil {
		die("dial: %v", err)
	}
	return s
}

func main() {
	if len(os.Args) < 2 {
		die("usage: agentsctl pair|hosts|call|watch|lend|turn|device …")
	}
	ctx := context.Background()
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	host := fs.String("host", "", "a host id; empty for the control plane")
	from := fs.String("from", "mac", "the host that lends")
	rt := fs.String("runtime", "claude", "the runtime")
	cwd := fs.String("cwd", "", "the agent's folder on the host")
	allow := fs.Bool("allow", false, "answer every permission card with its first allow option, and every form with its first choices")
	wait := fs.Int("wait", 300, "seconds to follow a turn")
	kind := fs.String("kind", "mac", "pair as this kind of client: mac, iPhone or iPad")
	token := fs.String("token", "", "a push token, for device")
	fs.Parse(args)
	rest := fs.Args()
	switch cmd {
	case "pair":
		if len(rest) != 1 {
			die("agentsctl pair '<client code>'")
		}
		code, err := controllink.ParseCode(rest[0])
		if err != nil {
			die("%v", err)
		}
		m, err := controllink.PairClientAs(ctx, code, "agentsctl", *kind)
		if err != nil {
			die("pair: %v", err)
		}
		b, _ := json.MarshalIndent(m, "", "  ")
		os.MkdirAll(filepath.Dir(file()), 0o700)
		os.WriteFile(file(), b, 0o600)
		fmt.Println("paired as", m.Client)
	case "hosts":
		s := session(ctx)
		r, err := s.Call(ctx, "", "machines/list", nil)
		out(r, err)
	case "call":
		if len(rest) < 1 {
			die("agentsctl call [-host H] METHOD [json]")
		}
		var params any
		if len(rest) > 1 {
			params = json.RawMessage(rest[1])
		}
		s := session(ctx)
		r, err := s.Call(ctx, *host, rest[0], params)
		out(r, err)
	case "watch":
		s := session(ctx)
		// A client hears a host only once it has a channel there: open one.
		if *host != "" {
			s.Call(ctx, *host, "daemon/ping", nil)
		}
		for n := range s.Notes {
			if *host == "" || n.Host == *host {
				fmt.Printf("%s %s %s\n", n.Host, n.Method, n.Params)
			}
		}
	case "device":
		if *host == "" || *token == "" {
			die("agentsctl device -host H -token T")
		}
		s := session(ctx)
		out(s.Call(ctx, "", "clients/setPushToken", map[string]string{"token": *token, "environment": "development"}))
		// Presence goes to a host; it says this device may be notified and is not in use.
		out(s.Call(ctx, *host, "presence/report", map[string]any{"active": false, "mayNotify": true}))
		fmt.Println("a device, with its push token; until stopped")
		for range s.Notes {
		}
	case "lend":
		s := session(ctx)
		lend(ctx, s, *host, *from, *rt)
	case "turn":
		if len(rest) != 1 || *host == "" || *cwd == "" {
			die("agentsctl turn -host H -runtime R -cwd PATH 'prompt'")
		}
		s := session(ctx)
		turn(ctx, s, *host, *rt, *cwd, rest[0], *allow, time.Duration(*wait)*time.Second, *from)
	default:
		die("unknown command %s", cmd)
	}
}

func out(r json.RawMessage, err error) {
	if err != nil {
		die("%v", err)
	}
	var v any
	json.Unmarshal(r, &v)
	b, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(b))
}

// lend is what the window does on -32036 (Lending.swift): the control plane lets the
// lender lend, the lender grants a stand-in and its CA, the borrower is offered them.
func lend(ctx context.Context, s *controllink.Session, host, from, runtime string) {
	if _, err := s.Call(ctx, "", "machines/lendSignIn", map[string]any{"host": host, "from": from, "runtime": runtime, "allowed": true}); err != nil {
		die("machines/lendSignIn: %v", err)
	}
	g, err := s.Call(ctx, from, "relay/grant", map[string]any{"runtime": runtime})
	if err != nil {
		die("relay/grant on %s: %v", from, err)
	}
	var grant struct {
		CACertificate string `json:"caCertificate"`
		StandIn       string `json:"standIn"`
	}
	json.Unmarshal(g, &grant)
	if _, err := s.Call(ctx, host, "relay/offer", map[string]any{"runtime": runtime, "socketPath": "tunnel",
		"caCertificate": grant.CACertificate, "standIn": grant.StandIn}); err != nil {
		die("relay/offer on %s: %v", host, err)
	}
	fmt.Printf("%s lends %s's sign-in to %s\n", from, runtime, host)
}

func turn(ctx context.Context, s *controllink.Session, host, rt, cwd, prompt string, allow bool, wait time.Duration, from string) {
	folder := "file://" + strings.TrimSuffix(cwd, "/") + "/"
	if _, err := s.Call(ctx, host, "folders/add", map[string]any{"folder": folder}); err != nil {
		fmt.Fprintf(os.Stderr, "folders/add: %v\n", err)
	}
	start := map[string]any{"runtimeID": rt, "cwd": folder, "prompt": prompt, "attachments": []any{},
		"startOptions": map[string]any{"values": map[string]any{}, "extraArguments": []any{}}}
	r, err := s.Call(ctx, host, "agents/start", start)
	if err != nil && strings.Contains(err.Error(), "-32036") {
		fmt.Println("the host wants a sign-in (-32036); lending it, as the window does")
		lend(ctx, s, host, from, rt)
		r, err = s.Call(ctx, host, "agents/start", start)
	}
	if err != nil {
		die("agents/start: %v", err)
	}
	var id string
	json.Unmarshal(r, &id)
	fmt.Println("agent", id)
	deadline := time.After(wait)
	for {
		select {
		case n, ok := <-s.Notes:
			if !ok {
				die("the control plane went")
			}
			if n.Host != host {
				continue
			}
			switch n.Method {
			case "agent/entry":
				var e struct {
					AgentID string `json:"agentID"`
					Entry   struct {
						Kind map[string]json.RawMessage `json:"kind"`
					} `json:"entry"`
				}
				json.Unmarshal(n.Params, &e)
				if !strings.EqualFold(e.AgentID, id) {
					continue
				}
				for k, v := range e.Entry.Kind {
					switch k {
					case "agentMessage":
						var m struct{ Text string }
						json.Unmarshal(v, &m)
						fmt.Print(m.Text)
					default:
						t := string(v)
						if len(t) > 160 {
							t = t[:160] + "…"
						}
						fmt.Printf("\n[%s] %s\n", k, t)
					}
				}
			case "agent/permission":
				var p struct {
					AgentID string `json:"agentID"`
					Request *struct {
						ID      string `json:"id"`
						Options []struct {
							OptionID string `json:"optionID"`
							Kind     string `json:"kind"`
						} `json:"options"`
					} `json:"request"`
				}
				json.Unmarshal(n.Params, &p)
				if p.Request == nil || !strings.EqualFold(p.AgentID, id) {
					continue
				}
				if !allow {
					fmt.Printf("\n[card] waiting for an answer in the window (permission %s)\n", p.Request.ID)
					continue
				}
				for _, o := range p.Request.Options {
					if strings.HasPrefix(o.Kind, "allow") {
						fmt.Printf("\n[card] answering %s\n", o.OptionID)
						if _, err := s.Call(ctx, host, "permissions/answer", map[string]any{"permissionID": p.Request.ID, "optionID": o.OptionID}); err != nil {
							fmt.Fprintf(os.Stderr, "permissions/answer: %v\n", err)
						}
						break
					}
				}
			case "agent/elicitation":
				var f struct {
					AgentID string                   `json:"agentID"`
					Request *wire.ElicitationRequest `json:"request"`
				}
				json.Unmarshal(n.Params, &f)
				if f.Request == nil || !strings.EqualFold(f.AgentID, id) {
					continue
				}
				b, _ := json.Marshal(f.Request.Mode)
				fmt.Printf("\n[form] %s\n", b)
				if !allow || f.Request.Mode.Form == nil {
					fmt.Printf("[form] waiting for an answer in the window (form %s)\n", f.Request.ID)
					continue
				}
				// The first choice of each question; yes to a yes or no.
				content := map[string]any{}
				for _, p := range f.Request.Mode.Form.Value.Properties {
					switch k := p.Kind; {
					case k.String != nil && len(k.String.Choices) > 0:
						content[p.Name] = k.String.Choices[0].Value
					case k.MultiSelect != nil && len(k.MultiSelect.Items) > 0:
						content[p.Name] = []string{k.MultiSelect.Items[0].Value}
					case k.Boolean != nil:
						content[p.Name] = true
					case p.IsRequired:
						content[p.Name] = "yes"
					}
				}
				fmt.Printf("[form] answering %v\n", content)
				if _, err := s.Call(ctx, host, "elicitations/answer", map[string]any{"requestID": f.Request.ID, "action": "accept",
					"content": content}); err != nil {
					fmt.Fprintf(os.Stderr, "elicitations/answer: %v\n", err)
				}
			case "agent/changed":
				var a struct {
					ID          string          `json:"id"`
					State       string          `json:"state"`
					EndedReason string          `json:"endedReason"`
					Report      json.RawMessage `json:"report"`
				}
				json.Unmarshal(n.Params, &a)
				if strings.EqualFold(a.ID, id) && (a.State == "finished" || a.State == "stopped") {
					fmt.Printf("\n== %s (%s) %s\n", a.State, a.EndedReason, a.Report)
					return
				}
			}
		case <-deadline:
			die("\nstill going after %s", wait)
		}
	}
}
