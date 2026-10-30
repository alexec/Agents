package records

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// LegacyGrant is written where an older build expects a grant: every client may do
// everything (#111), and the word stays for builds from before.
const LegacyGrant = "operator"

// Client kinds, as ClientRecord.Kind says them. A kind a later build added reads as
// KindUnknown.
const (
	KindMac     = "mac"
	KindIPhone  = "iPhone"
	KindIPad    = "iPad"
	KindUnknown = "unknown"
	// The web remote (071): pairs and connects only through the loopback listener.
	KindBrowser = "browser"
)

// ClientRecord is a paired screen: the Mac window, an iPhone, an iPad, a browser
// (v1/clients/<uuid>.json).
type ClientRecord struct {
	// Upper case, as Swift's uuidString writes it.
	ID   string
	Name string
	Kind string
	// P-256, X9.63.
	PublicKey []byte
	Paired    Stamp
	LastSeen  *Stamp
	// A device's own report of whether it may show a notification (021).
	MayNotify *bool
	Owner     *string
	// Bumped on every write, so no two versions of a record have the same bytes (rule 10).
	Rev int
	// Forgotten: kept as a tombstone, read as absent (rule 11).
	Forgotten   *bool
	ForgottenAt *Stamp
	// The newest list of endpoints it has said it holds (R16).
	KnownEpoch *int
	// A device's own APNs token (#1460), set only by that device over its own session,
	// for the control plane to push to when no Mac host relays its notices. Never on the
	// wire to another client.
	PushToken *PushToken
	// The push tokens of its Live Activity (#1744), one for each session it speaks for
	// (#2991), newest last, held to MostActivityTokens. Set only by the device, as PushToken is.
	ActivityTokens []ActivityToken
	// A browser's own Web Push subscription (#1486), set only by that browser over its
	// own session, as PushToken is: where the control plane posts its notices.
	WebPush *WebPushSubscription
	// When its key stops being accepted (#997, spec 736 FR-042); renewed while in use.
	// None on a record paired before #997, until the sweep or its next connection sets it.
	Expires *Stamp
	Extra   Extra
}

// ActivityToken is a Live Activity's push token on a device for one session it speaks
// for: from which APNs, and when the session's turn began, where the timer counts from. A
// device shows one activity for every turn sent from it (#2991), so one token is here once
// for each of those sessions.
type ActivityToken struct {
	Agent       string    `json:"agent"`
	Token       string    `json:"token"`
	Environment string    `json:"environment"`
	StartedAt   wire.Date `json:"startedAt"`
	// The session's phase as its host last said it (wire.TurnPhase); none is working.
	Phase string `json:"phase,omitempty"`
	// When the device gave it. A Live Activity lives at most 12 hours; one older is
	// dropped.
	SetAt Stamp `json:"setAt"`
}

// MostActivityTokens is how many Live Activity tokens a device keeps.
const MostActivityTokens = 16

// PushToken is a device's APNs token, hex, and which APNs it is from: "development" (a
// Debug build) or "production".
type PushToken struct {
	Token       string `json:"token"`
	Environment string `json:"environment"`
}

// WebPushSubscription is a browser's push service endpoint and the two keys its pushes are
// sealed with (RFC 8291): the P-256 public key, X9.63, and the 16-byte auth secret.
type WebPushSubscription struct {
	Endpoint string `json:"endpoint"`
	P256dh   []byte `json:"p256dh"`
	Auth     []byte `json:"auth"`
}

type clientJSON struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Kind        string     `json:"kind"`
	PublicKey   []byte     `json:"publicKey"`
	Grant       string     `json:"grant"`
	Paired      Stamp      `json:"paired"`
	LastSeen    *Stamp     `json:"lastSeen,omitempty"`
	MayNotify   *bool      `json:"mayNotify,omitempty"`
	Owner       *string    `json:"owner,omitempty"`
	Rev         int        `json:"rev"`
	Forgotten   *bool      `json:"forgotten,omitempty"`
	ForgottenAt *Stamp     `json:"forgottenAt,omitempty"`
	KnownEpoch  *int       `json:"knownEpoch,omitempty"`
	PushToken   *PushToken `json:"pushToken,omitempty"`
	// Activities: the push tokens of its Live Activities (#1744).
	Activities []ActivityToken      `json:"activityTokens,omitempty"`
	Expires    *Stamp               `json:"expires,omitempty"`
	WebPush    *WebPushSubscription `json:"webPush,omitempty"`
}

// MarshalJSON writes grant: operator, which an older copy needs to read the record at
// all, and which tells it the truth.
func (c ClientRecord) MarshalJSON() ([]byte, error) {
	return encodeKeeping(clientJSON{c.ID, c.Name, c.Kind, c.PublicKey, LegacyGrant, c.Paired, c.LastSeen, c.MayNotify,
		c.Owner, c.Rev, c.Forgotten, c.ForgottenAt, c.KnownEpoch, c.PushToken, c.ActivityTokens, c.Expires, c.WebPush}, c.Extra)
}

