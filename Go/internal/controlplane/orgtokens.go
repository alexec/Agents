package controlplane

import (
	"cmp"
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Short-lived tokens for cloud credentials (#999, spec Q1 answer A, FR-007): an AWS access
// key (and a role), a Google service account and an Entra app stay here, sealed. Each
// machine gets a token made from it that ends within an hour, sealed to its key, and a new
// one about 10 minutes before the last one ends. A machine never holds a credential that
// lasts. The calls are small and by hand: AWS STS (SigV4), Google's OAuth JWT grant and
// Entra's client credentials.

const (
	// mostTokenLife is the longest a token sent to a machine lasts.
	mostTokenLife = time.Hour
	// renewTokenBefore is how long before a token ends that a new one is sent.
	renewTokenBefore = 10 * time.Minute
	tokenCallTimeout = 20 * time.Second
	mostTokenAnswer  = 1 << 20
	googleScope      = "https://www.googleapis.com/auth/cloud-platform"
	entraScope       = "https://cognitiveservices.azure.com/.default"
)

// firstTokenRetry and lastTokenRetry bound the wait after a token that was not made:
// 1, 2, 4 … 30 minutes, for every machine together (#2250).
const (
	firstTokenRetry = time.Minute
	lastTokenRetry  = 30 * time.Minute
)

// orgEndpoints are where the token and check calls go. Tests point them at fakes.
type orgEndpoints struct {
	// STS is AWS STS's address for a region.
	STS func(region string) string
	// GoogleToken is Google's OAuth token address.
	GoogleToken string
	// Entra is Entra's token address for a tenant.
	Entra func(tenant string) string
	// Vendor is each vendor's API, for a key's check.
	Vendor map[wire.OrgRouteVendor]string
	Client *http.Client
	Now    func() time.Time
}

var defaultOrgEndpoints = orgEndpoints{
	STS:         func(region string) string { return "https://sts." + region + ".amazonaws.com/" },
	GoogleToken: "https://oauth2.googleapis.com/token",
	Entra: func(tenant string) string {
		return "https://login.microsoftonline.com/" + url.PathEscape(tenant) + "/oauth2/v2.0/token"
	},
	Vendor: map[wire.OrgRouteVendor]string{
		wire.OrgRouteVendorAnthropic: "https://api.anthropic.com",
		wire.OrgRouteVendorOpenai:    "https://api.openai.com",
		wire.OrgRouteVendorXai:       "https://api.x.ai",
	},
	Client: &http.Client{Timeout: tokenCallTimeout},
	Now:    time.Now,
}

func (s *Service) endpoints() *orgEndpoints {
	if s.cfg.orgEndpoints != nil {
		return s.cfg.orgEndpoints
	}
	return &defaultOrgEndpoints
}

// orgToken is a token made for a route's version, its field and when it ends; and, after
// a renewal that failed, how many failed and when the next is tried; and when a machine's
// delivery last asked for it.
type orgToken struct {
	asked    time.Time
	version  int64
	field    string
	value    string
	expires  time.Time
	failures int
	retryAt  time.Time
	err      error
}

// tokenRetry is how long to wait after the nth renewal in a row that failed.
func tokenRetry(failures int) time.Duration {
	wait := firstTokenRetry
	for i := 1; i < failures && wait < lastTokenRetry; i++ {
		wait *= 2
	}
	return min(wait, lastTokenRetry)
}

// tokenField is the field a route's token goes in, or "" for a route sent as it is.
func tokenField(r wire.OrgRoute, values map[string]string) string {
	switch {
	case r.Kind == wire.OrgRouteKindBedrock && values["awsAccessKeyId"] != "":
		return "awsSession"
	case r.Kind == wire.OrgRouteKindVertex:
		return "googleToken"
	case r.Kind == wire.OrgRouteKindAzure && values["entraClientSecret"] != "":
		return "entraToken"
	}
	return ""
}

// routeValuesToSend is what a machine may hold of a route: its plain keys as they are, or
// a cloud credential's token in its place, and when that ends (FR-007).
func (s *Service) routeValuesToSend(ctx context.Context, r wire.OrgRoute, values map[string]string) (map[string]string, time.Time, error) {
	field := tokenField(r, values)
	if field == "" {
		return values, time.Time{}, nil
	}
	s.orgRoutes.making.Lock()
	defer s.orgRoutes.making.Unlock()
	now := s.endpoints().Now()
	s.orgRoutes.mu.Lock()
	t, ok := s.orgRoutes.tokens[r.ID]
	s.orgRoutes.mu.Unlock()
	if ok && (t.version != deref(r.Version) || t.field != field) {
		t = orgToken{}
	}
	t.asked = now
	// After a renewal that failed, nothing is tried until retryAt, whichever machine asks.
	if t.expires.Sub(now) <= renewTokenBefore && !now.Before(t.retryAt) {
		value, expires, err := s.makeToken(ctx, r, values)
		if err == nil {
			t = orgToken{version: deref(r.Version), field: field, value: value, expires: expires}
			s.log(fmt.Sprintf("org route %s: a token made, until %s", r.ID, expires.UTC().Format(time.TimeOnly)))
		} else {
			t.version, t.field, t.err = deref(r.Version), field, err
			t.failures++
			t.retryAt = now.Add(tokenRetry(t.failures))
			s.log(fmt.Sprintf("org route %s: no token made (%v); tried again at %s", r.ID, err, t.retryAt.UTC().Format(time.TimeOnly)))
		}
	}
	s.orgRoutes.mu.Lock()
	if s.orgRoutes.tokens == nil {
		s.orgRoutes.tokens = map[string]orgToken{}
	}
	s.orgRoutes.tokens[r.ID] = t
	s.orgRoutes.mu.Unlock()
	// The last token goes on until it ends, through a renewal that failed.
	if t.value == "" || !t.expires.After(now) {
		return nil, time.Time{}, cmp.Or(t.err, errors.New("no token was made"))
	}
	return map[string]string{t.field: t.value}, t.expires, nil
}

// makeToken makes a route's token with its long-lived credential: never longer than
// mostTokenLife.
func (s *Service) makeToken(ctx context.Context, r wire.OrgRoute, values map[string]string) (string, time.Time, error) {
	ctx, cancel := context.WithTimeout(ctx, tokenCallTimeout)
	defer cancel()
	e := s.endpoints()
	var value string
	var expires time.Time
	var err error
	switch tokenField(r, values) {
	case "awsSession":
		value, expires, err = awsSession(ctx, e, deref(deref(r.Settings).Region), r.ID, values)
	case "googleToken":
		value, expires, err = googleToken(ctx, e, values["serviceAccount"])
	case "entraToken":
		settings := deref(r.Settings)
		value, expires, err = entraToken(ctx, e, deref(settings.Tenant), deref(settings.ClientID), values["entraClientSecret"])
	default:
		return "", time.Time{}, errors.New("this route needs no token")
	}
	if err != nil {
		return "", time.Time{}, err
	}
	if most := e.Now().Add(mostTokenLife); expires.IsZero() || expires.After(most) {
		expires = most
	}
	return value, expires, nil
}

// renewTokensEvery sends a new token to every machine here before its last one ends.
func (s *Service) renewTokensEvery(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case <-t.C:
			if s.tokensEndingSoon() {
				s.resendOrgRoutes()
			}
		}
	}
}

