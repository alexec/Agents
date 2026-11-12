package agentsd

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"log"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machinelock"
	"github.com/alexec/agents/Go/wire"
)

// An event's data on the bus (#4825, spec 4724-event-bus, "What the control plane keeps").
// The control plane must not read data (Alex, 2026-11-11, #4726): it can be a customer's
// words. So the machine that raises an event seals its data with HPKE to each other machine
// of its person's lock, to the sealing key the lock's addMachine names (so a control plane
// cannot put in a key of its own), as the bot's key goes (#3950). Inside each copy is the
// raising machine's key and its signature of the data, so a control plane, which can seal
// to any public key, cannot make data up either: the receiving machine takes it only when a
// machine of its own lock signed it. The associated data names the person, the machine and
// the event, so a copy for another machine or another event does not open.
//
// A machine that joined the lock after the event was sealed has no copy, nor does one with
// no lock, and data over 256 KB is not sealed: each then gets the envelope only, and reads
// the subject's state now.

const (
	// busDataPurpose is HPKE's info an event's data is sealed under.
	busDataPurpose = "com.alexecollins.agents.busdata.v1"
	// busDataMost is the most data an event carries on the bus (spec, "An event").
	busDataMost = 256 << 10
	// busDataKeyBytes and busDataSigBytes are what goes before the data in a copy: the signer's key (P-256, X9.63)
	// and its signature (r||s).
	busDataKeyBytes = 65
	busDataSigBytes = 64
)

// BusDataAD is the associated data of an event's data sealed to one machine of the person.
func BusDataAD(person, host, id string) []byte {
	return fmt.Appendf(nil, "busdata.v1|%s|%s|%s", person, controllink.MachineRecipient(host), id)
}

// busDataSigned is what the raising machine signs: the person, the event and the data.
func busDataSigned(person, id string, data []byte) []byte {
	sum := sha256.Sum256(data)
	return fmt.Appendf(nil, "busdata.v1|%s|%s|%x", person, id, sum)
}

// sealBusData seals data, signed with signer, to each machine in to: none when data is
// empty or too large. A machine with no id or key is left out.
func sealBusData(signer *ecdsa.PrivateKey, person, id string, data []byte, to []machinelock.Member) ([]wire.BusSealedData, error) {
	if len(data) == 0 || len(data) > busDataMost || len(to) == 0 {
		return nil, nil
	}
	sig, err := machinelock.SignData(signer, busDataSigned(person, id, data))
	if err != nil {
		return nil, err
	}
	plain := make([]byte, 0, busDataKeyBytes+busDataSigBytes+len(data))
	plain = append(append(append(plain, machinelock.PublicKey(signer)...), sig...), data...)
	var out []wire.BusSealedData
	for _, m := range to {
		if m.ID == "" || len(m.SealingKey) == 0 {
			continue
		}
		sealed, err := controllink.Seal(m.SealingKey, busDataPurpose, BusDataAD(person, m.ID, id), plain)
		if err != nil {
			return nil, err
		}
		out = append(out, wire.BusSealedData{Machine: m.ID, Sealed: sealed})
	}
	return out, nil
}

// openBusData opens this machine's copy of an event's data, and takes it only when a
// machine of the lock signed it.
func openBusData(state *machinelock.State, private []byte, host, id string, sealed []wire.BusSealedData) (json.RawMessage, error) {
	var own *wire.BusSealedData
	for i := range sealed {
		if sealed[i].Machine == host {
			own = &sealed[i]
			break
		}
	}
	if own == nil {
		return nil, nil
	}
	plain, err := controllink.Open(private, busDataPurpose, BusDataAD(state.Person, host, id), own.Sealed)
	if err != nil {
		return nil, errors.New("it does not open with this machine's key")
	}
	if len(plain) < busDataKeyBytes+busDataSigBytes {
		return nil, errors.New("it is not an event's data")
	}
	key, sig, data := plain[:busDataKeyBytes], plain[busDataKeyBytes:busDataKeyBytes+busDataSigBytes], plain[busDataKeyBytes+busDataSigBytes:]
	if len(data) > busDataMost || !json.Valid(data) {
		return nil, errors.New("it is not an event's data")
	}
	if !machinelock.VerifyData(key, busDataSigned(state.Person, id, data), sig) {
		return nil, errors.New("its signature does not check")
	}
	if m, ok := state.Member(key); !ok || m.Kind != wire.LockEntryKindAddMachine {
		return nil, errors.New("no machine of this lock signed it")
	}
	return json.RawMessage(bytes.Clone(data)), nil
}

// busDataTo is the other machines of this machine's lock, to seal an event's data to, and
// what seals it: none with no lock or no key.
func (d *Daemon) busDataTo() (person string, signer *ecdsa.PrivateKey, to []machinelock.Member) {
	state, pinned := d.heldLock()
	me := d.ownHostID()
	if !pinned || state == nil || me == "" {
		return "", nil, nil
	}
	signer, err := d.machineSigner()
	if err != nil {
		return "", nil, nil
	}
	for _, m := range state.Members(wire.LockEntryKindAddMachine) {
		if m.ID != "" && m.ID != me {
			to = append(to, m)
		}
	}
	return state.Person, signer, to
}

// openBusDelivery is this machine's copy of a delivered event's data, opened: none when it
// has none, or it does not open.
func (d *Daemon) openBusDelivery(e wire.BusEvent) json.RawMessage {
	if len(e.Sealed) == 0 || d.HostKey == nil {
		return nil
	}
	state, pinned := d.heldLock()
	host := d.ownHostID()
	if !pinned || state == nil || host == "" {
		return nil
	}
	private, found, err := d.HostKey.Load()
	if err != nil || !found {
		return nil
	}
	data, err := openBusData(state, private, host, e.ID, e.Sealed)
	if err != nil {
		log.Printf("bus/deliver: the data of %s not taken: %v", e.ID, err)
		return nil
	}
	return data
}
