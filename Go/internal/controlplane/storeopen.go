package controlplane

import (
	"fmt"
	"net/url"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// OpenStore is StoreAddress.open: a store named by its URL (contracts/store.md
// "Configuration"). file:///path is a folder, the default, which needs no account.
func OpenStore(text string, env func(string) string) (store.Store, error) {
	u, err := url.Parse(text)
	if err != nil || u.Scheme == "" {
		return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
	}
	switch u.Scheme {
	case "file":
		return store.NewFolder(u.Path), nil
	}
	return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
}
