package agentsd

import (
	"bytes"
	"errors"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/controllink"
)

// A machine pinned to one control plane (#998, spec 998 slice 4, US7, T044). The pin file's
// path and owner are parameters, so no test needs root.

// writePin writes a pin file with this mode, and says its path.
func writePin(t *testing.T, body string, mode os.FileMode) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "policy.json")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func me() uint32 { return uint32(os.Getuid()) }

// FR-026: the file is used only when its owner (root) owns it and nobody else can write it.
func TestThePinFileIsReadOnlyWhenRootOwnsIt(t *testing.T) {
	body := `{"controlPlane": {"address": "control.acme.dev", "key": "abc"}, "mustJoin": true}`
	pin, err := ReadPinFile(writePin(t, body, 0o644), me())
	if err != nil || pin == nil || pin.Address != "control.acme.dev" || pin.Key != "abc" || !pin.MustJoin {
		t.Fatalf("%+v %v", pin, err)
	}
	if pin, err := ReadPinFile(writePin(t, body, 0o664), me()); pin != nil || err == nil {
		t.Fatalf("a file others can write was used: %+v", pin)
	}
	if pin, err := ReadPinFile(writePin(t, body, 0o646), me()); pin != nil || err == nil {
		t.Fatalf("a file anyone can write was used: %+v", pin)
	}
	if pin, err := ReadPinFile(writePin(t, body, 0o644), me()+1); pin != nil || err == nil {
		t.Fatalf("a file another user owns was used: %+v", pin)
	}
	if pin, err := ReadPinFile(filepath.Join(t.TempDir(), "none.json"), me()); pin != nil || err != nil {
		t.Fatalf("no file: %+v %v", pin, err)
	}
}

// US7 AS4, FR-029: any other key, a rule, is ignored and logged once.
func TestARuleInThePinFileIsIgnoredAndSaidOnce(t *testing.T) {
	var out bytes.Buffer
	log.SetOutput(&out)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	path := writePin(t, `{"controlPlane": {"address": "control.acme.dev", "modes": "ask"}, "stopAll": {"on": true}, "budgets": {}}`, 0o644)
	for range 3 {
		pin, err := ReadPinFile(path, me())
		if err != nil || pin.Address != "control.acme.dev" || pin.MustJoin {
			t.Fatalf("%+v %v", pin, err)
		}
	}
	for _, key := range []string{"stopAll is ignored", "budgets is ignored", "controlPlane.modes is ignored"} {
		if n := strings.Count(out.String(), key); n != 1 {
			t.Fatalf("%q said %d times:\n%s", key, n, out.String())
		}
	}
}

// US7 AS2: a code or a join for another address or key is refused, and says which control
// plane is required; the pinned one, by its key or its key id, is admitted.
func TestAPinAdmitsOnlyItsControlPlane(t *testing.T) {
	k, other := newControlKeys(t), newControlKeys(t)
	pin := &MachinePin{Address: "control.acme.dev", Key: controllink.B64URL(k.public)}
	if err := pin.Admits(k.public, "https://control.acme.dev:8443"); err != nil {
		t.Fatal(err)
	}
	for _, refused := range []error{
		pin.Admits(other.public, "https://control.acme.dev"),
		pin.Admits(k.public, "https://control.elsewhere.dev"),
		pin.Admits(nil, "https://control.elsewhere.dev"),
	} {
		var p *PinRefused
		if !errors.As(refused, &p) || !strings.Contains(p.Words, "control.acme.dev") || !strings.HasPrefix(p.Words, orgSetBy) {
			t.Fatalf("not refused for the pin: %v", refused)
		}
	}
	byID := &MachinePin{Key: controllink.KeyID(k.public)}
	if byID.Admits(k.public, "https://anywhere.dev") != nil || byID.Admits(other.public, "https://anywhere.dev") == nil {
		t.Fatal("a key id pins by key")
	}
	member := &controllink.Membership{Host: "h1", ControlKey: k.public, URL: "https://10.0.0.1:443",
		Addresses: []string{"control.acme.dev"}}
	if err := pin.AdmitsMember(member); err != nil {
		t.Fatal(err)
	}
	var none *MachinePin
	if none.Admits(other.public, "https://x") != nil {
		t.Fatal("no pin refused a code")
	}
}

// US7 AS1, FR-028: a machine that must join and has not starts no agent, shell or
// workflow; once it has joined the pinned control plane, it does.
func TestAMachineThatMustJoinRunsNothingUntilItHas(t *testing.T) {
	fakeRuntimes(t)
	t.Setenv("SHELL", "/bin/sh")
	k := newControlKeys(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SetPin(PinFromFlags("control.acme.dev", controllink.KeyID(k.public), true))
	dir := folder(t, c, 1)
	refused(t, c.callError(t, 2, "agents/start", startParams(dir, "claude", nil)), "mustJoin", "")
	e := c.callError(t, 3, "agents/start", startParams(dir, "claude", nil))
	if !strings.Contains(e.Message, "join control.acme.dev") {
		t.Fatal(e.Message)
	}
	folder := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	os.WriteFile(filepath.Join(workflowsFolder(dir), "review.md"), []byte("---\nname: Review\non: lease.granted\n---\nReview.\n"), 0o644)
	approveAll(t, c, folder)
	refused(t, c.callError(t, 4, "workflows/run", map[string]any{"folder": folder, "workflowID": "review"}), "mustJoin", "")
	work, _ := store.Resolve(t.TempDir())
	id := anAgentIn(t, d, work)
	refused(t, c.callError(t, 5, "shell/attach", map[string]any{"agentID": id, "shell": 0, "rows": 24, "cols": 80}), "mustJoin", "")
	st := d.policyState()
	if st.Refusal == nil || st.Refusal.Reason != "mustJoin" {
		t.Fatalf("%+v", st)
	}
	// Joined another control plane: still nothing.
	other := newControlKeys(t)
	d.SetMember(&controllink.Membership{Host: "h1", ControlKey: other.public, URL: "https://control.acme.dev"})
	refused(t, c.callError(t, 6, "agents/start", startParams(dir, "claude", nil)), "mustJoin", "")
	// Joined the pinned one: everything runs.
	d.SetMember(&controllink.Membership{Host: "h1", ControlKey: k.public, URL: "https://control.acme.dev"})
	c.call(t, 7, "agents/start", startParams(dir, "claude", nil))
	c.call(t, 8, "shell/attach", map[string]any{"agentID": id, "shell": 0, "rows": 24, "cols": 80})
}

// A pin that does not say must join refuses nothing on its own.
func TestAPinWithoutMustJoinRefusesNoWork(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.SetPin(PinFromFlags("control.acme.dev", "", false))
	c.call(t, 1, "agents/start", startParams(t.TempDir(), "claude", nil))
	if PinFromFlags("", "", false) != nil {
		t.Fatal("no managed preferences made a pin")
	}
}
