package hosted

import (
	"bytes"
	"context"
	"encoding/base64"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/webpush"
)

// serviceKey is a VAPID key that sends nothing.
type serviceKey struct{}

func (serviceKey) Send(context.Context, webpush.Push) error { return nil }
func (serviceKey) PublicKey() string                        { return "BVAPIDKEY" }

// Every account's control plane sends Web Push with the service's one VAPID key (#3515),
// and none with no key.
func TestEachCopySendsWebPushWithTheServiceKey(t *testing.T) {
	keeper := "base64key://" + base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	key := &serviceKey{}
	for _, tc := range []struct {
		name string
		cfg  Config
	}{
		{"a key", Config{WebPush: key}},
		{"no key", Config{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := tc.cfg
			cfg.Store, cfg.Keeper, cfg.Domain, cfg.MaxCopies = store.NewMemory(), keeper, domain, 10
			s, err := New(context.Background(), cfg)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(s.Stop)
			for i := range 2 {
				acc, _, err := s.accounts.make(context.Background(), gitHubSignIn(int64(2000+i), "user"))
				if err != nil {
					t.Fatal(err)
				}
				// It starts with the key, and answers.
				open(t, s, acc.ID)
				got := s.copyConfig(acc.ID, nil, nil, &agentsCap{}).WebPush
				if tc.cfg.WebPush == nil && got != nil {
					t.Fatalf("%s: a copy has a Web Push key with none on the service", acc.ID)
				}
				if tc.cfg.WebPush != nil && got != key {
					t.Fatalf("%s: its Web Push is %v, want the service's key", acc.ID, got)
				}
			}
		})
	}
}
