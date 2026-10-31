// Package mcpcatalog is MCP servers found in a registry and written into mcp.json (060,
// AgentsKit/Catalog/MCP*): the registry's search and detail, turning a server into an
// entry and the variables the sheet asks for, the sidecar that says which entries the app
// added, and splicing one entry into mcp.json without disturbing its hand-written siblings.
package mcpcatalog

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Error is a refusal (DaemonAPI.MCPCatalogError), in Why.
type Error struct{ Why wire.MCPCatalogError }

func (e *Error) Error() string { return Sentence(e.Why) }

func Unreachable(host string) *Error {
	return &Error{wire.MCPCatalogError{Unreachable: &wire.MCPCatalogErrorUnreachable{Host: host}}}
}
func TimedOut(host string) *Error {
	return &Error{wire.MCPCatalogError{TimedOut: &wire.MCPCatalogErrorTimedOut{Host: host}}}
}
func NoPersonalHome() *Error { return &Error{wire.MCPCatalogError{NoPersonalHome: &struct{}{}}} }
func Unmanaged(path string) *Error {
	return &Error{wire.MCPCatalogError{Unmanaged: &wire.MCPCatalogErrorUnmanaged{Path: path}}}
}
func Unreadable(path string) *Error {
	return &Error{wire.MCPCatalogError{McpUnreadable: &wire.MCPCatalogErrorMcpUnreadable{Path: path}}}
}
func MissingSecret(name string) *Error {
	return &Error{wire.MCPCatalogError{MissingSecret: &wire.MCPCatalogErrorMissingSecret{Name: name}}}
}
func StaleDigest() *Error { return &Error{wire.MCPCatalogError{StaleDigest: &struct{}{}}} }
func SecretStillInUse(name string) *Error {
	return &Error{wire.MCPCatalogError{SecretStillInUse: &wire.MCPCatalogErrorSecretStillInUse{Name: name}}}
}
func PreviewExpired() *Error  { return &Error{wire.MCPCatalogError{PreviewExpired: &struct{}{}}} }
func NoRunnableWay() *Error   { return &Error{wire.MCPCatalogError{NoRunnableWay: &struct{}{}}} }
func ReplaceMismatch() *Error { return &Error{wire.MCPCatalogError{ReplaceMismatch: &struct{}{}}} }
func NotAFolder(path string) *Error {
	return &Error{wire.MCPCatalogError{NotAFolder: &wire.MCPCatalogErrorNotAFolder{Path: path}}}
}
func Failed(why string) *Error {
	return &Error{wire.MCPCatalogError{Failed: &wire.MCPCatalogErrorFailed{Value: why}}}
}

// Sentence is a refusal in the sheet's words (MCPCatalogWords).
func Sentence(e wire.MCPCatalogError) string {
	switch {
	case e.Unreachable != nil:
		return "Can't reach " + e.Unreachable.Host + "."
	case e.TimedOut != nil:
		return e.TimedOut.Host + " is slow: it did not answer within a minute. Try again."
	case e.NoPersonalHome != nil:
		return "This copy of the app has no personal ~/.agents."
	case e.Unmanaged != nil:
		return "A server you wrote is already at " + e.Unmanaged.Path + ", so it was left alone."
	case e.McpUnreadable != nil:
		return e.McpUnreadable.Path + " could not be read, so it was not written."
	case e.MissingSecret != nil:
		return e.MissingSecret.Name + " is required."
	case e.StaleDigest != nil:
		return "That server has changed. Open it again."
	case e.SecretStillInUse != nil:
		return e.SecretStillInUse.Name + " is still named by another server."
	case e.PreviewExpired != nil:
		return "That has expired. Open the server, or verify it, again."
	case e.NoRunnableWay != nil:
		return "There is no way to run this server on this Mac."
	case e.ReplaceMismatch != nil:
		return "The server there has changed. Open it again."
	case e.NotAFolder != nil:
		return e.NotAFolder.Path + " is not a folder on this Mac."
	case e.NameTaken != nil:
		return "There is already a server called " + e.NameTaken.Name + " there."
	case e.Invalid != nil:
		return e.Invalid.Value
	case e.Failed != nil:
		return "It could not be added: " + e.Failed.Value + "."
	}
	return "It could not be done."
}

// Registry is an MCP Registry (/v0.1): the official one, GitHub's, or a company's own.
type Registry struct {
	Client *http.Client
	Base   string
	// Token is sent as a bearer, for a registry that is not open.
	Token string
}

const (
	LiveRegistry = "https://registry.modelcontextprotocol.io"
	// The official registry can take half a minute over a search, so a minute it is.
	registryTimeout = 60 * time.Second
)

// Server is a registry's server, the fields the app reads.
type Server struct {
	Name        string  `json:"name"`
	Description *string `json:"description"`
	Title       *string `json:"title"`
	Version     *string `json:"version"`
	Repository  *struct {
		URL *string `json:"url"`
	} `json:"repository"`
	Packages []Package `json:"packages"`
	Remotes  []Remote  `json:"remotes"`
}

type Package struct {
	RegistryType         *string    `json:"registryType"`
	Identifier           *string    `json:"identifier"`
	Version              *string    `json:"version"`
	EnvironmentVariables []EnvVar   `json:"environmentVariables"`
	RuntimeArguments     []Argument `json:"runtimeArguments"`
}

type EnvVar struct {
	Name         *string `json:"name"`
	Description  *string `json:"description"`
	IsRequired   *bool   `json:"isRequired"`
	IsSecret     *bool   `json:"isSecret"`
	DefaultValue *string `json:"defaultValue"`
}

type Argument struct {
	Name  *string `json:"name"`
	Value *string `json:"value"`
}

