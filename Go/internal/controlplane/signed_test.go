package controlplane

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/machinelock"
	"github.com/agentloops-dev/agents/Go/wire"
)

// #3492: a request its sender signed goes to the machine with its params and signature as
// they came, not a byte changed (Go's own encoder would write "<" as "<").
func TestASignedRequestGoesAsItCame(t *testing.T) {
	params := `{"text":"<b>héllo</b> & more", "n":1.50}`
	key, _ := machinelock.NewKey()
	sig, err := machinelock.SignRequest(key, "h-1", "agents/prompt", []byte(params), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	line := signedRequest("kept-1", wire.LockDelivery{Method: "agents/prompt", Params: params, Lock: sig})
	if !strings.Contains(line, `"params":`+params+`,"lock":`) {
		t.Fatalf("the params changed: %s", line)
	}
	var m message
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatal(err)
	}
	got, ok := machinelock.SignatureOf(m.Lock)
	if !ok || string(m.Params) != params || m.Method != "agents/prompt" {
		t.Fatalf("%s", line)
	}
	if !machinelock.VerifyData(got.Key, machinelock.RequestData("h-1", got.At, m.Method, m.Params), got.Sig) {
		t.Fatal("the signature does not check on the other side")
	}
}
