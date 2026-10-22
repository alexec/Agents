package hosted

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Who may sign up (#2152, spec 1003 FR-001–FR-012). A GitHub user with an account signs in
// as before, never limited. A new one is checked in order: blocked, the mode, allowed (the
// allowlist, an invite, or open), the GitHub account's age, the cap on accounts. One who
// may not have an account yet goes on the waitlist. Making an account or a waitlist entry
// counts against the rates; showing a place already kept does not.

// The modes of Config.SignUp.
const (
	SignUpInvite = "invite"
	SignUpOpen   = "open"
	SignUpClosed = "closed"
)

// The defaults of Config's limits (spec 1003, Clarifications).
const (
	defaultMaxAccounts       = 100
	defaultMinGitHubAge      = 30 * 24 * time.Hour
	defaultSignUpsPerAddress = 3
	defaultSignUpsPerHour    = 30
	defaultMaxCopies         = 50
	defaultCertsPerHour      = 10
	defaultCertsPerWeek      = 40
	// InviteLife is how long an invite link can be used.
	InviteLife = 14 * 24 * time.Hour
	// waitlistMost bounds the waitlist; the rates fill it slowly.
	waitlistMost = 10000
)

// Why a person is on the waitlist, as the page says it.
const (
	whyNoInvite   = "no-invite"
	whyInviteUsed = "invite-used"
	whyAge        = "age"
	whyCap        = "cap"
)

func allowKey(login string) string {
	return hostedPrefix + "v1/allow/" + strings.ToLower(login) + ".json"
}
func inviteKey(code string) string { return hostedPrefix + "v1/invites/" + code + ".json" }
func waitingKey(user int64) string {
	return hostedPrefix + "v1/waiting/" + strconv.FormatInt(user, 10) + ".json"
}
func blockedKey(user int64) string {
	return hostedPrefix + "v1/blocked/" + strconv.FormatInt(user, 10) + ".json"
}
func waitlistKey(place string) string { return hostedPrefix + "v1/waitlist/" + place + ".json" }

const waitlistFolder = hostedPrefix + "v1/waitlist/"

// Invite is an invite link's record.
type Invite struct {
	Expires time.Time `json:"expires"`
	Used    *Used     `json:"used,omitempty"`
}

// Used is who used an invite, and when.
type Used struct {
	GitHub int64     `json:"github"`
	At     time.Time `json:"at"`
}

// Waiting is a GitHub user on the waitlist.
type Waiting struct {
	GitHub GitHubID  `json:"github"`
	At     time.Time `json:"at"`
	Why    string    `json:"why"`
	// Its key in the waitlist folder, whose order is the waitlist's.
	Place string `json:"place"`
}

// Block is a GitHub user who may not sign up.
type Block struct {
	Login  string    `json:"login,omitempty"`
	Reason string    `json:"reason,omitempty"`
	At     time.Time `json:"at"`
}

// validLogin is a GitHub login: letters, digits and hyphens, at most 39.
func validLogin(login string) bool {
	if login == "" || len(login) > 39 {
		return false
	}
	for _, c := range login {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// validInvite is an invite code: twenty letters and digits.
func validInvite(code string) bool {
	if len(code) != 20 {
		return false
	}
	for i := 0; i < len(code); i++ {
		if c := code[i]; !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

func newInviteCode() string {
	b := make([]byte, 20)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = idLetters[int(b[i])%len(idLetters)]
	}
	return string(b)
}

// signUpResult is what the gate decided: an account, a place on the waitlist, or a
// refusal in words.
type signUpResult struct {
	account *Account
	made    bool
	place   int
	why     string
	refused string
	// What kind of refusal, for the metrics.
	kind   string
	status int
}

// gate decides what a GitHub user with no account gets.
func (s *Service) gate(ctx context.Context, from string, user GitHubID, invite string) signUpResult {
	st := s.cfg.Store
	if o, err := st.Get(ctx, blockedKey(user.ID)); err != nil {
		return unreadable(err)
	} else if o != nil {
		return signUpResult{refused: "Sign-up is not open to this GitHub account.", status: http.StatusForbidden, kind: "blocked"}
	}
	if s.cfg.SignUp == SignUpClosed {
		return signUpResult{refused: "Sign-up is not open yet.", status: http.StatusServiceUnavailable, kind: "closed"}
	}
	listed := false
	if validLogin(user.Login) {
		o, err := st.Get(ctx, allowKey(user.Login))
		if err != nil {
			return unreadable(err)
		}
		listed = o != nil
	}
	allowed := s.cfg.SignUp == SignUpOpen || listed
	var inv *store.Object
	if !allowed && validInvite(invite) {
		o, err := st.Get(ctx, inviteKey(invite))
		if err != nil {
			return unreadable(err)
		}
		var rec Invite
		if o != nil && json.Unmarshal(o.Data, &rec) == nil && rec.Used == nil && s.cfg.Now().Before(rec.Expires) {
			allowed, inv = true, o
		}
	}
	why := ""
	switch {
	case !allowed && invite != "":
		why = whyInviteUsed
	case !allowed:
		why = whyNoInvite
	case !listed && s.cfg.Now().Sub(user.Created) < s.cfg.MinGitHubAge:
		why = whyAge
	default:
		n, err := s.accounts.count(ctx)
		if err != nil {
			return unreadable(err)
		}
		if n >= s.cfg.MaxAccounts {
			why = whyCap
		}
	}
	if why == "" {
		if !s.rates.allow(from, s.cfg.Now(), s.cfg.SignUpsPerAddress, s.cfg.SignUpsPerHour) {
			return tooMany()
		}
		if inv != nil {
			var rec Invite
			_ = json.Unmarshal(inv.Data, &rec)
			rec.Used = &Used{GitHub: user.ID, At: s.cfg.Now().UTC()}
			data, _ := json.Marshal(rec)
			if _, err := st.Put(ctx, inviteKey(invite), data, store.Matching(inv.ETag)); err != nil {
				if !store.IsConflict(err) {
					return unreadable(err)
				}
				// Someone else used it first.
				return s.wait(ctx, from, user, whyInviteUsed, false, true)
			}
		}
		acc, made, err := s.accounts.make(ctx, user)
		if err != nil || acc == nil {
			return unreadable(err)
		}
		s.leaveWaitlist(ctx, user.ID)
		return signUpResult{account: acc, made: made}
	}
	return s.wait(ctx, from, user, why, why == whyCap, false)
}

// wait puts a user on the waitlist, at the front for one who may sign up once there is
// room, or gives their place when they are on it already. counted says the rates have
// counted this sign-up already.
func (s *Service) wait(ctx context.Context, from string, user GitHubID, why string, front, counted bool) signUpResult {
	st := s.cfg.Store
	o, err := st.Get(ctx, waitingKey(user.ID))
	if err != nil {
		return unreadable(err)
	}
	var entry Waiting
	if o != nil && json.Unmarshal(o.Data, &entry) == nil {
		return s.placeOf(ctx, entry)
	}
	if !counted && !s.rates.allow(from, s.cfg.Now(), s.cfg.SignUpsPerAddress, s.cfg.SignUpsPerHour) {
		return tooMany()
	}
	keys, err := st.List(ctx, waitlistFolder)
	if err != nil {
		return unreadable(err)
	}
	if len(keys) >= waitlistMost {
		return signUpResult{refused: "The waitlist is full just now. Try again another day.", status: http.StatusServiceUnavailable, kind: "waitlist_full"}
	}
	now := s.cfg.Now().UTC()
	// Front places sort before the others, each in the order they came.
	order := "b"
	if front {
		order = "a"
	}
	entry = Waiting{GitHub: GitHubID{ID: user.ID, Login: user.Login}, At: now, Why: why,
		Place: fmt.Sprintf("%s%020d-%d", order, now.UnixNano(), user.ID)}
	data, _ := json.Marshal(entry)
	if _, err := st.Put(ctx, waitingKey(user.ID), data, store.Absent); err != nil {
		if store.IsConflict(err) {
			// Another tab put them on it at the same time.
			return s.wait(ctx, from, user, why, front, true)
		}
		return unreadable(err)
	}
	link, _ := json.Marshal(map[string]int64{"github": user.ID})
	if _, err := st.Put(ctx, waitlistKey(entry.Place), link, store.Absent); err != nil {
		return unreadable(err)
	}
	s.metrics.signedUp("waitlist")
	s.log(fmt.Sprintf("waitlist: github %d (%s)", user.ID, why))
	return s.placeOf(ctx, entry)
}

// placeOf is a waitlist entry's place, from one.
func (s *Service) placeOf(ctx context.Context, entry Waiting) signUpResult {
	keys, err := s.cfg.Store.List(ctx, waitlistFolder)
	if err != nil {
		return unreadable(err)
	}
	place := sort.Search(len(keys), func(i int) bool { return keys[i].Key >= waitlistKey(entry.Place) }) + 1
	return signUpResult{place: place, why: entry.Why}
}

// leaveWaitlist takes a user off the waitlist, once they have an account or are blocked.
func (s *Service) leaveWaitlist(ctx context.Context, user int64) {
	leaveWaitlist(ctx, s.cfg.Store, user)
}

func leaveWaitlist(ctx context.Context, st store.Store, user int64) {
	o, err := st.Get(ctx, waitingKey(user))
	if err != nil || o == nil {
		return
	}
	var entry Waiting
	if json.Unmarshal(o.Data, &entry) == nil && entry.Place != "" {
		_ = st.Delete(ctx, waitlistKey(entry.Place))
	}
	_ = st.Delete(ctx, waitingKey(user))
}

// whyText is a waitlist reason in words.
func whyText(why string, minAge time.Duration) string {
	switch why {
	case whyInviteUsed:
		return "That invite is used or expired."
	case whyAge:
		return fmt.Sprintf("Your GitHub account is newer than %d days.", int(minAge.Hours()/24))
	case whyCap:
		return "Agents has as many accounts as it can take for now."
	default:
		return "Sign-up is by invitation while Agents is in beta."
	}
}

func unreadable(err error) signUpResult {
	_ = err
	return signUpResult{refused: "Your account could not be read or made. Try again in a moment.", status: http.StatusServiceUnavailable, kind: "store"}
}

func tooMany() signUpResult {
	return signUpResult{refused: "Too many sign-ups just now. Try again in an hour.", status: http.StatusTooManyRequests, kind: "rate"}
}

// rates are the sign-ups of the last hour, by address and in all (FR-006). They are in
// memory: the service is one process, and a restart starts them again.
type rates struct {
	mu  sync.Mutex
	by  map[string][]time.Time
	all []time.Time
}

// allow counts a sign-up from an address, if it is under both rates.
func (r *rates) allow(from string, now time.Time, perAddress, perHour int) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	since := now.Add(-time.Hour)
	if r.by == nil {
		r.by = map[string][]time.Time{}
	}
	r.all = recent(r.all, since)
	mine := recent(r.by[from], since)
	// Bound the map: drop the addresses with nothing left in the hour.
	if len(r.by) > 256 {
		for k, v := range r.by {
			if len(recent(v, since)) == 0 {
				delete(r.by, k)
			}
		}
	}
	if len(mine) >= perAddress || len(r.all) >= perHour {
		r.by[from] = mine
		return false
	}
	r.by[from] = append(mine, now)
	r.all = append(r.all, now)
	return true
}

// recent is the times after since, in order.
func recent(times []time.Time, since time.Time) []time.Time {
	i := 0
	for i < len(times) && !times[i].After(since) {
		i++
	}
	return times[i:]
}

var errFull = errors.New("the service is full")
