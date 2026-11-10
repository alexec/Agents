package controlplane

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/notices"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// A need the person's booking's holder asked (#4268) goes out timely: the desk keeps the
// word, Web Push wakes the browser now, and APNs says Time Sensitive.
func TestATimelyNeedGoesOutTimely(t *testing.T) {
	t.Parallel()
	id := wire.UUID("E0000000-0000-4000-8000-000000000005")
	agent := wire.UUID("A0000000-0000-4000-8000-000000000001")
	now := time.Now()
	need := wire.Need{ID: wire.NeedID{Permission: &id}, AgentID: &agent, Kind: wire.NeedKindPermission,
		RaisedAt: wire.DateOf(now.Add(-time.Minute)), Headline: wire.Headline{H1: "Agents", H2: "Sign in", H3: "Type the code"}, Timely: new(true)}
	phone := notices.Device{ID: "D0000000-0000-4000-8000-000000000001", Kind: notices.IPhone, LastSeen: now, MayNotify: new(true)}
	out := notices.NewDesk().Heard(notices.AttentionNeed{Need: &need}, nil, []notices.Device{phone}, now)
	if len(out) != 1 || out[0].Timely == nil || !*out[0].Timely {
		t.Fatalf("%+v", out)
	}
	quiet := out[0]
	quiet.Alert = false
	push, err := webPushFor(quiet, records.WebPushSubscription{Endpoint: webPushEndpoint})
	if err != nil {
		t.Fatal(err)
	}
	var item wire.ControlPushItem
	json.Unmarshal(push.Payload, &item)
	if !push.Urgent || item.Timely == nil || !*item.Timely {
		t.Fatalf("%+v %+v", push, item)
	}
	if body := string((apns.Push{Alert: true, Timely: true}).Payload()); !strings.Contains(body, `"interruption-level":"time-sensitive"`) {
		t.Fatal(body)
	}
	if body := string((apns.Push{Alert: true}).Payload()); strings.Contains(body, "interruption-level") {
		t.Fatal(body)
	}
}
