package signin

import (
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"os"
	"strings"
	"time"
)

// The app's own client ids (FR-012): every control plane trusts sign-ins made for them,
// and its operator registers nothing. Apple is on (#2507); Google and GitHub are empty
// until Alex makes the Google OAuth client and the GitHub App (#995, "What Alex does"); a
// provider with no client id is offered as not available. AGENTS_SIGNIN_* set them for a build or a
// control plane before then.
var (
	// AppGoogleClientIDs are the Google OAuth clients (iOS type) the Mac and the Remote sign
	// in with; the first is the one a client is given.
	AppGoogleClientIDs []string
	// AppAppleAudiences are the bundle ids a native Sign in with Apple names as aud, and the
	// Services id.
	AppAppleAudiences = []string{"com.alexecollins.agents.store", "com.alexecollins.agents.remote"}
	// AppAppleEnabled says the app has the Sign in with Apple capability: on the two App
	// IDs and in the entitlements since #2507. The web pairs from a code, so there is no
	// Services id.
	AppAppleEnabled = true
	// AppGitHubClientID is the GitHub App's client id, for the device flow.
	AppGitHubClientID = ""
)

// Config is which providers this control plane can check, and where it asks them.
type Config struct {
	GoogleClientIDs []string
	AppleAudiences  []string
	// AppleEnabled says Apple sign-in can be turned on.
	AppleEnabled   bool
	GitHubClientID string
	// Where the providers are asked; "" is the real one (tests give fakes).
	GoogleJWKS string
	AppleJWKS  string
	GitHubAPI  string
	HTTP       *http.Client
}

// FromEnvironment is the app's ids, with AGENTS_SIGNIN_GOOGLE_CLIENT_IDS,
// AGENTS_SIGNIN_APPLE_AUDIENCES (which also turns Apple on) and
// AGENTS_SIGNIN_GITHUB_CLIENT_ID over them when set.
func FromEnvironment() Config {
	c := Config{GoogleClientIDs: AppGoogleClientIDs, AppleAudiences: AppAppleAudiences, AppleEnabled: AppAppleEnabled,
		GitHubClientID: AppGitHubClientID}
	if ids := list(os.Getenv("AGENTS_SIGNIN_GOOGLE_CLIENT_IDS")); len(ids) > 0 {
		c.GoogleClientIDs = ids
	}
	if ids := list(os.Getenv("AGENTS_SIGNIN_APPLE_AUDIENCES")); len(ids) > 0 {
		c.AppleAudiences, c.AppleEnabled = ids, true
	}
	if id := strings.TrimSpace(os.Getenv("AGENTS_SIGNIN_GITHUB_CLIENT_ID")); id != "" {
		c.GitHubClientID = id
	}
	// A walk's stand-in for an organisation's provider (#1002, signintest): its
	// certificate, PEM, is trusted beside the system's, as AGENTS_TEST_APNS_URL's is.
	if pem := strings.TrimSpace(os.Getenv("AGENTS_TEST_TRUST_ROOT")); strings.Contains(pem, "-----BEGIN") {
		pool, err := x509.SystemCertPool()
		if err != nil {
			pool = x509.NewCertPool()
		}
		if pool.AppendCertsFromPEM([]byte(pem)) {
			c.HTTP = &http.Client{Timeout: 10 * time.Second, Transport: &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}}}
		}
	}
	return c
}

func list(s string) []string {
	out := []string{}
	for _, part := range strings.Split(s, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

// Available says a provider can be turned on, and if not, why.
func (c Config) Available(provider string) (bool, string) {
	switch provider {
	case Google:
		if len(c.GoogleClientIDs) == 0 {
			return false, "This build has no Google client id yet."
		}
	case Apple:
		if !c.AppleEnabled || len(c.AppleAudiences) == 0 {
			return false, "This build has no Sign in with Apple id yet."
		}
	case GitHub:
		if c.GitHubClientID == "" {
			return false, "This build has no GitHub App yet."
		}
	default:
		return false, "There is no such sign-in provider."
	}
	return true, ""
}

// ClientID is what a client signs in with for a provider: Google's client id, the GitHub
// App's, or Apple's first audience (a native sign-in needs none).
func (c Config) ClientID(provider string) string {
	switch provider {
	case Google:
		if len(c.GoogleClientIDs) > 0 {
			return c.GoogleClientIDs[0]
		}
	case GitHub:
		return c.GitHubClientID
	}
	return ""
}

// OIDCFor is the checker of an OIDC provider, asking where the config says.
func (c Config) OIDCFor(provider string) *OIDC {
	var o *OIDC
	switch provider {
	case Google:
		o = GoogleOIDC(c.GoogleClientIDs)
		if c.GoogleJWKS != "" {
			o.JWKSURL = c.GoogleJWKS
		}
	case Apple:
		o = AppleOIDC(c.AppleAudiences)
		if c.AppleJWKS != "" {
			o.JWKSURL = c.AppleJWKS
		}
	default:
		return nil
	}
	o.HTTP = c.HTTP
	return o
}

// GitHubFor is the GitHub API checker.
func (c Config) GitHubFor() *GitHubAPI { return &GitHubAPI{Base: c.GitHubAPI, HTTP: c.HTTP} }

// Providers is every built-in provider, in the order the screen lists them.
var Providers = []string{Apple, Google, GitHub}