// tokensEndingSoon says a token this copy made ends within renewTokenBefore, and is due a
// renewal: not one that failed until its retryAt. A token that ended and that a resend
// since did not ask for is dropped: no machine here uses its route any more, and it would
// bring a resend every minute for ever (#2431).
func (s *Service) tokensEndingSoon() bool {
	now := s.endpoints().Now()
	s.orgRoutes.mu.Lock()
	defer s.orgRoutes.mu.Unlock()
	resent := s.orgRoutes.resent
	for id, t := range s.orgRoutes.tokens {
		if !t.expires.After(resent) && t.asked.Before(resent) {
			delete(s.orgRoutes.tokens, id)
			continue
		}
		if t.expires.Sub(now) <= renewTokenBefore && !now.Before(t.retryAt) {
			return true
		}
	}
	return false
}

// MARK: AWS STS

// stsAnswer is the part of STS's AssumeRole or GetSessionToken answer read.
type stsAnswer struct {
	Assumed stsCredentials `xml:"AssumeRoleResult>Credentials"`
	Session stsCredentials `xml:"GetSessionTokenResult>Credentials"`
}

type stsCredentials struct {
	AccessKeyID     string `xml:"AccessKeyId"`
	SecretAccessKey string `xml:"SecretAccessKey"`
	SessionToken    string `xml:"SessionToken"`
	Expiration      string `xml:"Expiration"`
}

