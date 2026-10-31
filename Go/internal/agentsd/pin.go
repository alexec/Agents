package agentsd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"syscall"

	"github.com/alexec/agents/Go/internal/controllink"
)

// A machine pinned to one control plane (#998, spec 998 slice 4, US7, FR-025–FR-029). An
// organisation's IT says which control plane a machine must join, and whether it runs
// nothing until it has: on a Mac with a configuration profile (managed preferences, which
// Agents Host reads and gives agentsd as --pin-address, --pin-key and --must-join), on
// Linux with /etc/agents/policy.json, owned by root and writable by nobody else. Both carry
// three keys only. Rules always come from the control plane (FR-029): any other key is
// ignored, and said once.
//
// Hosts never escalate: agentsd reads the managed preferences and the root-owned file, and
// never writes them.

// PinFile is where a Linux machine's pin is.
const PinFile = "/etc/agents/policy.json"

// MachinePin is the pin: the control plane's address, its key, and must join. Address and
// Key may each be empty; a pin with neither pins nothing.
type MachinePin struct {
	// Address is the control plane's host name ("control.acme.dev"), or a URL of it.
	Address string
	// Key is the control plane's key as a code carries it (base64url), or its key id
	// (controllink.KeyID).
	Key      string
	MustJoin bool
	// From says where the pin came from, for the log.
	From string
}

// pinWords is what a machine that must join, and has not, says (contracts/policy-api.md).
func (p *MachinePin) pinWords() string {
	if p.Address != "" {
		return "Your organisation requires this machine to join " + p.host() + "."
	}
	return "Your organisation requires this machine to join its control plane."
}

// host is the pin's address as a host name, lower case, with no port.
func (p *MachinePin) host() string { return hostOf(p.Address) }

func hostOf(address string) string {
	a := strings.TrimSpace(address)
	if strings.Contains(a, "://") {
		if u, err := url.Parse(a); err == nil {
			a = u.Hostname()
		}
	} else if i := strings.IndexAny(a, ":/"); i >= 0 {
		a = a[:i]
	}
	return strings.ToLower(strings.TrimSuffix(a, "."))
}

// keyMatches says the pin names this control key, by the key itself or its key id.
func (p *MachinePin) keyMatches(key []byte) bool {
	if p.Key == "" {
		return true
	}
	if len(key) == 0 {
		return false
	}
	k := strings.TrimSpace(p.Key)
	return k == controllink.B64URL(key) || k == controllink.KeyID(key)
}

// addressMatches says the pin names one of these addresses.
func (p *MachinePin) addressMatches(addresses ...string) bool {
	if p.Address == "" {
		return true
	}
	want := p.host()
	return slices.ContainsFunc(addresses, func(a string) bool { return a != "" && hostOf(a) == want })
}

// PinRefused is a code, a join or a membership for another control plane.
type PinRefused struct{ Words string }

func (e *PinRefused) Error() string { return e.Words }

// Admits says whether a code, an ask to join or a membership for the control plane at
// these addresses with this key (nil for an ask, which knows none yet) may be used here:
// nil, or why not, naming the control plane the organisation requires (US7 AS2, FR-027).
func (p *MachinePin) Admits(key []byte, addresses ...string) error {
	if p == nil || (p.Key == "" && p.Address == "") {
		return nil
	}
	// An ask to join knows no key before it is approved: its address is checked, and the
	// membership it makes is checked again, with its key.
	if p.addressMatches(addresses...) && (key == nil || p.keyMatches(key)) {
		return nil
	}
	required := "its control plane"
	if p.Address != "" {
		required = p.host()
	}
	return &PinRefused{Words: "Set by your organisation. This machine may join " + required + " only."}
}

// AdmitsMember is Admits for a kept membership: any address it dials.
func (p *MachinePin) AdmitsMember(m *controllink.Membership) error {
	addresses := slices.Clone(m.Addresses)
	addresses = append(addresses, m.URL)
	for _, e := range m.Endpoints {
		addresses = append(addresses, e.URL)
	}
	return p.Admits(m.ControlKey, addresses...)
}

// saidOnce keeps each "ignored" line to once a process (FR-029).
var saidOnce sync.Map

func sayOnce(line string) {
	if _, said := saidOnce.LoadOrStore(line, true); !said {
		log.Print(line)
	}
}

