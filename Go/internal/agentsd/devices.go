package agentsd

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Pairing (021 US5, 046), as DaemonCore+Devices: the paired devices in devices.json, the
// Mac's relay key in relay.json, and the one pairing code the Mac is showing. A device
// not yet on record is taken only from a connection the bridge bound to a pairing phone
// while that code is good, or from a device's channel the control plane opened (it paired
// the device there, #232). Only a Mac host serves these (devices_darwin.go); the binding is
// heard everywhere, so a server's host can tell a device's connection from a window's.

// pairingLifetime is five minutes: long enough to find the phone, short enough that a code
// left on the screen is soon worth nothing.
const pairingLifetime = 5 * time.Minute

type deviceBook struct {
	devMu      sync.Mutex
	devRecords []deviceRecord
	devLoaded  bool
	devPairing *wire.PairingCode
	// bound is what connection/bindDevice made of a connection: a device's or a pairing
	// phone's, and the one device it may speak as.
	devBound map[*Client]*binding
}

type binding struct {
	pairing bool
	device  wire.UUID
}

// deviceRecord is one device and what a later build wrote beside its fields, kept so
// this one does not damage it.
type deviceRecord struct {
	wire.Device
	extra map[string]json.RawMessage
}

var deviceKeys = []string{"id", "publicKey", "name", "kind", "announcedAt", "lastSeenAt", "mayNotify"}

func (r *deviceRecord) UnmarshalJSON(b []byte) error {
	if err := json.Unmarshal(b, &r.Device); err != nil {
		return err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(b, &all); err != nil {
		return err
	}
	// What Device's decoder requires.
	for _, k := range []string{"id", "name", "announcedAt"} {
		if all[k] == nil {
			return fmt.Errorf("a device with no %s", k)
		}
	}
	for _, k := range deviceKeys {
		delete(all, k)
	}
	if len(all) > 0 {
		r.extra = all
	}
	return nil
}

func (r deviceRecord) MarshalJSON() ([]byte, error) {
	b, err := json.Marshal(r.Device)
	if err != nil || len(r.extra) == 0 {
		return b, err
	}
	var all map[string]json.RawMessage
	json.Unmarshal(b, &all)
	for k, v := range r.extra {
		all[k] = v
	}
	return json.Marshal(all)
}

func (d *Daemon) devicesFile() string { return filepath.Join(d.Store.Loc.Root, "devices.json") }
func (d *Daemon) relayFile() string   { return filepath.Join(d.Store.Loc.Root, "relay.json") }

// loadDevices is DeviceStore.load: no file is no devices, a file that is not a list is
// set aside, a bad record costs that record only, and one id is one device.
func (d *Daemon) loadDevices() {
	if d.devLoaded {
		return
	}
	d.devLoaded = true
	b, err := os.ReadFile(d.devicesFile())
	if err != nil {
		return
	}
	var raws []json.RawMessage
	if json.Unmarshal(b, &raws) != nil {
		os.Rename(d.devicesFile(), fmt.Sprintf("%s.corrupt-%d", d.devicesFile(), time.Now().Unix()))
		store.TrimSetAsides(d.devicesFile())
		log.Print("devices.json: could not read it; starting with no paired devices")
		return
	}
	seen := map[wire.UUID]bool{}
	for _, raw := range raws {
		var r deviceRecord
		if json.Unmarshal(raw, &r) != nil || r.ID == "" {
			continue
		}
		r.ID = wire.UUID(strings.ToUpper(string(r.ID)))
		if !seen[r.ID] {
			seen[r.ID] = true
			d.devRecords = append(d.devRecords, r)
		}
	}
}

func (d *Daemon) findDevice(id wire.UUID) int {
	for i, r := range d.devRecords {
		if strings.EqualFold(string(r.ID), string(id)) {
			return i
		}
	}
	return -1
}

// writeDevices is DeviceStore.save: announced first.
func (d *Daemon) writeDevices() error {
	sort.SliceStable(d.devRecords, func(i, j int) bool { return d.devRecords[i].AnnouncedAt < d.devRecords[j].AnnouncedAt })
	b, err := storeJSON(d.devRecords)
	if err != nil {
		return err
	}
	return store.WriteAtomically(d.devicesFile(), b, 0o644)
}

func (d *Daemon) saveDevice(r deviceRecord) error {
	if i := d.findDevice(r.ID); i >= 0 {
		d.devRecords[i] = r
	} else {
		d.devRecords = append(d.devRecords, r)
	}
	if err := d.writeDevices(); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: "devices.json: " + err.Error()}
	}
	dev := r.Device
	Broadcast(d, wire.NotifyDeviceChanged, wire.DeviceNotification{ID: r.ID, Device: &dev})
	return nil
}

// listDevices is devices/list, announced first.
func (d *Daemon) listDevices() []wire.Device {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	d.loadDevices()
	out := make([]wire.Device, 0, len(d.devRecords))
	for _, r := range d.devRecords {
		out = append(out, r.Device)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].AnnouncedAt < out[j].AnnouncedAt })
	return out
}

