package main

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/hosted"
)

// The admin verbs (#2152) reach the hosted package, and a wrong one says how to use it.
func TestAdminVerbs(t *testing.T) {
	a := hosted.Admin{Store: store.NewMemory(), Domain: "hosted.test"}
	ctx := context.Background()
	var out bytes.Buffer
	if err := runAdmin(ctx, a, []string{"invite", "3"}, &out); err != nil || !strings.HasPrefix(out.String(), "https://hosted.test/?invite=") {
		t.Fatal(out.String(), err)
	}
	for _, args := range [][]string{{"allow", "ana"}, {"admit", "bo"}, {"disallow", "bo"}, {"waitlist"}, {"accounts"}, {"unblock", "7"}} {
		if err := runAdmin(ctx, a, args, &out); err != nil {
			t.Fatal(args, err)
		}
	}
	for _, args := range [][]string{{"nothing"}, {"allow"}, {"suspend", "abcdefghij"}, {"unblock", "x"}, {"invite", "-1"}} {
		if err := runAdmin(ctx, a, args, &out); !errors.Is(err, errUsage) {
			t.Fatal(args, err)
		}
	}
	if err := runAdmin(ctx, a, []string{"suspend", "abcdefghij", "spam"}, &out); err == nil || errors.Is(err, errUsage) {
		t.Fatal("suspended an account that is not there:", err)
	}
	if err := runAdmin(ctx, a, []string{"block", "nobody-known"}, &out); err == nil {
		t.Fatal("blocked a login nobody has")
	}
}