// UnmarshalJSON does not read the grant: every client may do everything (#111).
func (c *ClientRecord) UnmarshalJSON(data []byte) error {
	var j clientJSON
	extra, err := decodeKeeping(data, &j, "id", "name", "kind", "publicKey", "paired", "rev")
	if err != nil {
		return err
	}
	if !isUUID(j.ID) {
		return fmt.Errorf("%q is not a UUID", j.ID)
	}
	switch j.Kind {
	case KindMac, KindIPhone, KindIPad, KindUnknown, KindBrowser:
	default:
		j.Kind = KindUnknown
	}
	*c = ClientRecord{strings.ToUpper(j.ID), j.Name, j.Kind, j.PublicKey, j.Paired, j.LastSeen, j.MayNotify, j.Owner,
		j.Rev, j.Forgotten, j.ForgottenAt, j.KnownEpoch, j.PushToken, j.Activities, j.WebPush, j.Expires, extra}
	return nil
}

// IsDevice is Kind.isDevice: a phone, an iPad, or a device paired before kinds were
// said; not the Mac's window, and not a browser, which has no mailbox (071).
func (c *ClientRecord) IsDevice() bool { return c.Kind != KindMac && c.Kind != KindBrowser }

// MachineRecord is a machine that runs agents (v1/machines/<id>.json).
type MachineRecord struct {
	ID   string
	Name string
	// For a host that connects out.
	PublicKey []byte
	Platform  string
	Version   string
	// Whether hosts/install put it there, so removing it can offer to take it away.
	Installed bool
	// The machine it runs on, so a window can tell a host on its own Mac (R11).
	MachineID *string
	// A macOS host that runs the relay and mailbox for its person's devices (R10).
	Relay *bool
	// The hosts whose sign-in this host may use, by runtime (058, T091).
	SignInFrom map[string]string
	// The hosts whose git access this host may use, by git server (#1122).
	GitFrom     map[string]string
	Owner       *string
	Rev         int
	Forgotten   *bool
	ForgottenAt *Stamp
	KnownEpoch  *int
	// Set before #656; cleared when the host next says hello.
	DetectFolders *bool
	// The provider's workspace this host runs on (#691), as it was written.
	Workspace json.RawMessage
	// When its key stops being accepted (#997), as ClientRecord.Expires.
	Expires *Stamp
	Extra   Extra
}

type hostJSON struct {
	ID            string            `json:"id"`
	Name          string            `json:"name"`
	PublicKey     []byte            `json:"publicKey,omitempty"`
	Reach         json.RawMessage   `json:"reach"`
	Platform      string            `json:"platform"`
	Version       string            `json:"version"`
	Installed     bool              `json:"installed"`
	MachineID     *string           `json:"machineID,omitempty"`
	Relay         *bool             `json:"relay,omitempty"`
	SignInFrom    map[string]string `json:"signInFrom,omitempty"`
	GitFrom       map[string]string `json:"gitFrom,omitempty"`
	Owner         *string           `json:"owner,omitempty"`
	Rev           int               `json:"rev"`
	Forgotten     *bool             `json:"forgotten,omitempty"`
	ForgottenAt   *Stamp            `json:"forgottenAt,omitempty"`
	KnownEpoch    *int              `json:"knownEpoch,omitempty"`
	DetectFolders *bool             `json:"detectFolders,omitempty"`
	Workspace     json.RawMessage   `json:"workspace,omitempty"`
	Expires       *Stamp            `json:"expires,omitempty"`
}

// dialOut is MachineReach.dialOut: every host connects out now (058, T073); a record that
// says anything else is read as one that dials out.
var dialOut = json.RawMessage(`{"dialOut":{}}`)

func (h MachineRecord) MarshalJSON() ([]byte, error) {
	return encodeKeeping(hostJSON{h.ID, h.Name, h.PublicKey, dialOut, h.Platform, h.Version, h.Installed, h.MachineID,
		h.Relay, h.SignInFrom, h.GitFrom, h.Owner, h.Rev, h.Forgotten, h.ForgottenAt, h.KnownEpoch, h.DetectFolders,
		h.Workspace, h.Expires}, h.Extra)
}

func (h *MachineRecord) UnmarshalJSON(data []byte) error {
	var j hostJSON
	extra, err := decodeKeeping(data, &j, "id", "name", "reach", "platform", "version", "installed", "rev")
	if err != nil {
		return err
	}
	*h = MachineRecord{j.ID, j.Name, j.PublicKey, j.Platform, j.Version, j.Installed, j.MachineID, j.Relay, j.SignInFrom,
		j.GitFrom, j.Owner, j.Rev, j.Forgotten, j.ForgottenAt, j.KnownEpoch, j.DetectFolders, j.Workspace, j.Expires, extra}
	return nil
}

