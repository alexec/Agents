package controlplane

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// Codes is ControlCodes: pairing and enrolment codes (data-model.md "Code"), stored by
// id with nothing secret, used once at any copy.
type Codes struct {
	Store   store.Store
	Private []byte
	Public  []byte
	// The control plane's keys now, after any rotation (#997); nil uses Private and Public.
	Keys func() (private, public []byte)
	URL  string
	Pin  string
	Name string
}

func (c *Codes) keys() (private, public []byte) {
	if c.Keys != nil {
		return c.Keys()
	}
	return c.Private, c.Public
}

// storedCode is ControlCodes.Stored.
type storedCode struct {
	Purpose string `json:"purpose"`
	// Made for a browser (071 R2): good only through a page, the loopback listener's or the
	// page on the control plane's own domain (#1459).
	Browser *bool `json:"browser,omitempty"`
	// The person whose client or machine uses it (#994); none is the local owner.
	Owner *string `json:"owner,omitempty"`
	// An invite (#994): the client that uses it is a new person's first.
	Invite  *invite       `json:"invite,omitempty"`
	Expires records.Stamp `json:"expires"`
}

// invite is who an invite code makes: their name and role, and the admin who asked.
type invite struct {
	Name string `json:"name"`
	Role string `json:"role"`
	By   string `json:"by"`
}

// spent is ControlCodes.Spent: who spent a code, and as what (#212), so the same join
// tried again while the code lasts is given what it was given the first time.
type spent struct {
	PublicKey []byte  `json:"publicKey"`
	Client    *string `json:"client,omitempty"`
	Host      *string `json:"host,omitempty"`
	// Not stored: whether this is the earlier spend, read back.
	replayed bool
}

func codeKey(id string) string  { return "v1/codes/" + id + ".json" }
func spentKey(id string) string { return "v1/codes/" + id + ".spent" }

// Issue makes a code and writes it to the store, for clients/startPairing,
// machines/startEnroll or agents-control code. What uses it is the person's that ctx names
// (withCodeOwner), else the local owner's.
func (c *Codes) Issue(ctx context.Context, host, browser bool, lifetime time.Duration) (*wire.ControlCodeShown, error) {
	shown, _, err := c.issue(ctx, host, browser, lifetime, c.URL)
	return shown, err
}

// Invite makes an invite code (#994): a client code whose first client is a new person's.
func (c *Codes) Invite(ctx context.Context, in invite, lifetime time.Duration) (*wire.ControlCodeShown, error) {
	shown, _, err := c.issue(context.WithValue(ctx, inviteKey{}, in), false, false, lifetime, c.URL)
	return shown, err
}

type inviteKey struct{}

// issue makes a code that carries url, and says its id: a server behind a bastion dials
// its end of a reverse tunnel (#435).
func (c *Codes) issue(ctx context.Context, host, browser bool, lifetime time.Duration, url string) (*wire.ControlCodeShown, string, error) {
	private, public := c.keys()
	id, secret := controllink.MakeCodeSecret(private)
	expires := records.At(time.Now().Add(lifetime))
	stored := storedCode{Purpose: "client", Owner: codeOwnerOf(ctx), Expires: expires}
	if in, ok := ctx.Value(inviteKey{}).(invite); ok && !host {
		stored.Invite, stored.Owner = &in, nil
	}
	if host {
		stored.Purpose = "host"
	} else if browser {
		yes := true
		stored.Browser = &yes
	}
	data, err := records.Encode(stored)
	if err != nil {
		return nil, "", err
	}
	if _, err := c.Store.Put(ctx, codeKey(id), data, store.Absent); err != nil {
		return nil, "", err
	}
	code := &controllink.Code{Host: host, ControlKey: public, Secret: secret, URL: url, Pin: c.Pin, Name: c.Name}
	shown := &wire.ControlCodeShown{Text: code.Text(), Expires: dateOf(expires.Time)}
	if host {
		command := InstallCommand(url, c.Pin, shown.Text)
		shown.Command = &command
	}
	return shown, id, nil
}

// HostCode is what machines/install needs of the codes (hostinstall.CodeIssuer): a host
// code naming url ("" for this control plane's own address), and its id.
func (c *Codes) HostCode(ctx context.Context, url string) (string, string, error) {
	if url == "" {
		url = c.URL
	}
	shown, id, err := c.issue(ctx, true, false, controllink.CodeLifetime, url)
	if err != nil {
		return "", "", err
	}
	return shown.Text, id, nil
}

// Stored is a code as stored, refused if unknown, expired or (unless spentToo) spent;
// spentToo lets a spent one through, for Spend to tell a replayed join from another.
func (c *Codes) Stored(ctx context.Context, id string, spentToo bool) (*storedCode, error) {
	object, err := c.Store.Get(ctx, codeKey(id))
	if err != nil {
		return nil, err
	}
	var stored storedCode
	if object == nil || json.Unmarshal(object.Data, &stored) != nil || stored.Expires.IsZero() {
		return nil, controllink.Refuse(controllink.Unknown)
	}
	if !stored.Expires.After(time.Now()) {
		return nil, controllink.Refuse(controllink.Expired)
	}
	if !spentToo {
		was, err := c.Store.Get(ctx, spentKey(id))
		if err != nil {
			return nil, err
		}
		if was != nil {
			return nil, controllink.Refuse(controllink.Spent)
		}
	}
	return &stored, nil
}