// awsSession is a session credential from STS: AssumeRole when the route names a role,
// GetSessionToken otherwise. It goes to the machine as JSON.
func awsSession(ctx context.Context, e *orgEndpoints, region, route string, values map[string]string) (string, time.Time, error) {
	form := url.Values{"Version": {"2011-06-15"}, "DurationSeconds": {"3600"}}
	if role := values["awsRoleArn"]; role != "" {
		form.Set("Action", "AssumeRole")
		form.Set("RoleArn", role)
		form.Set("RoleSessionName", "agents-"+route)
		if external := values["externalId"]; external != "" {
			form.Set("ExternalId", external)
		}
	} else {
		form.Set("Action", "GetSessionToken")
	}
	body := []byte(form.Encode())
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.STS(region), strings.NewReader(string(body)))
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded; charset=utf-8")
	signV4(req, body, values["awsAccessKeyId"], values["awsSecretAccessKey"], region, "sts", e.Now())
	raw, err := tokenCall(e, req, "AWS STS")
	if err != nil {
		return "", time.Time{}, err
	}
	var answer stsAnswer
	if err := xml.Unmarshal(raw, &answer); err != nil {
		return "", time.Time{}, errors.New("AWS STS gave no session")
	}
	c := answer.Assumed
	if c.SessionToken == "" {
		c = answer.Session
	}
	if c.SessionToken == "" {
		return "", time.Time{}, errors.New("AWS STS gave no session")
	}
	expires, _ := time.Parse(time.RFC3339, c.Expiration)
	value, err := json.Marshal(map[string]string{"accessKeyId": c.AccessKeyID, "secretAccessKey": c.SecretAccessKey,
		"sessionToken": c.SessionToken})
	return string(value), expires, err
}

// signV4 signs a request with AWS Signature Version 4.
func signV4(req *http.Request, body []byte, accessKey, secretKey, region, service string, now time.Time) {
	now = now.UTC()
	amzDate, day := now.Format("20060102T150405Z"), now.Format("20060102")
	req.Header.Set("X-Amz-Date", amzDate)
	payload := sha256.Sum256(body)
	path := req.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	signed := "content-type;host;x-amz-date"
	canonical := strings.Join([]string{req.Method, path, req.URL.RawQuery,
		"content-type:" + req.Header.Get("Content-Type") + "\nhost:" + req.URL.Host + "\nx-amz-date:" + amzDate + "\n",
		signed, hex.EncodeToString(payload[:])}, "\n")
	scope := day + "/" + region + "/" + service + "/aws4_request"
	hashed := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(hashed[:])
	key := []byte("AWS4" + secretKey)
	for _, part := range []string{day, region, service, "aws4_request"} {
		key = hmacSHA256(key, part)
	}
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+accessKey+"/"+scope+", SignedHeaders="+signed+
		", Signature="+hex.EncodeToString(hmacSHA256(key, toSign)))
}

func hmacSHA256(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

// MARK: Google

// serviceAccount is the part of a service account's JSON key used.
type serviceAccount struct {
	ClientEmail  string `json:"client_email"`
	PrivateKey   string `json:"private_key"`
	PrivateKeyID string `json:"private_key_id"`
	key          *rsa.PrivateKey
}

// parseServiceAccount reads a service account's key, as Google gives it in JSON.
func parseServiceAccount(raw string) (serviceAccount, error) {
	var sa serviceAccount
	if err := json.Unmarshal([]byte(raw), &sa); err != nil {
		return sa, errors.New("it is not JSON")
	}
	if sa.ClientEmail == "" || sa.PrivateKey == "" {
		return sa, errors.New("it has no client_email or private_key")
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return sa, errors.New("its private_key is not PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		if k, err1 := x509.ParsePKCS1PrivateKey(block.Bytes); err1 == nil {
			parsed = k
		} else {
			return sa, errors.New("its private_key is not an RSA key")
		}
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return sa, errors.New("its private_key is not an RSA key")
	}
	sa.key = key
	return sa, nil
}

// googleToken is an OAuth access token for a service account, by the JWT bearer grant.
func googleToken(ctx context.Context, e *orgEndpoints, raw string) (string, time.Time, error) {
	sa, err := parseServiceAccount(raw)
	if err != nil {
		return "", time.Time{}, err
	}
	now := e.Now()
	header := map[string]string{"alg": "RS256", "typ": "JWT"}
	if sa.PrivateKeyID != "" {
		header["kid"] = sa.PrivateKeyID
	}
	claims := map[string]any{"iss": sa.ClientEmail, "scope": googleScope, "aud": e.GoogleToken,
		"iat": now.Unix(), "exp": now.Add(mostTokenLife).Unix()}
	h, _ := json.Marshal(header)
	c, _ := json.Marshal(claims)
	unsigned := base64.RawURLEncoding.EncodeToString(h) + "." + base64.RawURLEncoding.EncodeToString(c)
	digest := sha256.Sum256([]byte(unsigned))
	sig, err := rsa.SignPKCS1v15(rand.Reader, sa.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", time.Time{}, err
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion": {unsigned + "." + base64.RawURLEncoding.EncodeToString(sig)}}
	return oauthToken(ctx, e, e.GoogleToken, form, "Google")
}

// MARK: Entra

// entraToken is an access token for an Entra app, by client credentials.
func entraToken(ctx context.Context, e *orgEndpoints, tenant, client, secret string) (string, time.Time, error) {
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {client}, "client_secret": {secret},
		"scope": {entraScope}}
	return oauthToken(ctx, e, e.Entra(tenant), form, "Microsoft Entra")
}

// oauthToken posts a form to a token address and reads access_token and expires_in.
func oauthToken(ctx context.Context, e *orgEndpoints, address string, form url.Values, who string) (string, time.Time, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, address, strings.NewReader(form.Encode()))
	if err != nil {
		return "", time.Time{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	raw, err := tokenCall(e, req, who)
	if err != nil {
		return "", time.Time{}, err
	}
	var answer struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &answer); err != nil || answer.AccessToken == "" {
		return "", time.Time{}, fmt.Errorf("%s gave no token", who)
	}
	return answer.AccessToken, e.Now().Add(time.Duration(answer.ExpiresIn) * time.Second), nil
}

// tokenCall sends a token request and reads a bounded answer. Its error says the status,
// never the answer's body, which can echo what was sent.
func tokenCall(e *orgEndpoints, req *http.Request, who string) ([]byte, error) {
	resp, err := e.Client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%s could not be reached", who)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, mostTokenAnswer))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("%s refused the credential (%d)", who, resp.StatusCode)
	}
	return raw, nil
}

