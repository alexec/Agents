package mcpcatalog

import (
	"net/url"
	"strings"
	"unicode"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Tools is what this machine can run a package with.
type Tools struct{ Npx, Uvx, Docker bool }

// Runs is the ways a server can run here, and a remote's host when it is not the
// publisher's own.
type Runs struct {
	Available, Unavailable []wire.MCPRunKind
	ForeignHost            *string
}

var runOrder = []wire.MCPRunKind{wire.MCPRunKindRemote, wire.MCPRunKindNpx, wire.MCPRunKindUvx, wire.MCPRunKindDocker}

// AvailableRuns is MCPEntryBuilder.availableRuns, in a stable order.
func AvailableRuns(s Server, tools Tools) Runs {
	avail, unavail := map[wire.MCPRunKind]bool{}, map[wire.MCPRunKind]bool{}
	var foreign *string
	if len(s.Remotes) > 0 {
		avail[wire.MCPRunKindRemote] = true
		if u := s.Remotes[0].URL; u != nil {
			if p, err := url.Parse(*u); err == nil && p.Host != "" && !ownHosts(s)[strings.ToLower(p.Hostname())] {
				h := p.Hostname()
				foreign = &h
			}
		}
	}
	for _, p := range s.Packages {
		kind, has := wire.MCPRunKind(""), false
		switch deref(p.RegistryType) {
		case "npm":
			kind, has = wire.MCPRunKindNpx, tools.Npx
		case "pypi":
			kind, has = wire.MCPRunKindUvx, tools.Uvx
		case "oci":
			kind, has = wire.MCPRunKindDocker, tools.Docker
		default:
			continue
		}
		if has {
			avail[kind] = true
		} else {
			unavail[kind] = true
		}
	}
	r := Runs{ForeignHost: foreign}
	for _, k := range runOrder {
		if avail[k] {
			r.Available = append(r.Available, k)
		}
		if unavail[k] {
			r.Unavailable = append(r.Unavailable, k)
		}
	}
	return r
}

// Built is a server as an mcp.json entry, and what the sheet asks for.
type Built struct {
	NameHere     string
	ChosenRun    wire.MCPRunKind
	CommandOrURL string
	Host         *string
	Entry        skillcatalog.Value
	Variables    []wire.MCPVariable
}

type pair struct{ k, v string }

// Build is MCPEntryBuilder.build: the entry for one way of running the server, with
// ${NAME} where a secret goes.
func Build(s Server, run wire.MCPRunKind, alreadySet func(string) bool) (Built, error) {
	nameHere := slug(ShortName(s.Name))
	if s.Title != nil {
		nameHere = slug(*s.Title)
	}
	mark := func(v wire.MCPVariable) wire.MCPVariable { v.AlreadySet = alreadySet(v.Name); return v }
	vars := []wire.MCPVariable{}
	switch run {
	case wire.MCPRunKindRemote:
		if len(s.Remotes) == 0 || s.Remotes[0].URL == nil {
			return Built{}, NoRunnableWay()
		}
		remote := s.Remotes[0]
		u := *remote.URL
		var hostLabel *string
		if p, err := url.Parse(u); err == nil && p.Host != "" {
			h := p.Hostname()
			label := h + " · not the publisher's"
			if ownHosts(s)[strings.ToLower(h)] {
				label = h + " · the publisher's own"
			}
			hostLabel = &label
		}
		var headers []pair
		for _, h := range remote.Headers {
			if h.Name == nil {
				continue
			}
			value, vs := headerValue(h, s.Name)
			headers = append(headers, pair{*h.Name, value})
			for _, v := range vs {
				vars = append(vars, mark(v))
			}
		}
		kind := "http"
		if deref(remote.Type) == "sse" {
			kind = "sse"
		}
		entry := skillcatalog.Object(skillcatalog.Pair{Key: "type", Value: skillcatalog.String(kind)},
			skillcatalog.Pair{Key: "url", Value: skillcatalog.String(u)})
		if len(headers) > 0 {
			entry.Set("headers", object(headers))
		}
		return Built{NameHere: nameHere, ChosenRun: run, CommandOrURL: u, Host: hostLabel, Entry: entry, Variables: vars}, nil
	case wire.MCPRunKindNpx, wire.MCPRunKindUvx:
		registryType, command := "npm", "npx"
		if run == wire.MCPRunKindUvx {
			registryType, command = "pypi", "uvx"
		}
		p, ok := packageOf(s, registryType)
		if !ok {
			return Built{}, NoRunnableWay()
		}
		version := "latest"
		if p.Version != nil {
			version = *p.Version
		} else if s.Version != nil {
			version = *s.Version
		}
		args := []string{"-y", *p.Identifier + "@" + version}
		if run == wire.MCPRunKindUvx {
			args = []string{*p.Identifier + "==" + version}
		}
		env, vs := envFrom(p, mark)
		return Built{NameHere: nameHere, ChosenRun: run, CommandOrURL: command + " " + strings.Join(args, " "),
			Entry: stdioEntry(command, args, env), Variables: append(vars, vs...)}, nil
	case wire.MCPRunKindDocker:
		p, ok := packageOf(s, "oci")
		if !ok {
			return Built{}, NoRunnableWay()
		}
		args := []string{"run", "-i", "--rm"}
		for _, a := range p.RuntimeArguments {
			if a.Name != nil {
				args = append(args, *a.Name)
			}
			if a.Value != nil {
				filled, vs := expandBraces(*a.Value)
				args = append(args, filled)
				for _, v := range vs {
					vars = append(vars, mark(v))
				}
			}
		}
		args = append(args, *p.Identifier)
		env, vs := envFrom(p, mark)
		return Built{NameHere: nameHere, ChosenRun: run, CommandOrURL: "docker " + strings.Join(args, " "),
			Entry: stdioEntry("docker", args, env), Variables: append(vars, vs...)}, nil
	}
	// Only a server added by hand runs as a command of its own.
	return Built{}, NoRunnableWay()
}

func packageOf(s Server, registryType string) (Package, bool) {
	for _, p := range s.Packages {
		if deref(p.RegistryType) == registryType && p.Identifier != nil {
			return p, true
		}
	}
	return Package{}, false
}

func stdioEntry(command string, args []string, env []pair) skillcatalog.Value {
	list := skillcatalog.Value{Kind: 'a', Items: []skillcatalog.Value{}}
	for _, a := range args {
		list.Items = append(list.Items, skillcatalog.String(a))
	}
	entry := skillcatalog.Object(skillcatalog.Pair{Key: "command", Value: skillcatalog.String(command)},
		skillcatalog.Pair{Key: "args", Value: list})
	if len(env) > 0 {
		entry.Set("env", object(env))
	}
	return entry
}

func object(pairs []pair) skillcatalog.Value {
	o := skillcatalog.Object()
	for _, p := range pairs {
		o.Set(p.k, skillcatalog.String(p.v))
	}
	return o
}

func envFrom(p Package, mark func(wire.MCPVariable) wire.MCPVariable) ([]pair, []wire.MCPVariable) {
	var env []pair
	var vars []wire.MCPVariable
	for _, v := range p.EnvironmentVariables {
		if v.Name == nil {
			continue
		}
		name := *v.Name
		if v.IsSecret != nil && *v.IsSecret {
			env = append(env, pair{name, "${" + name + "}"})
			required := v.IsRequired == nil || *v.IsRequired
			vars = append(vars, mark(wire.MCPVariable{Name: name, Description: deref(v.Description), Kind: wire.MCPVariableKindSecret,
				Required: required}))
			continue
		}
		required := v.IsRequired != nil && *v.IsRequired
		vars = append(vars, wire.MCPVariable{Name: name, Description: deref(v.Description), Kind: wire.MCPVariableKindPlain,
			Required: required, Placeholder: v.DefaultValue})
		if v.DefaultValue != nil {
			env = append(env, pair{name, *v.DefaultValue})
		}
	}
	return env, vars
}

func headerValue(h Header, publisher string) (string, []wire.MCPVariable) {
	if h.Value != nil {
		return expandBraces(*h.Value)
	}
	header := "TOKEN"
	if h.Name != nil {
		header = *h.Name
	}
	name := preferredSecretName(header, publisher, deref(h.Description))
	required := h.IsSecret != nil && *h.IsSecret
	if h.IsRequired != nil {
		required = *h.IsRequired
	}
	v := wire.MCPVariable{Name: name, Description: deref(h.Description), Kind: wire.MCPVariableKindSecret, Required: required}
	if strings.ToLower(header) == "authorization" {
		return "Bearer ${" + name + "}", []wire.MCPVariable{v}
	}
	return "${" + name + "}", []wire.MCPVariable{v}
}

func preferredSecretName(header, publisher, description string) string {
	desc := strings.ToLower(description)
	switch {
	case strings.Contains(publisher, "github") && (strings.Contains(desc, "github") || strings.Contains(desc, "pat") || strings.Contains(desc, "token")):
		return "GITHUB_TOKEN"
	case strings.Contains(publisher, "upstash") || strings.Contains(publisher, "context7"):
		return "CONTEXT7_API_KEY"
	case strings.Contains(desc, "smithery"):
		return "SMITHERY_API_KEY"
	}
	return strings.ReplaceAll(strings.ToUpper(header), "-", "_")
}

// expandBraces turns {token} and Bearer {smithery_api_key} into ${TOKEN} forms.
func expandBraces(text string) (string, []wire.MCPVariable) {
	var out strings.Builder
	var vars []wire.MCPVariable
	for i := 0; i < len(text); {
		if text[i] == '{' {
			if j := strings.IndexByte(text[i+1:], '}'); j >= 0 {
				name := strings.ReplaceAll(strings.ToUpper(text[i+1:i+1+j]), "-", "_")
				out.WriteString("${" + name + "}")
				vars = append(vars, wire.MCPVariable{Name: name, Kind: wire.MCPVariableKindSecret, Required: true})
				i += j + 2
				continue
			}
		}
		out.WriteByte(text[i])
		i++
	}
	return out.String(), vars
}

func slug(title string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(title) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) {
			b.WriteRune(r)
			dash = false
		} else if !dash && b.Len() > 0 {
			b.WriteByte('-')
			dash = true
		}
	}
	s := strings.TrimRight(b.String(), "-")
	if s == "" {
		return "server"
	}
	return s
}
