package controlplane

import (
	"fmt"
	"net/url"

	"github.com/alexec/agents/Go/internal/controlplane/s3store"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// StoreCredentials are a bucket's keys handed over apart from the environment: Agents
// Host's --store-credentials-fd (T058a), as JSON {"accessKey":…,"secretKey":…}.
type StoreCredentials struct {
	AccessKey string `json:"accessKey"`
	SecretKey string `json:"secretKey"`
}

// OpenStore is StoreAddress.open: a store named by its URL (contracts/store.md
// "Configuration"). file:///path is a folder, the default, which needs no account;
// s3://bucket/prefix is a bucket, an option, with its keys given, or from the
// environment or ~/.aws/credentials.
func OpenStore(text string, env func(string) string, given *StoreCredentials) (store.Store, error) {
	u, err := url.Parse(text)
	if err != nil || u.Scheme == "" {
		return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
	}
	switch u.Scheme {
	case "file":
		return store.NewFolder(u.Path), nil
	case "s3":
		location, ok := s3store.ParseLocation(text, env)
		if !ok {
			break
		}
		credentials, ok := s3store.CredentialsFrom(env)
		if given != nil {
			credentials, ok = s3store.Credentials{AccessKey: given.AccessKey, SecretKey: given.SecretKey}, true
		}
		if !ok {
			return nil, fmt.Errorf("no keys for the bucket: AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, ~/.aws/credentials, or --store-credentials-fd")
		}
		return s3store.New(location, credentials, nil), nil
	}
	return nil, fmt.Errorf("%s is not a store: say file:///path or s3://bucket/prefix", text)
}
