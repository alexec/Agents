package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func startDevices(t *testing.T) (*Daemon, *conn) {
	d, c := start(t, t.TempDir())
	d.serveDevices()
	return d, c
}

func announcement(id string, key byte) map[string]any {
	return map[string]any{"id": id, "publicKey": []byte{key, key}, "name": "Phone", "kind": "iPhone"}
}

const phone = "11111111-2222-3333-4444-555555555555"

func TestABoundConnectionSpeaksForOneDevice(t *testing.T) {
	d, mac := startDevices(t)
	// The Mac's window puts the phone on record; the phone's own connection then speaks as it.
	mac.call(t, 4, "devices/announce", announcement(phone, 1))
	p := newConn()
	go d.Accept(p)
	t.Cleanup(func() { close(p.in) })
	p.call(t, 1, "connection/bindDevice", map[string]any{})
	var reply wire.AnnounceReply
	json.Unmarshal(p.call(t, 3, "devices/announce", announcement(phone, 1)), &reply)
	if string(reply.Device.ID) != phone {
		t.Fatalf("reply: %+v", reply)
	}

	// A device's connection may not name another, nor a new key under its id.
	if e := p.callError(t, 4, "devices/announce", announcement("99999999-2222-3333-4444-555555555555", 1)); e.Code != wire.FailureNotPermitted {
		t.Fatalf("another id: %+v", e)
	}
	if e := mac.callError(t, 7, "devices/announce", announcement(phone, 2)); e.Code != wire.FailureNotSupported {
		t.Fatalf("a new key: %+v", e)
	}
	// An unknown device's own connection is refused.
	q := newConn()
	go d.Accept(q)
	t.Cleanup(func() { close(q.in) })
	q.call(t, 1, "connection/bindDevice", map[string]any{})
	if e := q.callError(t, 2, "devices/announce", announcement("77777777-2222-3333-4444-555555555555", 3)); e.Code != wire.FailureNotAllowed {
		t.Fatalf("unpaired: %+v", e)
	}
	if e := q.callError(t, 3, "devices/forget", map[string]any{"id": phone}); e.Code != wire.FailureNotAllowed {
		t.Fatalf("a phone forgot: %+v", e)
	}

	b, _ := os.ReadFile(filepath.Join(d.Store.Loc.Root, "devices.json"))
	if !strings.Contains(string(b), `"name":"Phone"`) {
		t.Fatalf("devices.json: %s", b)
	}
	mac.call(t, 8, "devices/forget", map[string]any{"id": phone})
	var list []wire.Device
	json.Unmarshal(mac.call(t, 9, "devices/list", nil), &list)
	if len(list) != 0 {
		t.Fatalf("after forget: %+v", list)
	}
}

func TestDevicesKeepWhatALaterBuildWrote(t *testing.T) {
	d, mac := startDevices(t)
	os.WriteFile(filepath.Join(d.Store.Loc.Root, "devices.json"),
		[]byte(`[{"id":"`+phone+`","publicKey":"AQE=","name":"Old","kind":"iPad","announcedAt":1,"wants":["x"]},{"id":"bad"},"nope"]`), 0o644)
	mac.call(t, 1, "devices/announce", announcement(phone, 1))
	b, _ := os.ReadFile(filepath.Join(d.Store.Loc.Root, "devices.json"))
	if !strings.Contains(string(b), `"wants":["x"]`) || !strings.Contains(string(b), `"name":"Phone"`) {
		t.Fatalf("devices.json: %s", b)
	}
}
