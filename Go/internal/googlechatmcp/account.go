package googlechatmcp

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// The account (#1016): one Google Chat app, in a Google Cloud project, with its Pub/Sub
// connection. The app's service account signs in to both Pub/Sub (to pull the app's events)
// and the Chat API (to post as the app), so one key is the only secret. Pub/Sub is pulled,
// so nothing on the machine needs a public address; a webhook would need one.

// Provider is the channel's name in a sender (#1762): its links are kept under it.
const Provider = "googlechat"

// DefaultSubscription is the subscription's name when GOOGLE_CHAT_SUBSCRIPTION is not set:
// in the key's own project.
const DefaultSubscription = "agents-chat"

// ErrNotConnected says how to connect when no key is set.
var ErrNotConnected = errors.New("Google Chat is not connected: set GOOGLE_CHAT_CREDENTIALS to the Chat app's service account key " +
	"(its JSON, or the path of its file) in Settings ▸ Secrets; see docs/how-to/use-google-chat.md")

// Account is what the server signs in with.
type Account struct {
	// Credentials is the service account key, as JSON.
	Credentials []byte
	// Subscription is the Pub/Sub subscription to pull: projects/<project>/subscriptions/<name>.
	Subscription string
	// ChatURL and PubSubURL, when set, are where the APIs are (a fake on this machine);
	// the server then sends no credentials.
	ChatURL, PubSubURL string
}

var subscriptionRule = regexp.MustCompile(`^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/subscriptions/[A-Za-z][A-Za-z0-9._~+%-]{2,254}$`)
var shortSubscription = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9._~+%-]{2,254}$`)

// AccountFrom reads the account from the environment's values: GOOGLE_CHAT_CREDENTIALS (the
// key's JSON, or the path of its file), GOOGLE_CHAT_SUBSCRIPTION (a full name, or a name in
// the key's project; DefaultSubscription when empty), and, for a fake, GOOGLE_CHAT_API_URL and
// GOOGLE_CHAT_PUBSUB_URL.
func AccountFrom(getenv func(string) string) (Account, error) {
	a := Account{ChatURL: strings.TrimSpace(getenv("GOOGLE_CHAT_API_URL")), PubSubURL: strings.TrimSpace(getenv("GOOGLE_CHAT_PUBSUB_URL"))}
	raw := strings.TrimSpace(getenv("GOOGLE_CHAT_CREDENTIALS"))
	project := ""
	switch {
	case raw == "" && a.ChatURL != "" && a.PubSubURL != "":
		project = "agents-fake"
	case raw == "":
		return Account{}, ErrNotConnected
	default:
		if !strings.HasPrefix(raw, "{") {
			data, err := os.ReadFile(raw)
			if err != nil {
				return Account{}, fmt.Errorf("GOOGLE_CHAT_CREDENTIALS is neither a key's JSON nor a file that can be read: %w", err)
			}
			raw = strings.TrimSpace(string(data))
		}
		var key struct {
			Type        string `json:"type"`
			ProjectID   string `json:"project_id"`
			ClientEmail string `json:"client_email"`
		}
		if err := json.Unmarshal([]byte(raw), &key); err != nil || key.Type != "service_account" || key.ClientEmail == "" {
			return Account{}, errors.New("GOOGLE_CHAT_CREDENTIALS is not a service account key: download a JSON key for the Chat app's service account")
		}
		a.Credentials = []byte(raw)
		project = key.ProjectID
	}
	sub := strings.TrimSpace(getenv("GOOGLE_CHAT_SUBSCRIPTION"))
	if sub == "" {
		sub = DefaultSubscription
	}
	if shortSubscription.MatchString(sub) {
		if project == "" {
			return Account{}, errors.New("the key names no project: set GOOGLE_CHAT_SUBSCRIPTION to projects/<project>/subscriptions/<name>")
		}
		sub = "projects/" + project + "/subscriptions/" + sub
	}
	if !subscriptionRule.MatchString(sub) {
		return Account{}, fmt.Errorf("GOOGLE_CHAT_SUBSCRIPTION %q is not projects/<project>/subscriptions/<name>", sub)
	}
	a.Subscription = sub
	return a, nil
}