// ReadPinFile reads the pin at path, used only when the user owner owns it and nobody
// else can write it (FR-026): owner is 0, root, but a test's own uid. No file is no pin.
func ReadPinFile(path string, owner uint32) (*MachinePin, error) {
	info, err := os.Stat(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != owner || info.Mode().Perm()&0o022 != 0 || !info.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not used: it must be a file owned by root that nobody else can write", path)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(b, &doc); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	pin := &MachinePin{From: path}
	for k, v := range doc {
		switch k {
		case "controlPlane":
			var cp map[string]json.RawMessage
			if err := json.Unmarshal(v, &cp); err != nil {
				return nil, fmt.Errorf("%s: controlPlane: %v", path, err)
			}
			for ck, cv := range cp {
				switch ck {
				case "address":
					json.Unmarshal(cv, &pin.Address)
				case "key":
					json.Unmarshal(cv, &pin.Key)
				default:
					sayOnce(fmt.Sprintf("pin: %s: controlPlane.%s is ignored; rules come only from the control plane", path, ck))
				}
			}
		case "mustJoin":
			json.Unmarshal(v, &pin.MustJoin)
		default:
			sayOnce(fmt.Sprintf("pin: %s: %s is ignored; rules come only from the control plane", path, k))
		}
	}
	return pin, nil
}

// PinFromFlags is the pin Agents Host gives from the Mac's managed preferences, or nil.
func PinFromFlags(address, key string, mustJoin bool) *MachinePin {
	if address == "" && key == "" && !mustJoin {
		return nil
	}
	return &MachinePin{Address: address, Key: key, MustJoin: mustJoin, From: "managed preferences"}
}

type machinePinState struct {
	machinePinMu sync.Mutex
	machinePin   *MachinePin
	// machineMember is the membership this machine joined with, when its pin admits it.
	machineMember *controllink.Membership
}

// SetPin is the machine's pin, read once at start.
func (d *Daemon) SetPin(p *MachinePin) {
	d.machinePinMu.Lock()
	d.machinePin = p
	d.machinePinMu.Unlock()
	if p != nil {
		log.Printf("pin: from %s: address %q, key %q, must join %v", p.From, p.Address, p.Key, p.MustJoin)
	}
	d.tellPolicyState()
}

// Pin is the machine's pin, or nil.
func (d *Daemon) Pin() *MachinePin {
	d.machinePinMu.Lock()
	defer d.machinePinMu.Unlock()
	return d.machinePin
}

// SetMember is the membership this machine uses (the one its pin admits), once it has one.
func (d *Daemon) SetMember(m *controllink.Membership) {
	if m != nil {
		// A copy: the uplink changes its own as the control plane moves or rotates.
		c := *m
		c.ControlKey = slices.Clone(m.ControlKey)
		c.Addresses = slices.Clone(m.Addresses)
		c.Endpoints = slices.Clone(m.Endpoints)
		m = &c
	}
	d.machinePinMu.Lock()
	d.machineMember = m
	d.machinePinMu.Unlock()
	d.tellPolicyState()
}

// pinRefusal is mustJoin: the machine must join the pinned control plane and has not
// (FR-028). A key the pinned control plane rotated to is its own (#997). Nil otherwise.
func (d *Daemon) pinRefusal() error {
	d.machinePinMu.Lock()
	p, m := d.machinePin, d.machineMember
	d.machinePinMu.Unlock()
	if p == nil || !p.MustJoin {
		return nil
	}
	if m != nil && m.Host != "" {
		if p.AdmitsMember(m) == nil {
			return nil
		}
		if d.rotatedFromPinned(p) && p.addressMatches(append(slices.Clone(m.Addresses), m.URL)...) {
			return nil
		}
	}
	return policyRefusal("mustJoin", "", p.pinWords(), nil)
}

// rotatedFromPinned says the control key was rotated from the pinned key, within the 30
// days the old key is trusted.
func (d *Daemon) rotatedFromPinned(p *MachinePin) bool {
	d.orgMu.Lock()
	defer d.orgMu.Unlock()
	d.readOrgPolicyLocked()
	was := d.orgWas
	return len(was.PreviousKey) > 0 && was.PreviousUntil != nil && nowFunc().Before(*was.PreviousUntil) && p.keyMatches(was.PreviousKey)
}
