package hosted

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// A session is a signed cookie: the account and when it ends, with an HMAC under the
// service's session key. Nothing about a session is kept on the server. The sign-in's
// state is a second, short cookie, so a callback answers only the browser that left.

const (
	sessionCookie = "agents_session"
	stateCookie   = "agents_signin"
	// An invite link's code, signed, from /signin to the callback (#2152).
	inviteCookie = "agents_invite"
	sessionLife  = 30 * 24 * time.Hour
	stateLife    = 10 * time.Minute
)

type sessions struct {
	key []byte
	now func() time.Time
}

func (s sessions) sign(text string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte(text))
	return text + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

// open is the text a signed value holds, when its signature is this service's.
func (s sessions) open(signed string) (string, bool) {
	i := strings.LastIndex(signed, ".")
	if i < 0 {
		return "", false
	}
	if !hmac.Equal([]byte(s.sign(signed[:i])), []byte(signed)) {
		return "", false
	}
	return signed[:i], true
}

// start signs a browser in to an account.
func (s sessions) start(w http.ResponseWriter, account string) {
	until := s.now().Add(sessionLife).Unix()
	setCookie(w, sessionCookie, s.sign(account+"|"+strconv.FormatInt(until, 10)), sessionLife)
}

// account is the account a request is signed in to, or "".
func (s sessions) account(r *http.Request) string {
	c, err := r.Cookie(sessionCookie)
	if err != nil {
		return ""
	}
	text, ok := s.open(c.Value)
	if !ok {
		return ""
	}
	id, until, ok := strings.Cut(text, "|")
	end, err := strconv.ParseInt(until, 10, 64)
	if !ok || err != nil || s.now().Unix() >= end || !validID(id) {
		return ""
	}
	return id
}

// form is the token a page's form carries, so another site cannot post to it.
func (s sessions) form(account string) string {
	m := hmac.New(sha256.New, s.key)
	m.Write([]byte("form|" + account))
	return base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (s sessions) formOK(r *http.Request, account string) bool {
	return hmac.Equal([]byte(r.PostFormValue("token")), []byte(s.form(account)))
}

// newState is a sign-in's state, kept in its cookie.
func (s sessions) newState(w http.ResponseWriter) string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	state := base64.RawURLEncoding.EncodeToString(b)
	setCookie(w, stateCookie, s.sign(state), stateLife)
	return state
}

func (s sessions) stateOK(r *http.Request, state string) bool {
	c, err := r.Cookie(stateCookie)
	if err != nil || state == "" {
		return false
	}
	kept, ok := s.open(c.Value)
	return ok && hmac.Equal([]byte(kept), []byte(state))
}

func setCookie(w http.ResponseWriter, name, value string, life time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: value, Path: "/", MaxAge: int(life.Seconds()), HttpOnly: true,
		Secure: true, SameSite: http.SameSiteLaxMode})
}

func endCookie(w http.ResponseWriter, name string) {
	http.SetCookie(w, &http.Cookie{Name: name, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, Secure: true,
		SameSite: http.SameSiteLaxMode})
}
