package controllink

import (
	"encoding/json"
	"testing"
)

// What the control plane tells a host on channel 0 reaches Told; a reply to an Ask, and
// a request, do not (#1118).
func TestChannelZeroNotificationsAreTold(t *testing.T) {
	var heard []string
	u := &Uplink{Told: func(method string, params json.RawMessage) { heard = append(heard, method+" "+string(params)) }}
	u.message(0, `{"jsonrpc":"2.0","method":"machine/clients","params":{"clients":[]}}`)
	u.message(0, `{"jsonrpc":"2.0","id":3,"method":"git/fill","params":{}}`)
	u.message(0, `{"jsonrpc":"2.0","id":4,"result":{}}`)
	if len(heard) != 1 || heard[0] != `machine/clients {"clients":[]}` {
		t.Fatal(heard)
	}
}
