package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The machine's browser (#3533): its lease, and the toolset this binary carries.

func TestTheBrowserIsALeaseOfItsOwn(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var snap wire.LeaseSnapshot
	if err := json.Unmarshal(c.call(t, 1, "resources/snapshot", nil), &snap); err != nil {
		t.Fatal(err)
	}
	var row *wire.ResourceState
	for i := range snap.Resources {
		if snap.Resources[i].Name == "browser:agents" {
			row = &snap.Resources[i]
		}
	}
	if row == nil || row.Kind != "browser" || row.DisplayName != "This machine's browser" || row.IsGone || *row.Places != 1 {
		t.Fatalf("%+v", snap.Resources)
	}
	d.leaseMu.Lock()
	name, kind, display, ok := d.resolveResource(" Browser:Agents ")
	d.leaseMu.Unlock()
	if !ok || name != "browser:agents" || kind != "browser" || display != "This machine's browser" {
		t.Fatal(name, kind, display, ok)
	}
	if d.browserBusy() {
		t.Fatal("busy with no lease")
	}
	if d.browser == nil || d.browser.Running() {
		t.Fatal("the browser starts only on first use")
	}
}

func TestTheBrowserToolsetIsCarried(t *testing.T) {
	folder := t.TempDir()
	if err := writeBrowserToolset(filepath.Join(folder, browserToolsetID)); err != nil {
		t.Fatal(err)
	}
	tool := loadToolsets(folder)[browserToolsetID]
	if tool == nil || tool.manifest.Package != "@playwright/mcp" || tool.manifest.Entry != "cli.js" || !regexp.MustCompile(`^[0-9a-f]{16}$`).MatchString(tool.id) {
		t.Fatalf("%+v", tool)
	}
	// Node for both kinds of server and both kinds of Mac.
	if n := tool.manifest.Node; n == nil || n.SHA256["x86_64"] == "" || n.SHA256["aarch64"] == "" {
		t.Fatalf("%+v", tool.manifest.Node)
	}
	if tool.node == nil || tool.node.SHA256["arm64"] == "" || tool.node.SHA256["x64"] == "" {
		t.Fatalf("%+v", tool.node)
	}
	// The package.json pin and the lock agree, so `npm ci` installs what the manifest says.
	var pkg struct{ Dependencies map[string]string }
	var lock struct {
		Packages map[string]struct{ Version string } `json:"packages"`
	}
	for file, into := range map[string]any{"package.json": &pkg, "package-lock.json": &lock} {
		b, err := os.ReadFile(filepath.Join(folder, browserToolsetID, file))
		if err != nil || json.Unmarshal(b, into) != nil {
			t.Fatal(file, err)
		}
	}
	want := pkg.Dependencies["@playwright/mcp"]
	if want == "" || lock.Packages["node_modules/@playwright/mcp"].Version != want || lock.Packages["node_modules/playwright-core"].Version == "" {
		t.Fatalf("package.json %v, lock %+v", pkg, lock.Packages)
	}
}

func TestTheBrowserNeedsAToolsHome(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	old := toolsHome
	toolsHome = ""
	t.Cleanup(func() { toolsHome = old })
	if _, err := d.browser.Endpoint(nil); err == nil || err.Error() != "The browser can't be installed on this Mac." && err.Error() != "The browser can't be installed on this server." {
		t.Fatal(err)
	}
}

func TestBrowserStateBeforeTheDownload(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var st wire.BrowserState
	if err := json.Unmarshal(c.call(t, 1, "browser/state", wire.Empty{}), &st); err != nil {
		t.Fatal(err)
	}
	if st.Installed || st.Running || st.DownloadBytes != 0 || st.Sites == nil || len(st.Sites) != 0 || st.Problem != nil {
		t.Fatalf("%+v", st)
	}
	if err := json.Unmarshal(c.call(t, 2, "browser/clear", wire.BrowserClearRequest{}), &st); err != nil || st.Installed {
		t.Fatal(err, st)
	}
	if d.browser.Running() {
		t.Fatal("Settings ▸ Browser started the browser before its download")
	}
	// The sites say where the person signed in, and Clear signs agents out: the person's
	// own clients only.
	for _, role := range []Role{RoleAgent, RoleHostApp, RoleWindow, RoleStranger} {
		for _, m := range []string{"browser/state", "browser/clear"} {
			if role.Allows(m) {
				t.Fatalf("the %s role may call %s", role, m)
			}
		}
	}
}
