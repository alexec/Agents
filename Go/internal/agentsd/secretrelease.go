package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log"
	"os"
	goruntime "runtime"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/secretrelease"
	"github.com/alexec/agents/Go/wire"
)

// The release layer on Linux (#4058, the spike #4013). Every session runs as the same user,
// and the machine's key is a 0600 file, so an agent could open what is sealed only to it.
// So a flagged value is sealed first to a release key whose private half only the control
// plane keeps, and opens only when the control plane gives the key for that one value:
// against an approval that the answering client signed with its own lock key, naming the
// request, once (Go/internal/controlplane/secretrelease.go). An agent that reads the
// machine's key cannot sign as a person's device.
//
// The opened value is kept in agentsd's memory only, which no other process of the user
// reads (keepMemoryPrivate). "Allow for this session" and "Allow always" use it until
// agentsd restarts; after a restart, the first use asks again. The release key's public
// half is asked for at each run and kept in memory, never in a file an agent could change.

// releaseLayerHere is whether this machine keeps the release layer: Linux, with
// AGENTS_SECRET_RELEASE=1 until the clients sign their answers (#4017). Before that, no
// answer could open a value sealed this way. The tests turn it off for the Mac's path and
// on, by daemon, for this one (secretReleaseOn).
var releaseLayerHere = goruntime.GOOS == "linux" && os.Getenv("AGENTS_SECRET_RELEASE") == "1"

// releaseAsk bounds a call to the control plane for the release key.
const releaseAsk = 20 * time.Second

var (
	// errNotReleased is a value with a release layer that no signed approval opened in this run.
	errNotReleased = errors.New("on this machine it opens only for a use a person approved on one of their devices")
	// errNoControlPlane is a flagged value on a Linux machine with no control plane.
	errNoControlPlane = errors.New("a Linux machine keeps a secret with Ask before use only on a control plane, where a person's device approves each use; turn Ask before use off, or join a control plane")
)

type releaseState struct {
	secretReleaseMu sync.Mutex
	// secretReleaseOn turns the layer on or off for one daemon (tests); nil is releaseLayerHere.
	secretReleaseOn *bool
	// secretReleasePublic is the release key's public half, as the control plane said it.
	secretReleasePublic []byte
	// secretReleased is each value a signed approval opened, by store and name, with the hash of
	// the layer it came from, so a new value is not taken for the old one.
	secretReleased   map[string]releasedSecret
	secretPrivateSet bool
}

type releasedSecret struct {
	layer [sha256.Size]byte
	value string
}

func (d *Daemon) releaseLayerOn() bool {
	if d.secretReleaseOn != nil {
		return *d.secretReleaseOn
	}
	return releaseLayerHere
}

// releaseAD binds a release layer to where it is kept and its name.
func releaseAD(storeName, name string) []byte {
	return []byte("sealedsecret.release.v1|" + storeName + "|" + name)
}

// releasePublicKey is the release key's public half, asked of the control plane once a run.
func (d *Daemon) releasePublicKey() ([]byte, error) {
	d.secretReleaseMu.Lock()
	if d.secretReleasePublic != nil {
		defer d.secretReleaseMu.Unlock()
		return d.secretReleasePublic, nil
	}
	d.secretReleaseMu.Unlock()
	ask := d.askControl.Load()
	if ask == nil {
		return nil, errNoControlPlane
	}
	ctx, cancel := context.WithTimeout(d.ctx, releaseAsk)
	defer cancel()
	b, err := (*ask)(ctx, wire.CallMachineSecretKey.Name, wire.Empty{})
	if err != nil {
		return nil, releaseRefused("the control plane gave no release key", err)
	}
	var key wire.SecretReleaseKey
	if err := json.Unmarshal(b, &key); err != nil || len(key.PublicKey) != 32 {
		return nil, errors.New("the control plane's release key does not read")
	}
	d.secretReleaseMu.Lock()
	d.secretReleasePublic = key.PublicKey
	d.secretReleaseMu.Unlock()
	return key.PublicKey, nil
}

func releaseRefused(what string, err error) error {
	var refused *controllink.AskError
	if errors.As(err, &refused) {
		return errors.New(what + ": " + refused.Message)
	}
	return errors.New(what + ": " + err.Error())
}

func (d *Daemon) sealReleaseLayer(storeName, name, value string) (secretrelease.Layer, error) {
	public, err := d.releasePublicKey()
	if err != nil {
		return secretrelease.Layer{}, err
	}
	return secretrelease.Seal(public, name, value, releaseAD(storeName, name))
}

func releasedKey(storeName, name string) string { return storeName + "|" + name }

// releasedValue is the value a signed approval opened in this run, for the layer plain.
func (d *Daemon) releasedValue(storeName, name string, plain []byte) (string, bool) {
	d.secretReleaseMu.Lock()
	defer d.secretReleaseMu.Unlock()
	r, ok := d.secretReleased[releasedKey(storeName, name)]
	if !ok || r.layer != sha256.Sum256(plain) {
		return "", false
	}
	return r.value, true
}

