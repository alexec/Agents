package controlplane

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/wire"
)

// machine/pairWebPage (#4214): the machine on the control plane's own Mac gets a browser
// code in the web page's address; a machine elsewhere gets none.
func TestOnlyTheMachineHereGetsTheWebPagesCode(t *testing.T) {
	t.Parallel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		c.Web = &WebConfig{Folder: dist, Port: 0}
	})
	here, there := p.host("MACHINE-1"), p.host("MACHINE-2")
	params := json.RawMessage(`{}`)

	out, err := p.s.methods.HostSaid(here.member.Host, wire.CallMachinePairWebPage.Name, params)
	if err != nil {
		t.Fatal(err)
	}
	pairing := out.(*wire.WebPagePairing)
	prefix := web.OriginFor(p.s.WebPort()) + "/#code="
	if !strings.HasPrefix(pairing.URL, prefix) {
		t.Fatal(pairing.URL)
	}
	text, _ := url.QueryUnescape(strings.TrimPrefix(pairing.URL, prefix))
	if _, err := controllink.ParseCode(text); err != nil {
		t.Fatalf("%s: %v", text, err)
	}

	if _, err := p.s.methods.HostSaid(there.member.Host, wire.CallMachinePairWebPage.Name, params); err == nil {
		t.Fatal("a machine elsewhere got a code")
	}
}
