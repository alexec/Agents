package skillcatalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The marketplaces a catalogue sheet can search (Marketplaces): the app's own list, then
// the person's ~/.agents/marketplaces.json, then the destination folder's
// .agents/marketplaces.json. A token names a line in secrets.env, sent as a bearer token.
// off and on are the person's only. A folder's marketplaces start off, and are used once
// the person names them in on: a committed file could otherwise send one of their secrets
// to any host it names.

const SkillsShID = "provided:skills-sh"

// The Agents marketplace (#2155): its id, and the address the built-in file is listed under.
const (
	AgentsMarketplaceID   = "provided:agents"
	AgentsMarketplaceFile = "builtin:agents.json"
)

// RegistryVariable points every provided MCP registry at a walk's fixture server.
const RegistryVariable = "AGENTS_TEST_MCP_REGISTRY_URL"

// Provided is the app's own list, in the order the sheet offers them.
func Provided(env func(string) string) []wire.Marketplace {
	registry := func(live string) string {
		if s := env(RegistryVariable); s != "" {
			return s
		}
		return live
	}
	catalog := "https://skills.sh"
	if s := env(CatalogVariable); s != "" {
		catalog = s
	}
	about := func(s string) *string { return &s }
	return []wire.Marketplace{
		{ID: "provided:github-mcp", Name: "GitHub MCP Registry", Format: wire.MarketplaceFormatMCPRegistry,
			URL: registry("https://api.mcp.github.com"), Origin: wire.MarketplaceOriginProvided,
			About: about("Curated by GitHub, most starred first.")},
		{ID: "provided:official-mcp", Name: "MCP Registry", Format: wire.MarketplaceFormatMCPRegistry,
			URL: registry("https://registry.modelcontextprotocol.io"), Origin: wire.MarketplaceOriginProvided,
			About: about("The open registry: everything published, in its own order.")},
		// The connectors Agents makes (#2155): a file carried inside agentsd (mcpcatalog's agents.json).
		{ID: AgentsMarketplaceID, Name: "Agents", Format: wire.MarketplaceFormatFile, URL: AgentsMarketplaceFile,
			Origin: wire.MarketplaceOriginProvided, About: about("The connectors Agents makes, carried by every host.")},
		{ID: SkillsShID, Name: "skills.sh", Format: wire.MarketplaceFormatSkillsSh, URL: catalog,
			Origin: wire.MarketplaceOriginProvided, About: about("Skills on GitHub, most installed first.")},
		{ID: "provided:anthropic-skills", Name: "Anthropic skills", Format: wire.MarketplaceFormatGithubSkills,
			URL: "anthropics/skills", Origin: wire.MarketplaceOriginProvided, About: about("Anthropic's own skills.")},
	}
}

// KindOf is what a format lists.
func KindOf(f wire.MarketplaceFormat) wire.CatalogKind {
	if f == wire.MarketplaceFormatMCPRegistry || f == wire.MarketplaceFormatFile {
		return wire.CatalogKindMCP
	}
	return wire.CatalogKindSkills
}

// MarketplaceFile is what a marketplaces.json says.
type MarketplaceFile struct {
	Marketplaces []MarketplaceEntry `json:"marketplaces"`
	Off          []string           `json:"off,omitempty"`
	On           []string           `json:"on,omitempty"`
}

type MarketplaceEntry struct {
	Format wire.MarketplaceFormat `json:"format"`
	Name   string                 `json:"name"`
	Token  *string                `json:"token,omitempty"`
	URL    string                 `json:"url"`
}

// UnreadableMarketplaces is a file there that does not read: refused, so nothing is written
// over it.
type UnreadableMarketplaces struct{ Path string }

func (e UnreadableMarketplaces) Error() string {
	return e.Path + " could not be read, so the marketplaces in it are left out and nothing is written to it"
}

func PersonalMarketplaces(home string) string {
	return filepath.Join(home, ".agents", "marketplaces.json")
}
func FolderMarketplaces(folder string) string {
	return filepath.Join(folder, ".agents", "marketplaces.json")
}

// LoadMarketplaces is a missing file as an empty one.
func LoadMarketplaces(path string) (MarketplaceFile, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return MarketplaceFile{}, nil
	}
	var f MarketplaceFile
	if err != nil || json.Unmarshal(b, &f) != nil {
		return MarketplaceFile{}, UnreadableMarketplaces{path}
	}
	return f, nil
}