// secretRecord is the sealed record an agent's name stands for, and the store it is in:
// its session's own first, then this machine's.
func (d *Daemon) secretRecord(agent wire.UUID, name string) (string, sealedValue, bool) {
	if v, ok := d.readSessionSecrets(agent).Secrets[name]; ok {
		if v.Sealed == nil {
			return "", sealedValue{}, false
		}
		return sealedSessionStore(agent), *v.Sealed, true
	}
	home := d.personalHome()
	if home == "" {
		return "", sealedValue{}, false
	}
	s, ok := readSealedSecrets(home).Secrets[name]
	return sealedLocal, s, ok
}

// needsRelease is whether the name an agent uses has a release layer: a person's answer
// that allows its use must be signed.
func (d *Daemon) needsRelease(agent wire.UUID, name string) bool {
	_, s, ok := d.secretRecord(agent, name)
	return ok && s.Release
}

// releasePending is whether the name an agent uses has a release layer that no signed
// approval opened in this run: the value is read only after the approval.
func (d *Daemon) releasePending(agent wire.UUID, name string) bool {
	storeName, s, ok := d.secretRecord(agent, name)
	if !ok || !s.Release {
		return false
	}
	plain, err := d.openOuter(storeName, name, s)
	if err != nil {
		return false
	}
	_, opened := d.releasedValue(storeName, name, plain)
	return !opened
}

// releaseForAnswer checks a person's signed answer to a use of a value with a release layer,
// and opens the value with the key the control plane releases for it, unless this run has
// it already. It is called before the answer is kept, so a refusal leaves the request open.
func (d *Daemon) releaseForAnswer(rec wire.Request, a *wire.RequestSecretUseAnswer) error {
	ask := *rec.Detail.SecretUse
	agent := *rec.AskedBy
	storeName, s, ok := d.secretRecord(agent, ask.Name)
	if !ok || !s.Release {
		return nil
	}
	refuse := func(why string) error {
		log.Printf("secret use: refused an answer for %s: %s", ask.Name, why)
		return &Error{Code: CodeNotPermitted, Message: "Nothing was allowed: " + why + "."}
	}
	if a.Approval == nil {
		return refuse("on this Linux machine, an answer that allows a use must be signed by your device, and this client did not sign it; answer on a client that signs, or update this one")
	}
	host, _, _, joined := d.lockIdentity()
	if !joined {
		return refuse("this machine has not joined a control plane")
	}
	var approved secretrelease.Approval
	if state, _ := d.heldLock(); state != nil {
		got, err := secretrelease.CheckApproval(state, host, *a.Approval, time.Now())
		if err != nil {
			return refuse(err.Error())
		}
		approved = got
	} else if a.Approval.Method != secretrelease.ApproveMethod || json.Unmarshal([]byte(a.Approval.Params), &approved) != nil {
		return refuse(secretrelease.ErrNotApproval.Error())
	}
	if approved.Request != rec.ID || approved.Name != ask.Name || approved.Use != string(ask.Use) ||
		approved.Place != ask.Place || approved.Action != a.Action {
		return refuse("the signature is for another answer")
	}
	plain, err := d.openOuter(storeName, ask.Name, s)
	if err != nil {
		return refuse(ask.Name + " does not open on this machine")
	}
	if _, ok := d.releasedValue(storeName, ask.Name, plain); ok {
		return nil
	}
	var layer secretrelease.Layer
	if err := json.Unmarshal(plain, &layer); err != nil {
		return refuse(ask.Name + "'s release layer does not read")
	}
	call := d.askControl.Load()
	if call == nil {
		return refuse("this machine is not connected to its control plane, which keeps the key; try again when it is")
	}
	ctx, cancel := context.WithTimeout(d.ctx, releaseAsk)
	defer cancel()
	b, err := (*call)(ctx, wire.CallMachineSecretRelease.Name,
		wire.SecretRelease{Name: ask.Name, Encapsulated: layer.Encapsulated, Approval: *a.Approval})
	if err != nil {
		return refuse(releaseRefused("the control plane did not release the key", err).Error())
	}
	var released wire.SecretReleased
	if err := json.Unmarshal(b, &released); err != nil {
		return refuse("the control plane's answer does not read")
	}
	value, err := secretrelease.Open(released.Key, layer, releaseAD(storeName, ask.Name))
	clear(released.Key)
	if err != nil {
		return refuse(err.Error())
	}
	d.keepReleased(storeName, ask.Name, plain, value)
	log.Printf("secret use: %s was released for a signed approval", ask.Name)
	return nil
}

// keepReleased keeps an opened value in agentsd's memory, which it makes private first.
func (d *Daemon) keepReleased(storeName, name string, plain []byte, value string) {
	d.secretReleaseMu.Lock()
	defer d.secretReleaseMu.Unlock()
	if !d.secretPrivateSet {
		if err := keepMemoryPrivate(); err != nil {
			log.Printf("secret use: agentsd's memory could not be made private: %v", err)
		}
		d.secretPrivateSet = true
	}
	if d.secretReleased == nil {
		d.secretReleased = map[string]releasedSecret{}
	}
	d.secretReleased[releasedKey(storeName, name)] = releasedSecret{layer: sha256.Sum256(plain), value: value}
}

// forgetReleased drops what a store's values opened to: a session's, when it is archived.
func (d *Daemon) forgetReleased(storeName string) {
	d.secretReleaseMu.Lock()
	defer d.secretReleaseMu.Unlock()
	for k := range d.secretReleased {
		if strings.HasPrefix(k, storeName+"|") {
			delete(d.secretReleased, k)
		}
	}
}
