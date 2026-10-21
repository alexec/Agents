package workspacecommands

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// GoogleSecret is the secret a Google Cloud request reads (#1346): a service account's
// whole JSON key.
const GoogleSecret = "GOOGLE_SERVICE_ACCOUNT_KEY"

// GoogleAuth is how a request to Google Cloud is authorised: an OAuth access token for the
// scope, which the service account's key gets by a signed JWT (RFC 7523), kept until just
// before it ends.
type GoogleAuth struct {
	Scope string
}

// serviceAccount is what a key gives: who it is, its private key, and where tokens come from.
type serviceAccount struct {
	Email    string `json:"client_email"`
	Key      string `json:"private_key"`
	TokenURI string `json:"token_uri"`
}

// googleTokens keeps each account's token per scope.
type googleTokens struct {
	mu   sync.Mutex
	kept map[string]googleToken
}

type googleToken struct {
	value string
	until time.Time
}

// token is an access token for the key and scope: the one kept, or a new one.
func (p *Provider) googleToken(key string, scope string, deadline time.Duration) (string, error) {
	var account serviceAccount
	if err := json.Unmarshal([]byte(key), &account); err != nil || account.Email == "" || account.Key == "" {
		return "", Failure{Reason: "Its " + GoogleSecret + " secret isn't a service account's JSON key."}
	}
	if account.TokenURI == "" {
		account.TokenURI = "https://oauth2.googleapis.com/token"
	}
	parsed, err := url.Parse(account.TokenURI)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return "", Failure{Reason: "Its service account key's token_uri isn't a web address."}
	}
	id := account.Email + " " + scope
	p.google.mu.Lock()
	if kept, ok := p.google.kept[id]; ok && time.Now().Before(kept.until) {
		p.google.mu.Unlock()
		return kept.value, nil
	}
	p.google.mu.Unlock()
	assertion, err := googleJWT(account, scope, time.Now())
	if err != nil {
		return "", Failure{Reason: "Its service account key can't sign: " + err.Error()}
	}
	form := url.Values{"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"}, "assertion": {assertion}}
	request, err := http.NewRequest(http.MethodPost, account.TokenURI, strings.NewReader(form.Encode()))
	if err != nil {
		return "", Failure{Reason: "Its service account key's token_uri can't be asked."}
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	fetch := p.Fetch
	if fetch == nil {
		fetch = Fetch
	}
	status, _, answer, err := fetch(request, deadline)
	if err != nil {
		return "", Failure{Reason: "It can't get a token: " + parsed.Host + " can't be reached."}
	}
	if status < 200 || status > 299 {
		var said struct {
			Error       string `json:"error"`
			Description string `json:"error_description"`
		}
		_ = json.Unmarshal(answer, &said)
		words := strings.TrimSpace(said.Error + ": " + said.Description)
		if said.Error == "" {
			words = http.StatusText(status)
		}
		return "", Failure{Reason: "It can't get a token: " + parsed.Host + " answered " + words}
	}
	var got struct {
		Token   string `json:"access_token"`
		Expires int    `json:"expires_in"`
	}
	if json.Unmarshal(answer, &got) != nil || got.Token == "" {
		return "", Failure{Reason: "It can't get a token: " + parsed.Host + " gave none."}
	}
	life := time.Duration(got.Expires) * time.Second
	if life <= 0 {
		life = time.Hour
	}
	p.google.mu.Lock()
	if p.google.kept == nil {
		p.google.kept = map[string]googleToken{}
	}
	p.google.kept[id] = googleToken{value: got.Token, until: time.Now().Add(life - time.Minute)}
	p.google.mu.Unlock()
	return got.Token, nil
}

// googleJWT is the signed assertion a service account trades for a token: RS256 over
// {iss, scope, aud, iat, exp}, for an hour.
func googleJWT(account serviceAccount, scope string, now time.Time) (string, error) {
	block, _ := pem.Decode([]byte(account.Key))
	if block == nil {
		return "", errString("its private_key isn't PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		if rsaKey, err1 := x509.ParsePKCS1PrivateKey(block.Bytes); err1 == nil {
			parsed = rsaKey
		} else {
			return "", errString("its private_key isn't an RSA key")
		}
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return "", errString("its private_key isn't an RSA key")
	}
	encode := func(v any) string {
		data, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(data)
	}
	unsigned := encode(map[string]string{"alg": "RS256", "typ": "JWT"}) + "." + encode(map[string]any{
		"iss": account.Email, "scope": scope, "aud": account.TokenURI,
		"iat": now.Unix(), "exp": now.Add(time.Hour).Unix()})
	digest := sha256.Sum256([]byte(unsigned))
	signature, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

type errString string

func (e errString) Error() string { return string(e) }
