package controlplane

import (
	"encoding/json"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// The shapes the control plane's methods answer with, as Swift's default JSONEncoder
// writes them: dates as seconds since 2001-01-01, UUIDs in upper case, data in base64,
// nil left out.

// RefDate is a date on the wire.
type RefDate time.Time

// referenceDate is 2001-01-01T00:00:00Z, which Swift's dates count from.
const referenceDate = 978307200

func (d RefDate) MarshalJSON() ([]byte, error) {
	t := time.Time(d)
	return json.Marshal(float64(t.UnixNano()-referenceDate*int64(time.Second)) / 1e9)
}

func (d *RefDate) UnmarshalJSON(b []byte) error {
	var seconds float64
	if err := json.Unmarshal(b, &seconds); err != nil {
		return err
	}
	*d = RefDate(time.Unix(referenceDate, 0).Add(time.Duration(seconds * float64(time.Second))))
	return nil
}

func refDate(s *records.Stamp) *RefDate {
	if s == nil {
		return nil
	}
	d := RefDate(s.Time)
	return &d
}

// clientWire is ClientRecord as clients/list answers it.
type clientWire struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Kind        string   `json:"kind"`
	PublicKey   []byte   `json:"publicKey"`
	Grant       string   `json:"grant"`
	Paired      RefDate  `json:"paired"`
	LastSeen    *RefDate `json:"lastSeen,omitempty"`
	MayNotify   *bool    `json:"mayNotify,omitempty"`
	Owner       *string  `json:"owner,omitempty"`
	Rev         int      `json:"rev"`
	Forgotten   *bool    `json:"forgotten,omitempty"`
	ForgottenAt *RefDate `json:"forgottenAt,omitempty"`
	KnownEpoch  *int     `json:"knownEpoch,omitempty"`
}

func clientOnWire(c records.ClientRecord) clientWire {
	return clientWire{c.ID, c.Name, c.Kind, c.PublicKey, records.LegacyGrant, RefDate(c.Paired.Time), refDate(c.LastSeen),
		c.MayNotify, c.Owner, c.Rev, c.Forgotten, refDate(c.ForgottenAt), c.KnownEpoch}
}

// WebRemoteStatus is DaemonAPI.WebRemoteStatus: the web remote's listener as it stands.
type WebRemoteStatus struct {
	Port   int     `json:"port"`
	Served bool    `json:"served"`
	Reason *string `json:"reason,omitempty"`
	Detail *string `json:"detail,omitempty"`
}

// HostJoinStatus is DaemonAPI.HostJoinStatus: how this Mac's host's join stands (#113).
type HostJoinStatus struct {
	Member    bool    `json:"member"`
	Connected bool    `json:"connected"`
	Problem   *string `json:"problem,omitempty"`
	At        RefDate `json:"at"`
}

// controlStatus is DaemonAPI.ControlStatus: control/status.
type controlStatus struct {
	Name             string            `json:"name"`
	Version          string            `json:"version"`
	HomeHost         *string           `json:"homeHost,omitempty"`
	MachineID        string            `json:"machineID"`
	StartedAt        *RefDate          `json:"startedAt,omitempty"`
	Port             *int              `json:"port,omitempty"`
	AwayFromHome     *bool             `json:"awayFromHome,omitempty"`
	You              string            `json:"you,omitempty"`
	RelayKey         []byte            `json:"relayKey,omitempty"`
	Web              *WebRemoteStatus  `json:"web,omitempty"`
	ThisMacHost      *HostJoinStatus   `json:"thisMacHost,omitempty"`
	ProjectDetection json.RawMessage   `json:"projectDetection,omitempty"`
	UnjoinedTunnels  []json.RawMessage `json:"unjoinedTunnels,omitempty"`
}

// gitAsk is DaemonAPI.GitAsk: a host's git waiting on a person's answer (#1122).
type gitAsk struct {
	Server string `json:"server"`
	From   string `json:"from"`
}

// controlHost is DaemonAPI.ControlHost: one hosts/list row.
type controlHost struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Platform   string            `json:"platform"`
	Version    string            `json:"version"`
	State      string            `json:"state"`
	Reach      string            `json:"reach"`
	MachineID  *string           `json:"machineID,omitempty"`
	Relay      *bool             `json:"relay,omitempty"`
	SignInFrom map[string]string `json:"signInFrom,omitempty"`
	GitFrom    map[string]string `json:"gitFrom,omitempty"`
	GitAsks    []gitAsk          `json:"gitAsks,omitempty"`
	Tunnel     json.RawMessage   `json:"tunnel,omitempty"`
	Workspace  json.RawMessage   `json:"workspace,omitempty"`
	// Which language the host is written in, as its hello said (#1134): "go" or none.
	Implementation string `json:"implementation,omitempty"`
}

// clientConnection is DaemonAPI.ClientConnection: clients/connections.
type clientConnection struct {
	Client  string  `json:"client"`
	Relayed bool    `json:"relayed"`
	Through *string `json:"through,omitempty"`
}

// hostHello is DaemonAPI.HostHello: a host's first word on channel 0.
type hostHello struct {
	Host      *string `json:"host,omitempty"`
	Version   string  `json:"version"`
	Platform  string  `json:"platform"`
	MachineID string  `json:"machineID"`
	Name      *string `json:"name,omitempty"`
	Relay     *bool   `json:"relay,omitempty"`
	// "go" from a Go host (#1134); a Swift host says nothing.
	Implementation string `json:"implementation,omitempty"`
}

// codeShown is DaemonAPI.ControlCodeShown: a code, until when it works, and for a host
// the one line to run on the server.
type codeShown struct {
	Text    string  `json:"text"`
	Expires RefDate `json:"expires"`
	Command *string `json:"command,omitempty"`
}

// admitted is DaemonAPI.Admitted: who the new party now is.
type admitted struct {
	Client string `json:"client,omitempty"`
	Host   string `json:"host,omitempty"`
	Grant  string `json:"grant,omitempty"`
}

// clientAnnounce is DaemonAPI.ClientAnnounce.
type clientAnnounce struct {
	ID        string `json:"id"`
	PublicKey []byte `json:"publicKey"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
}

// hostAnnounce is DaemonAPI.HostAnnounce.
type hostAnnounce struct {
	PublicKey      []byte `json:"publicKey"`
	Name           string `json:"name"`
	Platform       string `json:"platform"`
	Version        string `json:"version"`
	MachineID      string `json:"machineID"`
	Relay          *bool  `json:"relay,omitempty"`
	Implementation string `json:"implementation,omitempty"`
}

type hostRequest struct {
	Host  string `json:"host"`
	Purge *bool  `json:"purge,omitempty"`
}

type lendSignIn struct {
	Host    string `json:"host"`
	From    string `json:"from"`
	Runtime string `json:"runtime"`
	Allowed bool   `json:"allowed"`
}

type lendGit struct {
	Host    string `json:"host"`
	From    string `json:"from"`
	Server  string `json:"server"`
	Allowed bool   `json:"allowed"`
}

type hostRelayRequest struct {
	Host  string `json:"host"`
	Relay bool   `json:"relay"`
}

type tunnelOpen struct {
	Runtime string `json:"runtime"`
	Ref     string `json:"ref"`
}

// projectDetection is ProjectDetection (#429).
type projectDetection struct {
	Enabled bool     `json:"enabled"`
	Paths   []string `json:"paths"`
}

var standardDetection = projectDetection{Enabled: true, Paths: []string{"~", "~/src", "~/code", "~/projects", "~/Developer", "~/dev", "~/git"}}
