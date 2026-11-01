package store

import (
	"context"
	"strings"
)

// Prefixed is a store inside another, under a prefix (#1807): one organisation's records
// in a shared store, as direction.md's tenancy has it. Its keys are the same as any
// store's (v1/…); only the inner store sees the prefix. Nothing outside the prefix is
// read or written through it.
type Prefixed struct {
	Inner  Store
	prefix string
}

// NewPrefixed is the part of inner under prefix, which ends with a slash ("accounts/x/").
func NewPrefixed(inner Store, prefix string) *Prefixed {
	if prefix != "" && !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return &Prefixed{Inner: inner, prefix: prefix}
}

// Prefix is where it is in the inner store.
func (p *Prefixed) Prefix() string { return p.prefix }

func (p *Prefixed) Get(ctx context.Context, key string) (*Object, error) {
	return p.Inner.Get(ctx, p.prefix+key)
}

func (p *Prefixed) Put(ctx context.Context, key string, data []byte, when Condition) (string, error) {
	return p.Inner.Put(ctx, p.prefix+key, data, when)
}

func (p *Prefixed) Delete(ctx context.Context, key string) error {
	return p.Inner.Delete(ctx, p.prefix+key)
}

func (p *Prefixed) List(ctx context.Context, prefix string) ([]Key, error) {
	keys, err := p.Inner.List(ctx, p.prefix+prefix)
	if err != nil {
		return nil, err
	}
	out := make([]Key, 0, len(keys))
	for _, k := range keys {
		out = append(out, Key{Key: strings.TrimPrefix(k.Key, p.prefix), ETag: k.ETag, Size: k.Size})
	}
	return out, nil
}

// DeleteAll deletes every object in s, and says how many went: an organisation's whole
// store, when its account is deleted (#1807).
func DeleteAll(ctx context.Context, s Store) (int, error) {
	keys, err := s.List(ctx, "")
	if err != nil {
		return 0, err
	}
	for i, k := range keys {
		if err := s.Delete(ctx, k.Key); err != nil {
			return i, err
		}
	}
	return len(keys), nil
}