// bindDevice is connection/bindDevice: the bridge saying a window's connection carries a
// device, or a phone that is pairing. Never undone, and never from a device's own.
func (d *Daemon) bindDevice(c *Client, b wire.DeviceBinding) error {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	if c.conn.Device() != "" || d.devBound[c] != nil {
		return &Error{Code: wire.FailureNotPermitted, Message: "Only a window's connection can be given to a device."}
	}
	if d.devBound == nil {
		d.devBound = map[*Client]*binding{}
	}
	// A connection gone is a binding gone.
	d.mu.Lock()
	for k := range d.devBound {
		if d.clients[k.ID] != k {
			delete(d.devBound, k)
		}
	}
	d.mu.Unlock()
	n := &binding{pairing: b.Pairing != nil && *b.Pairing}
	if b.ID != nil {
		n.device = wire.UUID(strings.ToUpper(string(*b.ID)))
	}
	d.devBound[c] = n
	return nil
}

// callerDevice is the device a connection carries, and whether it is a device's at all:
// a control-plane channel for one (vouched), or one the bridge bound.
func (d *Daemon) callerDevice(c *Client) (b *binding, vouched bool) {
	if id := c.conn.Device(); id != "" {
		return &binding{device: wire.UUID(strings.ToUpper(id))}, true
	}
	return d.devBound[c], false
}

// announce is devices/announce. The same id with the same key is the same device and
// gets its record back; a different key under an id is refused.
func (d *Daemon) announce(c *Client, a wire.DeviceAnnouncement) (wire.AnnounceReply, error) {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	d.loadDevices()
	a.ID = wire.UUID(strings.ToUpper(string(a.ID)))
	b, vouched := d.callerDevice(c)
	if b != nil {
		// A device's connection speaks as the first device it names, and no other.
		if b.device == "" {
			b.device = a.ID
		} else if b.device != a.ID {
			return wire.AnnounceReply{}, &Error{Code: wire.FailureNotPermitted, Message: "A device's connection speaks only for that device."}
		}
	}
	pairing := b != nil && b.pairing
	if pairing && (d.devPairing == nil || !nowFunc().Before(d.devPairing.Expires.Time())) {
		return wire.AnnounceReply{}, &Error{Code: wire.FailureNotAllowed, Message: "That pairing code has run out. Show a new one on the Mac."}
	}
	i := d.findDevice(a.ID)
	if i < 0 && b != nil && !pairing && !vouched {
		return wire.AnnounceReply{}, &Error{Code: wire.FailureNotAllowed, Message: "Pair this device by scanning the code in the Mac's Settings."}
	}
	if pairing {
		defer d.endPairing()
	}
	var r deviceRecord
	if i >= 0 {
		r = d.devRecords[i]
		if !bytes.Equal(r.PublicKey, a.PublicKey) {
			return wire.AnnounceReply{}, &Error{Code: wire.FailureNotSupported, Message: "A device's key does not change. A device with a new key is a new device."}
		}
		r.Name, r.Kind = a.Name, a.Kind
		t := now()
		r.LastSeenAt = &t
	} else {
		t := now()
		r = deviceRecord{Device: wire.Device{ID: a.ID, PublicKey: a.PublicKey, Name: a.Name, Kind: a.Kind, AnnouncedAt: t, LastSeenAt: &t}}
	}
	if err := d.saveDevice(r); err != nil {
		return wire.AnnounceReply{}, err
	}
	if i < 0 {
		safe.Go("reconsider", d.reconsider)
	}
	return wire.AnnounceReply{ID: r.ID, PublicKey: r.PublicKey, Name: r.Name, Kind: r.Kind, AnnouncedAt: r.AnnouncedAt,
		LastSeenAt: r.LastSeenAt, MayNotify: r.MayNotify, MacKey: d.relayKey()}, nil
}

// forgetDevice is devices/forget: the Mac's window only. Its connections are closed too,
// so a forgotten phone keeps nothing it had.
func (d *Daemon) forgetDevice(c *Client, id wire.UUID) error {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	if b, _ := d.callerDevice(c); b != nil {
		return &Error{Code: wire.FailureNotAllowed, Message: "Only the Mac can forget a device."}
	}
	d.loadDevices()
	i := d.findDevice(id)
	if i < 0 {
		return nil
	}
	id = d.devRecords[i].ID
	d.devRecords = append(d.devRecords[:i], d.devRecords[i+1:]...)
	if err := d.writeDevices(); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: "devices.json: " + err.Error()}
	}
	yes := true
	Broadcast(d, wire.NotifyDeviceChanged, wire.DeviceNotification{ID: id, Removed: &yes})
	d.mu.Lock()
	var gone []*Client
	for _, k := range d.clients {
		if b := d.devBound[k]; strings.EqualFold(k.conn.Device(), string(id)) || b != nil && b.device == id {
			gone = append(gone, k)
		}
	}
	d.mu.Unlock()
	for _, k := range gone {
		k.conn.Close()
	}
	safe.Go("reconsider", d.reconsider)
	return nil
}

