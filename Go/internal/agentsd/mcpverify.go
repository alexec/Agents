package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// A server typed on the sheet (#305): connected to before anything is written, then written
// exactly as it answered. Only its name and the outcome are logged, never its command,
// arguments, env, headers or URL.

func (d *Daemon) registerMCPVerify() {
	On(d, wire.CallMCPVerify, func(ctx context.Context, c *Client, r wire.MCPVerifyRequest) (wire.MCPVerifyAnswer, error) {
		return d.mcpVerify(ctx, r), nil
	})
	On(d, wire.CallMCPAddByHand, func(ctx context.Context, c *Client, r wire.MCPAddByHandRequest) (wire.MCPAddAnswer, error) {
		return d.mcpAddByHand(r)
	})
}

// mcpVerifyTimeout is how long Verify waits for a server to answer.
var mcpVerifyTimeout = 20 * time.Second

// handEntry is a typed server as the entry that would be written (${NAME} where a secret
// goes), the server Verify connects to with every ${NAME} filled, and the values typed, to
// write to secrets.env on Add (MCPHandEntry).
type handEntry struct {
	name       string
	entry      skillcatalog.Value
	filled     sdk.McpServer
	newSecrets map[string]string
	run        wire.MCPRunKind
}

var (
	handName     = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$`)
	variableName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	headerName   = regexp.MustCompile("^[A-Za-z0-9!#$%&'*+.^_`|~-]+$")
)

func invalid(why string) error {
	return &mcpcatalog.Error{Why: wire.MCPCatalogError{Invalid: &wire.MCPCatalogErrorInvalid{Value: why}}}
}