// SaveMarketplaces writes it sorted and pretty, as Foundation does.
func SaveMarketplaces(f MarketplaceFile, path string) error {
	if f.Marketplaces == nil {
		f.Marketplaces = []MarketplaceEntry{}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(f); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	text := regexp.MustCompile(`(?m)^(\s*"[^"]*"): `).ReplaceAll(buf.Bytes(), []byte("$1 : "))
	return store.WriteAtomically(path, text, 0o644)
}

// ListMarketplaces is every marketplace for a kind (all for nil), provided first, then the
// person's, then the folder's.
func ListMarketplaces(kind *wire.CatalogKind, personal MarketplaceFile, folder *MarketplaceFile,
	secretIsSet func(string) bool, env func(string) string) []wire.Marketplace {
	off, on := set(personal.Off), set(personal.On)
	all := Provided(env)
	for _, e := range personal.Marketplaces {
		all = append(all, fromEntry(e, wire.MarketplaceOriginPersonal, secretIsSet))
	}
	if folder != nil {
		for _, e := range folder.Marketplaces {
			all = append(all, fromEntry(e, wire.MarketplaceOriginFolder, secretIsSet))
		}
	}
	seen := map[string]bool{}
	out := []wire.Marketplace{}
	for _, m := range all {
		if seen[m.ID] || kind != nil && KindOf(m.Format) != *kind {
			continue
		}
		seen[m.ID] = true
		if m.Origin == wire.MarketplaceOriginFolder {
			m.Enabled = on[m.ID]
		} else {
			m.Enabled = !off[m.ID]
		}
		out = append(out, m)
	}
	return out
}

func set(xs []string) map[string]bool {
	out := map[string]bool{}
	for _, x := range xs {
		out[x] = true
	}
	return out
}

func fromEntry(e MarketplaceEntry, origin wire.MarketplaceOrigin, secretIsSet func(string) bool) wire.Marketplace {
	m := wire.Marketplace{ID: MarketplaceID(origin, e.URL), Name: e.Name, Format: e.Format, URL: Normalized(e.URL),
		Token: e.Token, Origin: origin}
	if e.Token != nil {
		m.TokenMissing = !secretIsSet(*e.Token)
	}
	return m
}

// SetEnabled turns one on or off in the person's file.
func SetEnabled(id string, folder bool, enabled bool, f *MarketplaceFile) {
	without := func(xs []string) []string {
		var out []string
		for _, x := range xs {
			if x != id {
				out = append(out, x)
			}
		}
		return out
	}
	if folder {
		f.On = without(f.On)
		if enabled {
			f.On = append(f.On, id)
		}
	} else {
		f.Off = without(f.Off)
		if !enabled {
			f.Off = append(f.Off, id)
		}
	}
}

func MarketplaceID(origin wire.MarketplaceOrigin, u string) string {
	return string(origin) + ":" + Normalized(u)
}

func Normalized(u string) string { return strings.TrimRight(strings.TrimSpace(u), "/") }

var tokenName = regexp.MustCompile(`^[\p{L}_][\p{L}\p{N}_]*$`)

// MarketplaceProblem is why an entry typed on the sheet cannot be added, or "".
func MarketplaceProblem(r wire.MarketplaceAddRequest) string {
	if strings.TrimSpace(r.Name) == "" {
		return "Give it a name."
	}
	u := Normalized(r.URL)
	switch r.Format {
	case wire.MarketplaceFormatGithubSkills:
		if _, _, ok := GitHubSource(u); !ok {
			return "A GitHub repository is owner/repo."
		}
	case wire.MarketplaceFormatFile:
		// A path: absolute, from ~/, or from the folder that holds the marketplaces.json's .agents.
		if u == "" || strings.Contains(u, "://") || strings.HasPrefix(u, "builtin:") {
			return "A file marketplace is a path, such as ~/team/connectors.json."
		}
		if r.Token != nil && *r.Token != "" {
			return "A file marketplace takes no token."
		}
	default:
		p, err := url.Parse(u)
		if err != nil || p.Scheme == "" || p.Host == "" {
			return "The address is a URL, such as https://mcp.example.com."
		}
		scheme, h := strings.ToLower(p.Scheme), p.Hostname()
		if scheme != "https" && !(scheme == "http" && (h == "localhost" || h == "127.0.0.1")) {
			return "The address must be https (http only for localhost)."
		}
	}
	if r.Token != nil && *r.Token != "" && !tokenName.MatchString(*r.Token) {
		return "A token name is letters, digits and _, such as ACME_MCP_TOKEN."
	}
	return ""
}
