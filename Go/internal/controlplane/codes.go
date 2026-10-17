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
)

// Codes is ControlCodes: pairing and enrolment codes (data-model.md "Code"), stored by
// id with nothing secret, used once at any copy.
type Codes struct {
	Store   store.Store
	Private []byte
	Public  []byte
	URL     string
	Pin     string
	Name    string
}

// storedCode is ControlCodes.Stored.
type storedCode struct {
	Purpose string `json:"purpose"`
	// Made for a browser on this Mac (071 R2): good only through the loopback listener.
	Browser *bool         `json:"browser,omitempty"`
	Owner   *string       `json:"owner,omitempty"`
	Expires records.Stamp `json:"expires"`
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
// hosts/startEnroll or agents-control code.
func (c *Codes) Issue(ctx context.Context, host, browser bool, lifetime time.Duration) (*codeShown, error) {
	shown, _, err := c.issue(ctx, host, browser, lifetime, c.URL)
	return shown, err
}

// issue makes a code that carries url, and says its id: a server behind a bastion dials
// its end of a reverse tunnel (#435).
func (c *Codes) issue(ctx context.Context, host, browser bool, lifetime time.Duration, url string) (*codeShown, string, error) {
	id, secret := controllink.MakeCodeSecret(c.Private)
	expires := records.At(time.Now().Add(lifetime))
	stored := storedCode{Purpose: "client", Expires: expires}
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
	code := &controllink.Code{Host: host, ControlKey: c.Public, Secret: secret, URL: url, Pin: c.Pin, Name: c.Name}
	shown := &codeShown{Text: code.Text(), Expires: RefDate(expires.Time)}
	if host {
		command := InstallCommand(url, c.Pin, shown.Text)
		shown.Command = &command
	}
	return shown, id, nil
}

// HostCode is what hosts/install needs of the codes (hostinstall.CodeIssuer): a host
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

// InstallScript is HostInstallScript.text: what a server runs to become a host, served at
// GET /v1/install.sh. scripts/host-install.sh is the same text.
//
//go:embed install.sh
var InstallScript string

// InstallCommand is HostInstallScript.command: the one line a person runs on the server,
// for a host code.
func InstallCommand(url, pin, code string) string {
	base := strings.TrimSuffix(url, "/")
	curl := "curl -fsSL"
	if pin != "" {
		standard := strings.NewReplacer("-", "+", "_", "/").Replace(pin)
		for len(standard)%4 != 0 {
			standard += "="
		}
		curl += " --insecure --pinnedpubkey sha256//" + standard
	}
	return curl + " " + base + "/v1/install.sh | sh -s -- '" + code + "'"
}

// serverFileNames is ServerFiles.names: the only files /v1/servers/ hands out.
var serverFileNames = func() map[string]bool {
	names := map[string]bool{"VERSION": true, "VERSION-go": true}
	for _, arch := range []string{"x86_64", "aarch64"} {
		// agentsd-go (#1136): the Go host, for install.sh --impl go.
		for _, program := range []string{"agentsd", "agentsd-go", "ci-watcher"} {
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

// ToolsetFolder is where the runtimes' toolsets are read for hosts/install (#1136):
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

// serverFile is ServerFiles.read: a file by name, from the folder, never a path the
// request made up.
func serverFile(name, folder string) ([]byte, bool) {
	if !serverFileNames[name] || folder == "" {
		return nil, false
	}
	data, err := os.ReadFile(filepath.Join(folder, name))
	return data, err == nil
}