type Remote struct {
	Type    *string  `json:"type"`
	URL     *string  `json:"url"`
	Headers []Header `json:"headers"`
}

type Header struct {
	Name        *string `json:"name"`
	Description *string `json:"description"`
	IsRequired  *bool   `json:"isRequired"`
	IsSecret    *bool   `json:"isSecret"`
	Value       *string `json:"value"`
}

func (r Registry) base() string {
	if r.Base == "" {
		return LiveRegistry
	}
	return strings.TrimSuffix(r.Base, "/")
}

// Search is the registry's latest version of each server matching query; a query shorter
// than two characters is not sent.
func (r Registry) Search(ctx context.Context, query string, tools Tools) ([]wire.MCPCatalogResult, error) {
	q := strings.TrimSpace(query)
	if utf8.RuneCountInString(q) < 2 {
		return []wire.MCPCatalogResult{}, nil
	}
	b, err := r.get(ctx, r.base()+"/v0.1/servers?search="+url.QueryEscape(q)+"&version=latest")
	if err != nil {
		return nil, err
	}
	var answer struct {
		Servers []struct {
			Server Server `json:"server"`
		} `json:"servers"`
	}
	if json.Unmarshal(b, &answer) != nil {
		return nil, Unreachable(hostOf(r.base()))
	}
	out := []wire.MCPCatalogResult{}
	for _, s := range answer.Servers {
		out = append(out, Result(s.Server, tools))
	}
	return out, nil
}

// Detail is one server's latest version: /v0.1/servers/{name, its slash %2F}/versions/latest.
func (r Registry) Detail(ctx context.Context, name string) (Server, error) {
	var encoded strings.Builder
	for _, c := range []byte(name) {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_' {
			encoded.WriteByte(c)
		} else {
			encoded.WriteString("%" + strings.ToUpper(hexByte(c)))
		}
	}
	b, err := r.get(ctx, r.base()+"/v0.1/servers/"+encoded.String()+"/versions/latest")
	if err != nil {
		return Server{}, err
	}
	var answer struct {
		Server Server `json:"server"`
	}
	if json.Unmarshal(b, &answer) != nil {
		return Server{}, Unreachable(hostOf(r.base()))
	}
	return answer.Server, nil
}

func hexByte(c byte) string {
	const digits = "0123456789abcdef"
	return string([]byte{digits[c>>4], digits[c&15]})
}

func (r Registry) get(ctx context.Context, u string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, registryTimeout)
	defer cancel()
	host := hostOf(u)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, Unreachable(host)
	}
	req.Header.Set("User-Agent", "agents-app")
	if r.Token != "" {
		req.Header.Set("Authorization", "Bearer "+r.Token)
	}
	client := r.Client
	if client == nil {
		client = http.DefaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, TimedOut(host)
		}
		return nil, Unreachable(host)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, Unreachable(host)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, Unreachable(host)
	}
	return b, nil
}

func hostOf(u string) string {
	if p, err := url.Parse(u); err == nil && p.Host != "" {
		return p.Hostname()
	}
	return "registry"
}

// Result is a registry server as a result row.
func Result(s Server, tools Tools) wire.MCPCatalogResult {
	pub := Publisher(s.Name)
	runs := AvailableRuns(s, tools)
	title := ShortName(s.Name)
	if s.Title != nil {
		title = *s.Title
	}
	r := wire.MCPCatalogResult{ID: s.Name, Title: title, Description: deref(s.Description), Version: deref(s.Version),
		Publisher: pub, Known: pub.Known, Runs: runs.Available, RemoteHost: runs.ForeignHost}
	if r.Runs == nil {
		r.Runs = []wire.MCPRunKind{}
	}
	return r
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// Publisher is the label and known mark a registry name gives (MCPPublisher).
func Publisher(registryName string) wire.MCPPublisherInfo {
	ns := Namespace(registryName)
	if org, ok := strings.CutPrefix(ns, "io.github."); ok {
		return wire.MCPPublisherInfo{Label: org + " on GitHub", Namespace: ns, Known: skillcatalog.KnownOwner(org)}
	}
	parts := strings.Split(ns, ".")
	if len(parts) >= 2 {
		domain := strings.Join(parts[1:], ".")
		known := skillcatalog.KnownOwner(parts[1]) || domain == "github.com" || domain == "modelcontextprotocol.io" ||
			skillcatalog.KnownOwner(domain)
		return wire.MCPPublisherInfo{Label: domain, Namespace: ns, Known: known}
	}
	return wire.MCPPublisherInfo{Label: ns, Namespace: ns}
}

func Namespace(name string) string {
	if i := strings.Index(name, "/"); i >= 0 {
		return name[:i]
	}
	return name
}

func ShortName(name string) string {
	if i := strings.Index(name, "/"); i >= 0 {
		return name[i+1:]
	}
	return name
}

// ownHosts is the hosts that count as the publisher's own, for a remote's address.
func ownHosts(s Server) map[string]bool {
	hosts := map[string]bool{}
	ns := Namespace(s.Name)
	if strings.HasPrefix(ns, "io.github.") {
		for _, h := range []string{"github.com", "api.github.com", "api.githubcopilot.com", "raw.githubusercontent.com"} {
			hosts[h] = true
		}
	}
	if parts := strings.Split(ns, "."); len(parts) >= 2 {
		hosts[strings.Join(parts[1:], ".")] = true
	}
	if s.Repository != nil && s.Repository.URL != nil {
		if p, err := url.Parse(*s.Repository.URL); err == nil && p.Host != "" {
			hosts[strings.ToLower(p.Hostname())] = true
		}
	}
	return hosts
}