// defaultSecretName is the name a secret gets when none is typed: the variable's own, or
// for a header, the server's and the header's.
func defaultSecretName(server, value string, header bool) string {
	raw := value
	if header {
		raw = server + "_" + value
	}
	var b strings.Builder
	for _, r := range strings.ToUpper(raw) {
		if r < 0x80 && (r >= 'A' && r <= 'Z' || r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	name := b.String()
	if name != "" && name[0] >= '0' && name[0] <= '9' {
		name = "_" + name
	}
	return name
}

func buildHandEntry(hand wire.MCPHandServer, secrets skillcatalog.Secrets) (handEntry, error) {
	name := strings.TrimSpace(hand.Name)
	if !handName.MatchString(name) {
		return handEntry{}, invalid("A name is letters, digits, dots, dashes and underscores, starting with a letter or digit.")
	}
	h := handEntry{name: name, newSecrets: map[string]string{}}
	held := func(v wire.MCPHandValue, header bool) (string, error) {
		if !v.Secret {
			return v.Value, nil
		}
		secretName := ""
		if v.SecretName != nil {
			secretName = strings.TrimSpace(*v.SecretName)
		}
		if secretName == "" {
			secretName = defaultSecretName(name, v.Name, header)
		}
		if !variableName.MatchString(secretName) {
			return "", invalid("A secret's name is letters, digits and underscores: " + secretName + " is not.")
		}
		if v.Value != "" {
			if other, ok := h.newSecrets[secretName]; ok && other != v.Value {
				return "", invalid(secretName + " is given two different values.")
			}
			h.newSecrets[secretName] = v.Value
		} else if !secrets.IsSet(secretName) {
			return "", mcpcatalog.MissingSecret(secretName)
		}
		return "${" + secretName + "}", nil
	}
	type kv struct{ k, v string }
	var pairs []kv
	switch hand.Kind {
	case wire.MCPHandServerKindCommand:
		command := strings.TrimSpace(hand.Command)
		if command == "" {
			return handEntry{}, invalid("A local server needs a command.")
		}
		for _, v := range hand.Env {
			if v.Name == "" && v.Value == "" {
				continue
			}
			key := strings.TrimSpace(v.Name)
			if !variableName.MatchString(key) {
				which := key + " is not"
				if key == "" {
					which = "one has none"
				}
				return handEntry{}, invalid("A variable's name is letters, digits and underscores: " + which + ".")
			}
			for _, p := range pairs {
				if p.k == key {
					return handEntry{}, invalid(key + " is set twice.")
				}
			}
			value, err := held(v, false)
			if err != nil {
				return handEntry{}, err
			}
			pairs = append(pairs, kv{key, value})
		}
		args := hand.Args
		if args == nil {
			args = []string{}
		}
		list := skillcatalog.Value{Kind: 'a', Items: []skillcatalog.Value{}}
		for _, a := range args {
			list.Items = append(list.Items, skillcatalog.String(a))
		}
		h.entry = skillcatalog.Object(skillcatalog.Pair{Key: "command", Value: skillcatalog.String(command)},
			skillcatalog.Pair{Key: "args", Value: list})
		env := []sdk.EnvVariable{}
		if len(pairs) > 0 {
			o := skillcatalog.Object()
			for _, p := range pairs {
				o.Set(p.k, skillcatalog.String(p.v))
				env = append(env, sdk.EnvVariable{Name: p.k, Value: p.v})
			}
			h.entry.Set("env", o)
		}
		h.filled = sdk.McpServer{Stdio: &sdk.McpServerStdio{Name: name, Command: command, Args: args, Env: env}}
		h.run = wire.MCPRunKindCommand
	case wire.MCPHandServerKindURL:
		u := strings.TrimSpace(hand.URL)
		p, err := url.Parse(u)
		if err != nil || (strings.ToLower(p.Scheme) != "http" && strings.ToLower(p.Scheme) != "https") || p.Host == "" {
			return handEntry{}, invalid("A remote server's URL starts with https:// (or http://).")
		}
		for _, v := range hand.Headers {
			if v.Name == "" && v.Value == "" {
				continue
			}
			key := strings.TrimSpace(v.Name)
			if !headerName.MatchString(key) {
				which := key + " is not"
				if key == "" {
					which = "one has none"
				}
				return handEntry{}, invalid("A header's name is one word: " + which + ".")
			}
			for _, p := range pairs {
				if strings.EqualFold(p.k, key) {
					return handEntry{}, invalid(key + " is set twice.")
				}
			}
			value, err := held(v, true)
			if err != nil {
				return handEntry{}, err
			}
			pairs = append(pairs, kv{key, value})
		}
		h.entry = skillcatalog.Object(skillcatalog.Pair{Key: "type", Value: skillcatalog.String("http")},
			skillcatalog.Pair{Key: "url", Value: skillcatalog.String(u)})
		headers := []sdk.HttpHeader{}
		if len(pairs) > 0 {
			o := skillcatalog.Object()
			for _, p := range pairs {
				o.Set(p.k, skillcatalog.String(p.v))
				headers = append(headers, sdk.HttpHeader{Name: p.k, Value: p.v})
			}
			h.entry.Set("headers", o)
		}
		h.filled = sdk.McpServer{Http: &sdk.McpServerHttpInline{Name: name, Type: "http", Url: u, Headers: headers}}
		h.run = wire.MCPRunKindRemote
	default:
		return handEntry{}, invalid("A server is a command or a URL.")
	}
	// A plain value may name a secret already set, as ${NAME}: every one has to be.
	overlay := map[string]string{}
	for k, v := range h.newSecrets {
		overlay[k] = v
	}
	value := func(n string) (string, bool) {
		if v, ok := overlay[n]; ok {
			return v, true
		}
		return secrets.Value(n)
	}
	var missing []string
	fillIn := func(text string) string {
		return secretRefName.ReplaceAllStringFunc(text, func(m string) string {
			n := m[2 : len(m)-1]
			if v, ok := value(n); ok {
				return v
			}
			missing = append(missing, n)
			return m
		})
	}
	switch {
	case h.filled.Stdio != nil:
		s := *h.filled.Stdio
		s.Command = fillIn(s.Command)
		args := make([]string, len(s.Args))
		for i, a := range s.Args {
			args[i] = fillIn(a)
		}
		env := make([]sdk.EnvVariable, len(s.Env))
		for i, e := range s.Env {
			env[i] = sdk.EnvVariable{Name: e.Name, Value: fillIn(e.Value)}
		}
		s.Args, s.Env = args, env
		h.filled = sdk.McpServer{Stdio: &s}
	case h.filled.Http != nil:
		s := *h.filled.Http
		s.Url = fillIn(s.Url)
		headers := make([]sdk.HttpHeader, len(s.Headers))
		for i, x := range s.Headers {
			headers[i] = sdk.HttpHeader{Name: x.Name, Value: fillIn(x.Value)}
		}
		s.Headers = headers
		h.filled = sdk.McpServer{Http: &s}
	}
	if len(missing) > 0 {
		return handEntry{}, mcpcatalog.MissingSecret(missing[0])
	}
	return h, nil
}

// verifyMCP connects as an agent would, and says what the server calls itself and its tools.
func verifyMCP(ctx context.Context, s sdk.McpServer, cwd string, timeout time.Duration) (name, version *string, tools []string, err error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var c mcpConn
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return nil, nil, nil, err
		}
		c = sc
	case s.Http != nil:
		c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers}
	default:
		return nil, nil, nil, &mcpCheckFailure{kind: "notMCP"}
	}
	defer c.end()
	timedOut := func(err error) error {
		if ctx.Err() != nil {
			return &mcpCheckFailure{kind: "timedOut"}
		}
		return err
	}
	raw, err := c.call(ctx, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	if err != nil {
		return nil, nil, nil, timedOut(err)
	}
	var info struct {
		ServerInfo struct {
			Name    *string `json:"name"`
			Version *string `json:"version"`
		} `json:"serverInfo"`
	}
	json.Unmarshal(raw, &info)
	if err := c.notify(ctx, "notifications/initialized"); err != nil {
		return nil, nil, nil, timedOut(err)
	}
	tools = []string{}
	cursor := ""
	for id := 2; ; id++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(ctx, id, "tools/list", params)
		if err != nil {
			return nil, nil, nil, timedOut(err)
		}
		var page struct {
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
			NextCursor string `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &page) != nil {
			return nil, nil, nil, &mcpCheckFailure{kind: "notMCP"}
		}
		for _, t := range page.Tools {
			tools = append(tools, t.Name)
		}
		if page.NextCursor == "" || id > 50 {
			return info.ServerInfo.Name, info.ServerInfo.Version, tools, nil
		}
		cursor = page.NextCursor
	}
}

// mcpVerified is a server that answered Verify, until added or for half an hour. It holds
// the secret values typed on the sheet, never written anywhere but secrets.env.
type mcpVerified struct {
	destination wire.SkillDestination
	built       handEntry
	until       time.Time
}

var mcpVerifiedStore = struct {
	sync.Mutex
	m map[wire.UUID]mcpVerified
}{m: map[wire.UUID]mcpVerified{}}

func (d *Daemon) mcpVerify(ctx context.Context, r wire.MCPVerifyRequest) wire.MCPVerifyAnswer {
	refuse := func(err error) wire.MCPVerifyAnswer {
		log.Printf("mcp: verify %s refused", r.Server.Name)
		why := mcpWhy(err)
		return wire.MCPVerifyAnswer{Error: &why}
	}
	home := d.personalHome()
	if home == "" {
		return refuse(mcpcatalog.NoPersonalHome())
	}
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return refuse(err)
	}
	built, err := buildHandEntry(r.Server, skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)))
	if err != nil {
		return refuse(err)
	}
	path, err := d.mcpFile(r.Destination)
	if err != nil {
		return refuse(err)
	}
	if _, taken, err := mcpcatalog.Entry(path, built.name); err != nil {
		return refuse(mcpcatalog.Unreadable(path))
	} else if taken {
		return refuse(&mcpcatalog.Error{Why: wire.MCPCatalogError{NameTaken: &wire.MCPCatalogErrorNameTaken{Name: built.name}}})
	}
	cwd := home
	if r.Destination.Kind == wire.SkillDestinationKindFolder {
		cwd = *r.Destination.Folder
	}
	server := built.filled
	ownAuthorization := true
	if server.Http != nil {
		ownAuthorization = false
		for _, h := range server.Http.Headers {
			if strings.EqualFold(h.Name, "Authorization") {
				ownAuthorization = true
			}
		}
	}
	entry := map[string]wire.JSONValue{}
	for _, p := range built.entry.Pairs {
		entry[p.Key] = wire.JSONValue(p.Value.Stringified())
	}
	// Signed in to already: verified as an agent will reach it, with its bearer.
	if !ownAuthorization {
		if b := d.signIn().signIns.BearerFor(ctx, server.Http.Url, built.name); b.Kind == "token" {
			h := *server.Http
			h.Headers = append(append([]sdk.HttpHeader{}, h.Headers...), sdk.HttpHeader{Name: "Authorization", Value: "Bearer " + b.Token})
			server = sdk.McpServer{Http: &h}
		}
	}
	name, version, tools, err := verifyMCP(ctx, server, cwd, mcpVerifyTimeout)
	var outcome wire.MCPVerifyOutcome
	if err != nil {
		failure := mcpFailureOf(err)
		switch {
		case failure.kind == "authRequired" && ownAuthorization:
			outcome.Failed = &wire.MCPVerifyOutcomeFailed{Value: "It refused the Authorization header it was sent (HTTP 401)."}
		case failure.kind == "authRequired":
			_, metadata := probeSignIn(ctx, built.filled.Http.Url, built.filled.Http.Headers, mcpSignInProbeTimeout)
			d.signIn().signIns.MarkNeedsSignIn(built.filled.Http.Url, built.name, metadata)
			outcome.AuthRequired = &wire.MCPVerifyOutcomeAuthRequired{}
			if metadata != "" {
				outcome.AuthRequired.ResourceMetadata = &metadata
			}
		default:
			outcome.Failed = &wire.MCPVerifyOutcomeFailed{Value: failure.sentence(mcpVerifyTimeout)}
		}
		log.Printf("mcp: verify %s → no answer", built.name)
		return wire.MCPVerifyAnswer{Outcome: &outcome, Entry: entry}
	}
	outcome.Answered = &wire.MCPVerifyOutcomeAnswered{ServerName: name, Version: version, Tools: tools}
	id := store.NewUUID()
	mcpVerifiedStore.Lock()
	for k, v := range mcpVerifiedStore.m {
		if time.Now().After(v.until) {
			delete(mcpVerifiedStore.m, k)
		}
	}
	mcpVerifiedStore.m[id] = mcpVerified{destination: r.Destination, built: built, until: time.Now().Add(30 * time.Minute)}
	mcpVerifiedStore.Unlock()
	log.Printf("mcp: verify %s → answered, %d tool(s)", built.name, len(tools))
	return wire.MCPVerifyAnswer{VerifyID: &id, Outcome: &outcome, Entry: entry}
}

func sameDestination(a, b wire.SkillDestination) bool {
	return a.Kind == b.Kind && (a.Folder == nil) == (b.Folder == nil) && (a.Folder == nil || *a.Folder == *b.Folder)
}

// mcpAddByHand writes a server that answered Verify, exactly as it was verified: its
// secrets to secrets.env first, the name still free.
func (d *Daemon) mcpAddByHand(r wire.MCPAddByHandRequest) (wire.MCPAddAnswer, error) {
	if err := d.customServerRefusal(); err != nil {
		return wire.MCPAddAnswer{}, err
	}
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return wire.MCPAddAnswer{}, mcpRefusal(err)
	}
	mcpVerifiedStore.Lock()
	v, ok := mcpVerifiedStore.m[r.VerifyID]
	delete(mcpVerifiedStore.m, r.VerifyID)
	mcpVerifiedStore.Unlock()
	if !ok || time.Now().After(v.until) || !sameDestination(v.destination, r.Destination) {
		return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.PreviewExpired())
	}
	home := d.personalHome()
	if home == "" {
		return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.NoPersonalHome())
	}
	path, err := d.mcpFile(r.Destination)
	if err != nil {
		return wire.MCPAddAnswer{}, mcpRefusal(err)
	}
	name := v.built.name
	if _, taken, err := mcpcatalog.Entry(path, name); err != nil {
		return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.Unreadable(path))
	} else if taken {
		return wire.MCPAddAnswer{}, mcpRefusal(&mcpcatalog.Error{Why: wire.MCPCatalogError{NameTaken: &wire.MCPCatalogErrorNameTaken{Name: name}}})
	}
	if len(v.built.newSecrets) > 0 {
		secretsPath := skillcatalog.SecretsPath(home)
		env, err := skillcatalog.LoadSecretsForChange(secretsPath)
		if err != nil {
			return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.Failed(err.Error()))
		}
		keys := make([]string, 0, len(v.built.newSecrets))
		for k := range v.built.newSecrets {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			env.Set(k, v.built.newSecrets[k])
		}
		if err := env.Save(secretsPath); err != nil {
			return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.Failed("secrets.env could not be written"))
		}
	}
	if err := mcpcatalog.Upsert(path, name, v.built.entry); err != nil {
		return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.Unreadable(path))
	}
	addedAt := nowFunc()
	byHand := true
	side := mcpcatalog.LoadSidecar(d.mcpSidecarPath())
	side.Servers[mcpcatalog.Key(r.Destination, name)] = mcpcatalog.Record{Run: string(v.built.run), AddedAt: addedAt, ByHand: &byHand}
	side.Save(d.mcpSidecarPath())
	if r.Destination.Kind == wire.SkillDestinationKindFolder {
		d.recordMCPApproval(*r.Destination.Folder, name, json.RawMessage(v.built.entry.Stringified()))
	}
	log.Printf("mcp: add %s by hand", name)
	d.mcpChanged()
	return wire.MCPAddAnswer{Server: &wire.ManagedMCPServer{Name: name, Run: v.built.run, AddedAt: wire.DateOf(addedAt),
		Destination: r.Destination, ByHand: &byHand}}, nil
}