// Endpoint is ControlEndpoint: one place a control plane answers (R16), on the wire and
// in control.json alike.
type Endpoint = wire.ControlEndpoint

// Settings is ControlSettings (v1/control.json): what the control plane is.
type Settings struct {
	Name string
	Port int
	// The host on the same machine. A legacy client's bare lines go there.
	HomeHost  *string
	MachineID string
	// The one address clients and hosts are given (R8), and its certificate's pin (R6).
	URL *string
	Pin *string
	// Every place it answers, once announced, and the epoch of that list (R16).
	Endpoints []Endpoint
	Epoch     *int
	// The control plane's public key, X9.63. The private half is never in the store.
	ControlKey []byte
	Owner      *string
	Created    *Stamp
	Rev        *int
	// Where a host added from now on has its folders found (#429), as written.
	FolderDetection json.RawMessage
	// Chat apps that reach the person's agents (#1012), as written.
	Channels json.RawMessage
	// How many days audit entries are kept (#996); nil is the default, 90.
	AuditDays *int
	// After a shorter AuditDays (#2067): the days kept before it, until a day after
	// AuditShortened, so choosing the longer time again in that day loses nothing.
	AuditDaysBefore *int
	AuditShortened  *Stamp
	// The key before the last rotation, while it is still accepted, and when it was
	// rotated (#997).
	PreviousKey []byte
	RotatedAt   *Stamp
	Extra       Extra
}

type settingsJSON struct {
	Name            string          `json:"name"`
	Port            int             `json:"port"`
	HomeHost        *string         `json:"homeHost,omitempty"`
	MachineID       string          `json:"machineID"`
	URL             *string         `json:"url,omitempty"`
	Pin             *string         `json:"pin,omitempty"`
	Endpoints       []Endpoint      `json:"endpoints,omitempty"`
	Epoch           *int            `json:"epoch,omitempty"`
	ControlKey      []byte          `json:"controlKey,omitempty"`
	Owner           *string         `json:"owner,omitempty"`
	Created         *Stamp          `json:"created,omitempty"`
	Rev             *int            `json:"rev,omitempty"`
	FolderDetection json.RawMessage `json:"folderDetection,omitempty"`
	Channels        json.RawMessage `json:"channels,omitempty"`
	AuditDays       *int            `json:"auditDays,omitempty"`
	AuditDaysBefore *int            `json:"auditDaysBefore,omitempty"`
	AuditShortened  *Stamp          `json:"auditShortened,omitempty"`
	PreviousKey     []byte          `json:"previousKey,omitempty"`
	RotatedAt       *Stamp          `json:"rotatedAt,omitempty"`
}

func (s Settings) MarshalJSON() ([]byte, error) {
	return encodeKeeping(settingsJSON{s.Name, s.Port, s.HomeHost, s.MachineID, s.URL, s.Pin, s.Endpoints, s.Epoch,
		s.ControlKey, s.Owner, s.Created, s.Rev, s.FolderDetection, s.Channels, s.AuditDays, s.AuditDaysBefore, s.AuditShortened, s.PreviousKey, s.RotatedAt}, s.Extra)
}

func (s *Settings) UnmarshalJSON(data []byte) error {
	var j settingsJSON
	extra, err := decodeKeeping(data, &j, "name", "port", "machineID")
	if err != nil {
		return err
	}
	*s = Settings{j.Name, j.Port, j.HomeHost, j.MachineID, j.URL, j.Pin, j.Endpoints, j.Epoch, j.ControlKey, j.Owner,
		j.Created, j.Rev, j.FolderDetection, j.Channels, j.AuditDays, j.AuditDaysBefore, j.AuditShortened, j.PreviousKey, j.RotatedAt, extra}
	return nil
}

// NewUUID is a random (version 4) UUID, upper case, as Swift's UUID().uuidString.
func NewUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

// NewPersonID is PersonID.make: a UUID in lower case.
func NewPersonID() string { return strings.ToLower(NewUUID()) }

// NewHostID is MachineRef.make: eight lower-case letters and digits, never "mac".
func NewHostID() string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
	for {
		b := make([]byte, 8)
		rand.Read(b)
		for i := range b {
			// 252 is the largest multiple of 36 below 256: no letter is likelier.
			for b[i] >= 252 {
				rand.Read(b[i : i+1])
			}
			b[i] = alphabet[int(b[i])%len(alphabet)]
		}
		if string(b) != "mac" {
			return string(b)
		}
	}
}

// IsUUID says whether s is a UUID, in either case.
func IsUUID(s string) bool { return isUUID(s) }

func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
