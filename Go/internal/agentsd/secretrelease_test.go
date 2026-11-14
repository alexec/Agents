package agentsd

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controllink"
	"github.com/agentloops-dev/agent-loops/Go/internal/machinelock"
	"github.com/agentloops-dev/agent-loops/Go/internal/secretrelease"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// fakeRelease is the control plane's half of #4058: it keeps the release key, and gives one
// value's key only for a fresh approval a client of sam's lock signed, once.
type fakeRelease struct {
	mu       sync.Mutex
	state    *machinelock.State
	seen     map[string]bool
	released int
}

func (f *fakeRelease) ask(t *testing.T) askControl {
	private, err := secretrelease.NewKey()
	if err != nil {
		t.Fatal(err)
	}
	return func(_ context.Context, method string, params any) (json.RawMessage, error) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch method {
		case wire.CallMachineSecretKey.Name:
			return json.Marshal(wire.SecretReleaseKey{PublicKey: private.PublicKey().Bytes()})
		case wire.CallMachineSecretRelease.Name:
			r := params.(wire.SecretRelease)
			a, err := secretrelease.CheckApproval(f.state, "h-1", r.Approval, time.Now())
			if err != nil {
				return nil, &controllink.AskError{Code: CodeNotPermitted, Message: err.Error()}
			}
			if id := machinelock.SignedID(r.Approval.Lock); f.seen[id] || a.Name != r.Name {
				return nil, &controllink.AskError{Code: CodeNotPermitted, Message: "that approval was used before"}
			} else {
				f.seen[id] = true
			}
			key, err := secretrelease.Release(private, r.Name, r.Encapsulated)
			if err != nil {
				return nil, err
			}
			f.released++
			return json.Marshal(wire.SecretReleased{Key: key})
		}
		return nil, errors.New("no method " + method)
	}
}

// linuxMachine is fillSetUp's machine as h-1 of sam's lock, with the phone a client of it,
// and the release layer on.
func linuxMachine(t *testing.T) (*mcpClient, *fillPage, *Daemon, *ecdsa.PrivateKey, *machinelock.State) {
	t.Helper()
	m, page, d := fillSetUp(t, nil)
	d.secretReleaseOn = new(true)
	private, err := controllink.HostPrivateKey(d.HostKey)
	if err != nil {
		t.Fatal(err)
	}
	key, _ := controllink.PublicKey(private)
	if err := (&controllink.Membership{Host: "h-1", Addresses: []string{}}).Save(d.Store.Loc.Root); err != nil {
		t.Fatal(err)
	}
	mac, phone := newLockKey(t), newLockKey(t)
	c := []wire.LockEntry{lockEntry(t, mac, wire.LockEntryKindRoot, mac, nil)}
	for _, body := range []wire.LockBody{
		{Kind: wire.LockEntryKindAddClient, Key: machinelock.PublicKey(phone), ID: new(phoneClient)},
		{Kind: wire.LockEntryKindAddMachine, Key: key, SealingKey: key, ID: new("h-1")},
	} {
		h := machinelock.HashOf(c[len(c)-1])
		body.Person, body.Previous, body.At = "sam", h[:], wire.DateOf(time.Now())
		e, err := machinelock.Sign(mac, body)
		if err != nil {
			t.Fatal(err)
		}
		c = append(c, e)
	}
	if !d.TakeLock(wire.Lock{Person: "sam", Entries: c}) {
		t.Fatal("the lock was not taken")
	}
	state, _ := d.heldLock()
	return m, page, d, phone, state
}