// refuseDevice keeps what only the Mac's own window asks for from a device's connection.
func (d *Daemon) refuseDevice(c *Client, method string) error {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	if b, _ := d.callerDevice(c); b != nil {
		return &Error{Code: wire.FailureNotPermitted, Message: method + " is not open to a device's connection."}
	}
	return nil
}

// startPairing is devices/startPairing: a fresh code each time, replacing any before it.
func (d *Daemon) startPairing() (wire.PairingCode, error) {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	key := d.relayKey()
	if key == nil {
		return wire.PairingCode{}, &Error{Code: wire.FailureNotAllowed, Message: "The phone bridge isn't running, so there is nothing for a phone to pair with."}
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return wire.PairingCode{}, err
	}
	code := wire.PairingCode{MacKey: key, Secret: secret, Name: macName(), Expires: wire.DateOf(nowFunc().Add(pairingLifetime))}
	d.devPairing = &code
	Broadcast(d, wire.NotifyPairingChanged, wire.Empty{})
	return code, nil
}

func (d *Daemon) endPairing() {
	if d.devPairing == nil {
		return
	}
	d.devPairing = nil
	Broadcast(d, wire.NotifyPairingChanged, wire.Empty{})
}

// currentPairing is pairing/current, for the bridge: a code run out is not handed out.
func (d *Daemon) currentPairing() wire.PairingSecret {
	d.devMu.Lock()
	defer d.devMu.Unlock()
	if d.devPairing == nil || !nowFunc().Before(d.devPairing.Expires.Time()) {
		return wire.PairingSecret{}
	}
	e := d.devPairing.Expires
	return wire.PairingSecret{Secret: d.devPairing.Secret, Expires: &e}
}

// relayKey is the public half of the Mac's relay key, if a bridge has registered one.
func (d *Daemon) relayKey() wire.Data {
	b, err := os.ReadFile(d.relayFile())
	if err != nil {
		return nil
	}
	var r wire.RelayRegistration
	if json.Unmarshal(b, &r) != nil || len(r.PublicKey) == 0 {
		return nil
	}
	return r.PublicKey
}

// registerRelayKey is relay/register: an uncompressed P256 point, or refused.
func (d *Daemon) registerRelayKey(key wire.Data) error {
	if len(key) != 65 || key[0] != 0x04 {
		return Invalid("A relay key is an uncompressed P256 public key, 65 bytes.")
	}
	d.devMu.Lock()
	defer d.devMu.Unlock()
	if bytes.Equal(d.relayKey(), key) {
		return nil
	}
	b, err := storeJSON(wire.RelayRegistration{PublicKey: key})
	if err == nil {
		err = store.WriteAtomically(d.relayFile(), b, 0o644)
	}
	return err
}

// serveDevices registers the methods; devices_darwin.go calls it.
func (d *Daemon) serveDevices() {
	On(d, wire.CallDevicesList, func(context.Context, *Client, wire.Empty) ([]wire.Device, error) {
		return d.listDevices(), nil
	})
	On(d, wire.CallDevicesAnnounce, func(_ context.Context, c *Client, a wire.DeviceAnnouncement) (wire.AnnounceReply, error) {
		return d.announce(c, a)
	})
	On(d, wire.CallDevicesForget, func(_ context.Context, c *Client, r wire.DeviceForget) (wire.Empty, error) {
		return wire.Empty{}, d.forgetDevice(c, r.ID)
	})
	On(d, wire.CallDevicesStartPairing, func(_ context.Context, c *Client, _ wire.Empty) (wire.PairingCode, error) {
		if err := d.refuseDevice(c, wire.CallDevicesStartPairing.Name); err != nil {
			return wire.PairingCode{}, err
		}
		return d.startPairing()
	})
	On(d, wire.CallDevicesStopPairing, func(_ context.Context, c *Client, _ wire.Empty) (wire.Empty, error) {
		if err := d.refuseDevice(c, wire.CallDevicesStopPairing.Name); err != nil {
			return wire.Empty{}, err
		}
		d.devMu.Lock()
		d.endPairing()
		d.devMu.Unlock()
		return wire.Empty{}, nil
	})
	On(d, wire.CallPairingCurrent, func(_ context.Context, c *Client, _ wire.Empty) (wire.PairingSecret, error) {
		if err := d.refuseDevice(c, wire.CallPairingCurrent.Name); err != nil {
			return wire.PairingSecret{}, err
		}
		return d.currentPairing(), nil
	})
	On(d, wire.CallRelayRegister, func(_ context.Context, c *Client, r wire.RelayRegistration) (wire.Empty, error) {
		if err := d.refuseDevice(c, wire.CallRelayRegister.Name); err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, d.registerRelayKey(r.PublicKey)
	})
}