// Spend uses a code: the first copy to write its .spent wins. The same key spending it
// again before it runs out is the same join, tried again after it could not be saved
// (#212): it is given the earlier spend, replayed. Any other key is refused.
func (c *Codes) Spend(ctx context.Context, id string, by spent) (*spent, error) {
	data, err := records.Encode(by)
	if err != nil {
		return nil, err
	}
	_, err = c.Store.Put(ctx, spentKey(id), data, store.Absent)
	if err == nil {
		return &by, nil
	}
	if !store.IsConflict(err) {
		return nil, err
	}
	object, err := c.Store.Get(ctx, spentKey(id))
	if err != nil {
		return nil, err
	}
	var earlier spent
	if object == nil || json.Unmarshal(object.Data, &earlier) != nil || len(by.PublicKey) == 0 ||
		!bytes.Equal(earlier.PublicKey, by.PublicKey) {
		return nil, controllink.Refuse(controllink.Spent)
	}
	earlier.replayed = true
	return &earlier, nil
}

// Respend says the code was spent as something else after all: the join that spent it,
// and only that one, is given a host id of its own when the one it asked for was taken
// (#1996), so a replay of it is given the same.
func (c *Codes) Respend(ctx context.Context, id string, by spent) error {
	data, err := records.Encode(by)
	if err != nil {
		return err
	}
	_, err = c.Store.Put(ctx, spentKey(id), data, store.Always)
	return err
}

// InstallScript is HostInstallScript.text: what a server runs to become a host, served at
// GET /v1/install.sh. scripts/host-install.sh is the same text.
//
//go:embed install.sh
var InstallScript string

// InstallCommand is HostInstallScript.command: the one line a person runs on the server,
// for a host code.
func InstallCommand(url, pin, code string) string {
	return fetchScript(url, pin) + " | sh -s -- '" + code + "'"
}

// JoinCommand is the one line that makes a server ask to join as a person, with no code
// (#994): it shows a short code, and the person approves it on a client.
func JoinCommand(url, pin, person string) string {
	if pin == "" {
		pin = "-"
	}
	return fetchScript(url, pin) + " | sh -s -- --join '" + strings.TrimSuffix(url, "/") + "' '" + pin + "' '" + person + "'"
}

func fetchScript(url, pin string) string {
	base := strings.TrimSuffix(url, "/")
	curl := "curl -fsSL"
	if pin != "" && pin != "-" {
		standard := strings.NewReplacer("-", "+", "_", "/").Replace(pin)
		for len(standard)%4 != 0 {
			standard += "="
		}
		curl += " --insecure --pinnedpubkey sha256//" + standard
	}
	return curl + " " + base + "/v1/install.sh"
}

// serverFileNames is ServerFiles.names: the only files /v1/servers/ hands out.
var serverFileNames = func() map[string]bool {
	names := map[string]bool{"VERSION": true}
	for _, arch := range []string{"x86_64", "aarch64"} {
		// The host (Go, #1136; one name since #1381); github-mcp (#1232), linear-mcp (#839), gitlab-mcp (#1629),
		// email-mcp (#1780).
		for _, program := range []string{"agentsd", "github-mcp", "linear-mcp", "gitlab-mcp", "email-mcp"} {
			names[program+"-linux-"+arch] = true
			names[program+"-linux-"+arch+".sha256"] = true
		}
	}
	return names
}()

// ServerFolder is ServerFiles.folder: AGENTS_CONTROL_SERVERS, the app bundle's
// Resources/servers beside Helpers/agents-control, or a container's /servers; the first
// with a VERSION in it.
func ServerFolder() string {
	var candidates []string
	if given := os.Getenv("AGENTS_CONTROL_SERVERS"); given != "" {
		candidates = append(candidates, given)
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		candidates = append(candidates, filepath.Join(filepath.Dir(filepath.Dir(exe)), "Resources", "servers"))
	}
	candidates = append(candidates, "/servers")
	for _, c := range candidates {
		if _, err := os.Stat(filepath.Join(c, "VERSION")); err == nil {
			return c
		}
	}
	return ""
}

// ToolsetFolder is where the runtimes' toolsets are read for machines/install (#1136):
// AGENTS_CONTROL_TOOLSETS, the app bundle's Resources/toolsets beside
// Helpers/agents-control, or a container's /toolsets; the first with a Claude manifest.
func ToolsetFolder() string {
	var candidates []string
	if given := os.Getenv("AGENTS_CONTROL_TOOLSETS"); given != "" {
		candidates = append(candidates, given)
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		candidates = append(candidates, filepath.Join(filepath.Dir(filepath.Dir(exe)), "Resources", "toolsets"))
	}
	candidates = append(candidates, "/toolsets")
	for _, c := range candidates {
		if _, err := os.Stat(filepath.Join(c, "claude", "manifest.json")); err == nil {
			return c
		}
	}
	return ""
}

// toolsetFileNames are the only files /v1/toolsets/ hands out (#1312): what a Linux host
// needs to install a Node toolset itself, for the runtimes machines/install installs that way.
var toolsetFileNames = func() map[string]bool {
	names := map[string]bool{}
	for _, runtime := range []string{"claude", "codex", "gemini"} {
		for _, file := range []string{"manifest.json", "package.json", "package-lock.json"} {
			names[runtime+"/"+file] = true
		}
	}
	return names
}()

// toolsetFile is a toolset's file by `<runtime>/<file>`, from the folder, never a path
// the request made up. The shown command fetches them into ~/.agents-server/toolsets.
func toolsetFile(name, folder string) ([]byte, bool) {
	if !toolsetFileNames[name] || folder == "" {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(folder, name))
	return data, err == nil
}

// serverFile is ServerFiles.read: a file by name, from the folder, never a path the
// request made up.
func serverFile(name, folder string) ([]byte, bool) {
	if !serverFileNames[name] || folder == "" {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(folder, name))
	return data, err == nil
}