func signedAnswer(t *testing.T, key *ecdsa.PrivateKey, r wire.Request, action string) *wire.RequestSecretUseAnswer {
	t.Helper()
	s := r.Detail.SecretUse
	approval, err := secretrelease.SignApproval(key, "h-1", secretrelease.Approval{Request: r.ID, Name: s.Name,
		Use: string(s.Use), Place: s.Place, Action: action}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return &wire.RequestSecretUseAnswer{Action: action, Approval: &approval}
}

// #4058: on Linux, a machine with no control plane keeps no flagged value; with one, the
// value is sealed to the release key too, and opens only for an approval the person's
// device signed, which the control plane takes once. After a restart, a grant asks again.
func TestOnLinuxAFlaggedValueOpensOnlyForASignedApproval(t *testing.T) {
	_, left := formHolds(t)
	m, page, d, phone, state := linuxMachine(t)

	// No control plane: no flagged value, and nothing in the plain file either.
	if err := d.saveSecret("GITLAB_PASSWORD", filledValue, true); err == nil || !strings.Contains(err.Error(), "only on a control plane") {
		t.Fatalf("a flagged save with no control plane: %v", err)
	}
	if v, _, _ := d.localSecret("", "GITLAB_PASSWORD"); v != "" {
		t.Fatal("the value was kept")
	}

	plane := &fakeRelease{state: state, seen: map[string]bool{}}
	d.SetControlAsk(plane.ask(t))
	if err := d.saveSecret("GITLAB_PASSWORD", filledValue, true); err != nil {
		t.Fatal(err)
	}
	home := personalHomeOf(t, d)
	b, _ := os.ReadFile(sealedSecretsPath(home))
	if strings.Contains(string(b), filledValue) || !strings.Contains(string(b), `"release":true`) {
		t.Fatalf("sealed.json: %s", b)
	}
	// The machine's key alone, which an agent can read on Linux, opens only the layer.
	if _, ok := d.sealedLocalSecret(home, "GITLAB_PASSWORD"); ok {
		t.Fatal("the value opened with the machine's key alone")
	}

	// The request says the answer must be signed; one that is not is refused, and stays open.
	done := fillAsync(m, 2)
	r := openSecretUse(t, d)
	if r.Detail.SecretUse.NeedsSignature == nil || !*r.Detail.SecretUse.NeedsSignature {
		t.Fatalf("%+v", r.Detail.SecretUse)
	}
	if _, err := d.answerSecretUse(r, &wire.RequestSecretUseAnswer{Action: secretUseOnce}, nil); err == nil || !strings.Contains(err.Error(), "signed by your device") {
		t.Fatalf("an unsigned answer: %v", err)
	}
	// Nor one the machine's own key signed, nor one signed for another answer.
	other := signedAnswer(t, phone, r, secretUseSession)
	other.Action = secretUseOnce
	if _, err := d.answerSecretUse(r, other, nil); err == nil || !strings.Contains(err.Error(), "another answer") {
		t.Fatalf("a signature for another action: %v", err)
	}
	private, _ := controllink.HostPrivateKey(d.HostKey)
	machineKey, _ := machinelock.MachineSigner(private)
	if _, err := d.answerSecretUse(r, signedAnswer(t, machineKey, r, secretUseOnce), nil); err == nil || !strings.Contains(err.Error(), "not signed by one of your devices") {
		t.Fatalf("an answer the machine signed: %v", err)
	}
	if after := d.request(r.ID); after == nil || after.State != wire.RequestStateOpen || plane.released != 0 {
		t.Fatalf("a refused answer ended the request: %+v, %d released", after, plane.released)
	}

	// The phone's signed answer: the control plane releases the key, and the fill goes.
	once := signedAnswer(t, phone, r, secretUseOnce)
	if _, err := d.answerSecretUse(r, once, nil); err != nil {
		t.Fatal(err)
	}
	if got := replyOf(t, done); got.IsError || page.value != filledValue || plane.released != 1 {
		t.Fatalf("%+v %q %d", got, page.value, plane.released)
	}
	// The control plane takes that approval once.
	layer := readSealedSecrets(home).Secrets["GITLAB_PASSWORD"]
	outer, _ := d.openOuter(sealedLocal, "GITLAB_PASSWORD", layer)
	var l secretrelease.Layer
	json.Unmarshal(outer, &l)
	if _, err := (*d.askControl.Load())(context.Background(), wire.CallMachineSecretRelease.Name,
		wire.SecretRelease{Name: "GITLAB_PASSWORD", Encapsulated: l.Encapsulated, Approval: *once.Approval}); err == nil {
		t.Fatal("the control plane took an approval twice")
	}

	// Always, signed: a grant, and the value in memory until a restart.
	page.value = ""
	done = fillAsync(m, 3)
	r = openSecretUse(t, d)
	if _, err := d.answerSecretUse(r, signedAnswer(t, phone, r, secretUseAlways), nil); err != nil {
		t.Fatal(err)
	}
	if got := replyOf(t, done); got.IsError || page.value != filledValue || len(d.secretGrants().Grants) != 1 {
		t.Fatalf("%+v %q", got, page.value)
	}
	// After a restart (nothing in memory), the grant asks again.
	d.secretReleaseMu.Lock()
	d.secretReleased = nil
	d.secretReleaseMu.Unlock()
	page.value = ""
	left() // this call must outlast its hold
	if got := replyOf(t, fillAsync(m, 4)); !strings.Contains(replyText(got), "wait_for_event") || page.value != "" {
		t.Fatalf("after a restart: %+v %q", got, page.value)
	}
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)
}

// #4149: a Linux machine with no control plane offers no Ask before use on the ask card, and
// a typed answer is kept without the flag; once it has joined, the card offers it again.
func TestALinuxMachineWithNoControlPlaneOffersNoAskBeforeUse(t *testing.T) {
	_, _, d := fillSetUp(t, nil)
	d.secretReleaseOn = new(true)
	if d.keepsFlagged() {
		t.Fatal("a machine with no control plane offers Ask before use")
	}
	agent := seeded(t, d, t.TempDir(), nil).ID
	secret := wire.ElicitationSecret{Name: "GITLAB_TOKEN"}
	if err := d.saveAskedSecret(agent, secret, map[string]wire.JSONValue{secretField: wire.JSONValue(`"` + filledValue + `"`)}); err != nil {
		t.Fatalf("an answer with no flag offered: %v", err)
	}
	if isSealedSecret(d.personalHome(), "GITLAB_TOKEN") {
		t.Fatal("the value was sealed with Ask before use")
	}
	if _, err := controllink.HostPrivateKey(d.HostKey); err != nil {
		t.Fatal(err)
	}
	if err := (&controllink.Membership{Host: "h-1", Addresses: []string{}}).Save(d.Store.Loc.Root); err != nil {
		t.Fatal(err)
	}
	if !d.keepsFlagged() {
		t.Fatal("a machine that joined a control plane offers no Ask before use")
	}
}
