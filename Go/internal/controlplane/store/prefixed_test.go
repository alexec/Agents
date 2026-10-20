package store

import (
	"context"
	"testing"
)

// #1807: two organisations in one store see only their own keys, and deleting one leaves
// the other whole.
func TestAPrefixKeepsOrganisationsApart(t *testing.T) {
	ctx := context.Background()
	inner := NewMemory()
	a, b := NewPrefixed(inner, "accounts/a"), NewPrefixed(inner, "accounts/b/")
	for _, s := range []Store{a, b} {
		if _, err := s.Put(ctx, "v1/control.json", []byte("{}"), Absent); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := a.Put(ctx, "v1/clients/x.json", []byte("{}"), Absent); err != nil {
		t.Fatal(err)
	}
	listed, err := a.List(ctx, "v1/")
	if err != nil || len(listed) != 2 || listed[0].Key != "v1/clients/x.json" {
		t.Fatalf("%+v %v", listed, err)
	}
	if o, _ := b.Get(ctx, "v1/clients/x.json"); o != nil {
		t.Fatal("b read a's client")
	}
	if n, err := DeleteAll(ctx, a); err != nil || n != 2 {
		t.Fatalf("%d %v", n, err)
	}
	all, _ := inner.List(ctx, "")
	if len(all) != 1 || all[0].Key != "accounts/b/v1/control.json" {
		t.Fatalf("%+v", all)
	}
}
