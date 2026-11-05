package whatsappmcp

import (
	"errors"
	"regexp"
	"strings"
)

// The account (#1352): one WhatsApp Business phone number on Meta's Cloud API. The server
// posts as that number with the access token, and hears what people send it by Meta's
// webhook, which it serves itself: the Cloud API has no pull and no socket, so the webhook
// needs a public HTTPS address in front of it (a tunnel, or the machine's reverse proxy).
// Every webhook call is signed with the Meta app's secret, and the server takes only a call
// whose signature it can check, so nobody else can fake a sender.

// Provider is the channel's name in a sender (#1762): its links are kept under it.
const Provider = "whatsapp"

// DefaultAddr is where the webhook listens when WHATSAPP_WEBHOOK_ADDR is not set: this machine
// only, for a tunnel to reach.
const DefaultAddr = "127.0.0.1:8797"

// DefaultAPIURL is the Graph API, at a version Meta keeps for two years from its release.
const DefaultAPIURL = "https://graph.facebook.com/v24.0"

// ErrNotConnected says how to connect when a value is missing.
var ErrNotConnected = errors.New("WhatsApp is not connected: set WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_APP_SECRET and " +
	"WHATSAPP_VERIFY_TOKEN in Settings ▸ Secrets; see docs/how-to/use-whatsapp.md")

// notConnected is ErrNotConnected that names only the values that are missing.
type notConnected string

func (e notConnected) Error() string        { return string(e) }
func (e notConnected) Is(target error) bool { return target == ErrNotConnected }

// Account is what the server signs in and checks the webhook with.
type Account struct {
	// Token is the access token: a system user's, which does not expire.
	Token string
	// PhoneNumberID is the business phone number's id (not the number itself).
	PhoneNumberID string
	// AppSecret signs each webhook call (X-Hub-Signature-256).
	AppSecret string
	// VerifyToken is the word Meta sends back when the webhook is set up.
	VerifyToken string
	// Addr is where the webhook listens.
	Addr string
	// APIURL is the Graph API, with its version: a fake on this machine in tests.
	APIURL string
}

var phoneNumberIDRule = regexp.MustCompile(`^[0-9]{5,32}$`)

// AccountFrom reads the account from the environment's values: WHATSAPP_TOKEN,
// WHATSAPP_PHONE_NUMBER_ID, WHATSAPP_APP_SECRET and WHATSAPP_VERIFY_TOKEN, all required;
// WHATSAPP_WEBHOOK_ADDR (DefaultAddr when empty) and, for a fake, WHATSAPP_API_URL.
func AccountFrom(getenv func(string) string) (Account, error) {
	value := func(name string) string { return strings.TrimSpace(getenv(name)) }
	a := Account{Token: value("WHATSAPP_TOKEN"), PhoneNumberID: value("WHATSAPP_PHONE_NUMBER_ID"), AppSecret: value("WHATSAPP_APP_SECRET"),
		VerifyToken: value("WHATSAPP_VERIFY_TOKEN"), Addr: value("WHATSAPP_WEBHOOK_ADDR"), APIURL: strings.TrimRight(value("WHATSAPP_API_URL"), "/")}
	missing := []string{}
	for _, v := range []struct{ name, value string }{{"WHATSAPP_TOKEN", a.Token}, {"WHATSAPP_PHONE_NUMBER_ID", a.PhoneNumberID},
		{"WHATSAPP_APP_SECRET", a.AppSecret}, {"WHATSAPP_VERIFY_TOKEN", a.VerifyToken}} {
		if v.value == "" {
			missing = append(missing, v.name)
		}
	}
	if len(missing) == 4 {
		return Account{}, ErrNotConnected
	}
	if len(missing) > 0 {
		return Account{}, notConnected("WhatsApp is not connected: set " + strings.Join(missing, " and ") + " in Settings ▸ Secrets; see docs/how-to/use-whatsapp.md")
	}
	if !phoneNumberIDRule.MatchString(a.PhoneNumberID) {
		return Account{}, errors.New("WHATSAPP_PHONE_NUMBER_ID is the phone number's id from the app's WhatsApp ▸ API Setup page, all digits, not the number itself")
	}
	if a.Addr == "" {
		a.Addr = DefaultAddr
	}
	if a.APIURL == "" {
		a.APIURL = DefaultAPIURL
	}
	return a, nil
}
