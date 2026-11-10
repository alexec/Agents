package controllink

import (
	"context"
	"encoding/json"
	"slices"
	"strconv"
	"testing"
	"time"
)

// The uplink keeps what the control plane answers machine/hello with (#4100): its list, or an
// empty one from a control plane older than the answer; nil until it answers.
func TestHelloKeepsTheControlPlanesCapabilities(t *testing.T) {
	for _, tc := range []struct {
		result string
		want   []string
	}{
		{`{"capabilities":["machine.accounts/1","user/3"]}`, []string{"machine.accounts/1", "user/3"}},
		{`{}`, []string{}},
	} {
		u := &Uplink{}
		u.out = &sender{out: make(chan string, 1), done: make(chan struct{})}
		u.hello(context.Background(), MachineHello{Version: "1"})
		if u.ControlCapabilities() != nil {
			t.Fatal("a list before the control plane answered")
		}
		var frame struct {
			C int `json:"c"`
			M struct {
				ID     int64  `json:"id"`
				Method string `json:"method"`
			} `json:"m"`
		}
		if err := json.Unmarshal([]byte(<-u.out.out), &frame); err != nil || frame.C != 0 || frame.M.Method != "machine/hello" {
			t.Fatalf("first line %+v, %v", frame, err)
		}
		u.message(0, `{"jsonrpc":"2.0","id":`+strconv.FormatInt(frame.M.ID, 10)+`,"result":`+tc.result+`}`)
		deadline := time.Now().Add(5 * time.Second)
		for u.ControlCapabilities() == nil && time.Now().Before(deadline) {
			time.Sleep(5 * time.Millisecond)
		}
		if got := u.ControlCapabilities(); got == nil || !slices.Equal(got, tc.want) {
			t.Fatalf("%s: kept %v", tc.result, got)
		}
	}
}