// MARK: orgRoutes/check

// checkOrgRoute is orgRoutes/check: one small request from the control plane where it
// can make one (a key, a base URL, a cloud credential's token), in words. A route only a
// machine can check says so.
func (s *Service) checkOrgRoute(ctx context.Context, r wire.OrgRoute, values map[string]string) wire.OrgRouteCheck {
	if tokenField(r, values) != "" {
		_, expires, err := s.makeToken(ctx, r, values)
		if err != nil {
			return wire.OrgRouteCheck{Words: err.Error() + "."}
		}
		return wire.OrgRouteCheck{Ok: true, Words: fmt.Sprintf("A token was made with this credential, until %s UTC.",
			expires.UTC().Format("15:04"))}
	}
	e := s.endpoints()
	var address string
	switch r.Kind {
	case wire.OrgRouteKindKey:
		address = e.Vendor[deref(r.Vendor)]
	case wire.OrgRouteKindBaseURL:
		address = deref(deref(r.Settings).Address)
	default:
		return wire.OrgRouteCheck{Words: "This route can be checked only from a machine: start a session on it."}
	}
	models := "/v1/models"
	ctx, cancel := context.WithTimeout(ctx, tokenCallTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(address, "/")+models, nil)
	if err != nil {
		return wire.OrgRouteCheck{Words: "The route's address is not one to call."}
	}
	if key := values["apiKey"]; key != "" {
		header, value := vendorKeyHeader(deref(r.Vendor), key)
		if h := deref(r.Settings).Header; h != nil {
			header, value = *h, key
		}
		req.Header.Set(header, value)
	}
	if deref(r.Vendor) == wire.OrgRouteVendorAnthropic {
		req.Header.Set("anthropic-version", "2023-06-01")
	}
	resp, err := e.Client.Do(req)
	if err != nil {
		return wire.OrgRouteCheck{Words: "The route's address could not be reached from the control plane."}
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, mostTokenAnswer))
	resp.Body.Close()
	switch {
	case resp.StatusCode/100 == 2:
		return wire.OrgRouteCheck{Ok: true, Words: "The provider took the key."}
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return wire.OrgRouteCheck{Words: fmt.Sprintf("The provider refused the key (%d).", resp.StatusCode)}
	}
	return wire.OrgRouteCheck{Words: fmt.Sprintf("The provider answered %d.", resp.StatusCode)}
}

// vendorKeyHeader is the header each vendor takes its key in (research R3).
func vendorKeyHeader(vendor wire.OrgRouteVendor, key string) (string, string) {
	switch vendor {
	case wire.OrgRouteVendorAnthropic:
		return "x-api-key", key
	}
	return "Authorization", "Bearer " + key
}
