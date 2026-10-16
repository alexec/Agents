// Package channels ports the control plane's chat channels (#1012) from Swift: Slack
// (#1009) answers Needs You questions. Channels are an option and are off unless set.
//
// Every shape in this file is written as Swift's default JSONEncoder writes it: dates as
// seconds since 2001-01-01, UUIDs in upper case, nil left out.
package channels

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Method and notification names: DaemonAPI.Method.channelsGet, .channelsSet and
// DaemonAPI.Notification.controlChannelsChanged.
const (
	MethodGet     = "channels/get"
	MethodSet     = "channels/set"
	NotifyChanged = "control/channelsChanged"
)

// Status words: DaemonAPI.SlackState.off, .connecting, .connected and .failed.
const (
	StatusOff        = "off"
	StatusConnecting = "connecting"
	StatusConnected  = "connected"
	StatusFailed     = "failed"
)

// Error codes: JSONRPCError.invalidParams and DaemonAPI.Failure.notPermitted.
const (
	CodeInvalidParams = -32602
	CodeNotPermitted  = -32045
)

// RPCError is JSONRPCError: a refusal with a code and words a person can read.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string { return fmt.Sprintf("%d %s", e.Code, e.Message) }

// RefDate is a Foundation Date on the wire: seconds since 2001-01-01T00:00:00Z.
type RefDate time.Time

// referenceDate is 2001-01-01T00:00:00Z in Unix seconds.
const referenceDate = 978307200

// Seconds is Date.timeIntervalSinceReferenceDate.
func (d RefDate) Seconds() float64 {
	return float64(time.Time(d).UnixNano()-referenceDate*int64(time.Second)) / 1e9
}

func (d RefDate) MarshalJSON() ([]byte, error) { return json.Marshal(d.Seconds()) }

func (d *RefDate) UnmarshalJSON(b []byte) error {
	var seconds float64
	if err := json.Unmarshal(b, &seconds); err != nil {
		return err
	}
	*d = RefDate(time.Unix(referenceDate, 0).Add(time.Duration(seconds * float64(time.Second))))
	return nil
}

// NewUUID is UUID().uuidString: a random UUID in upper case.
func NewUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}

// ChannelSettings is ChannelSettings: control.json's channels, with no secret in it.
type ChannelSettings struct {
	Slack *SlackChannelSettings `json:"slack,omitempty"`
}

// SlackChannelSettings is SlackChannelSettings: whether Slack is on, and the one member
// whose direct messages get the questions.
type SlackChannelSettings struct {
	Enabled  bool   `json:"enabled"`
	MemberID string `json:"memberID"`
}

var memberID = regexp.MustCompile(`^[UW][A-Z0-9]{2,}$`)

// IsMemberID is SlackChannelSettings.isMemberID: U or W, then capitals and digits.
func IsMemberID(text string) bool { return memberID.MatchString(text) }

// ChannelsState is DaemonAPI.ChannelsState: channels/get's answer and
// control/channelsChanged's body.
type ChannelsState struct {
	Slack SlackState `json:"slack"`
}

// SlackState is DaemonAPI.SlackState. It never holds a token.
type SlackState struct {
	Enabled     bool    `json:"enabled"`
	MemberID    string  `json:"memberID"`
	AppTokenSet bool    `json:"appTokenSet"`
	BotTokenSet bool    `json:"botTokenSet"`
	Status      string  `json:"status"`
	Detail      *string `json:"detail,omitempty"`
	Available   bool    `json:"available"`
}

// Unavailable is DaemonAPI.ChannelsState.unavailable: what a control plane says where no
// channel can run (several copies, or no home for secrets).
func Unavailable() ChannelsState {
	detail := "Channels need a control plane with one copy, for now."
	return ChannelsState{Slack: SlackState{Status: StatusOff, Detail: &detail}}
}

// ChannelsSet is DaemonAPI.ChannelsSet: channels/set's request.
type ChannelsSet struct {
	Slack *SlackSet `json:"slack,omitempty"`
}

// SlackSet is DaemonAPI.SlackSet: only what is given changes, and a token given empty is
// taken away.
type SlackSet struct {
	Enabled  *bool   `json:"enabled,omitempty"`
	MemberID *string `json:"memberID,omitempty"`
	AppToken *string `json:"appToken,omitempty"`
	BotToken *string `json:"botToken,omitempty"`
}

// Headline is Headline: a banner's three short strings.
type Headline struct {
	H1 string `json:"h1"`
	H2 string `json:"h2"`
	H3 string `json:"h3"`
}

// NeedID is NeedID: what is being answered. Exactly one field is set.
type NeedID struct {
	Permission    string
	Elicitation   string
	Report        *NeedReport
	GuardedChange *NeedGuarded
}

// NeedReport is NeedID.report's body.
type NeedReport struct {
	AgentID string  `json:"agentID"`
	At      RefDate `json:"at"`
}

// NeedGuarded is NeedID.guardedChange's body. Folder is a file URL, as Swift writes it.
type NeedGuarded struct {
	Folder string `json:"folder"`
	Path   string `json:"path"`
}

type needIDWire struct {
	Permission    *string      `json:"permission,omitempty"`
	Elicitation   *string      `json:"elicitation,omitempty"`
	Report        *NeedReport  `json:"report,omitempty"`
	GuardedChange *NeedGuarded `json:"guardedChange,omitempty"`
}

func (n NeedID) MarshalJSON() ([]byte, error) {
	var w needIDWire
	switch {
	case n.Permission != "":
		w.Permission = &n.Permission
	case n.Elicitation != "":
		w.Elicitation = &n.Elicitation
	case n.Report != nil:
		w.Report = n.Report
	case n.GuardedChange != nil:
		w.GuardedChange = n.GuardedChange
	}
	return json.Marshal(w)
}

func (n *NeedID) UnmarshalJSON(b []byte) error {
	var w needIDWire
	if err := json.Unmarshal(b, &w); err != nil {
		return err
	}
	*n = NeedID{}
	switch {
	case w.Permission != nil:
		n.Permission = *w.Permission
	case w.Elicitation != nil:
		n.Elicitation = *w.Elicitation
	case w.Report != nil:
		n.Report = w.Report
	case w.GuardedChange != nil:
		n.GuardedChange = w.GuardedChange
	default:
		return fmt.Errorf("a need id names what is asked")
	}
	return nil
}

// Token is NeedID.token: one string for the need.
func (n NeedID) Token() string {
	switch {
	case n.Permission != "":
		return "permission:" + strings.ToUpper(n.Permission)
	case n.Elicitation != "":
		return "elicitation:" + strings.ToUpper(n.Elicitation)
	case n.Report != nil:
		return "report:" + strings.ToUpper(n.Report.AgentID) + ":" + swiftDouble(n.Report.At.Seconds())
	case n.GuardedChange != nil:
		return "guarded:" + urlPath(n.GuardedChange.Folder) + ":" + n.GuardedChange.Path
	}
	return ""
}

// swiftDouble writes a Double as Swift's description does for an ordinary date.
func swiftDouble(f float64) string {
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// urlPath is URL.path: the path of a file URL, with no slash at the end.
func urlPath(text string) string {
	u, err := url.Parse(text)
	if err != nil || u.Path == "" {
		return text
	}
	if len(u.Path) > 1 {
		return strings.TrimSuffix(u.Path, "/")
	}
	return u.Path
}

// Need is Need: what wants a person.
type Need struct {
	ID       NeedID   `json:"id"`
	AgentID  *string  `json:"agentID,omitempty"`
	Folder   string   `json:"folder"`
	Kind     string   `json:"kind"`
	RaisedAt RefDate  `json:"raisedAt"`
	Headline Headline `json:"headline"`
}

// AttentionNeed is DaemonAPI.AttentionNeed: a host's attention/need. A need offered, or
// Withdraw for a need that is over.
type AttentionNeed struct {
	Need     *Need     `json:"need,omitempty"`
	Headline *Headline `json:"headline,omitempty"`
	Buzz     *bool     `json:"buzz,omitempty"`
	Withdraw *NeedID   `json:"withdraw,omitempty"`
}

// Offer is DaemonAPI.AttentionNeed.offer.
func Offer(need Need, buzz bool) AttentionNeed {
	h := need.Headline
	return AttentionNeed{Need: &need, Headline: &h, Buzz: &buzz}
}

// Withdraw is DaemonAPI.AttentionNeed.withdraw.
func Withdraw(id NeedID) AttentionNeed { return AttentionNeed{Withdraw: &id} }

// ElicitationRequest is ElicitationRequest: a structured question from an agent, as
// elicitations/pending answers it.
type ElicitationRequest struct {
	ID            string          `json:"id"`
	ElicitationID *string         `json:"elicitationID,omitempty"`
	AgentID       string          `json:"agentID"`
	Message       *string         `json:"message,omitempty"`
	Mode          ElicitationMode `json:"mode"`
	Scope         string          `json:"scope"`
	AskedAt       RefDate         `json:"askedAt"`
}

// Title is ElicitationRequest.title.
func (r ElicitationRequest) Title() string {
	if r.Mode.Form != nil {
		if r.Mode.Form.Title != nil {
			return *r.Mode.Form.Title
		}
		if r.Message != nil {
			return *r.Message
		}
		return "The agent needs something"
	}
	return "The agent wants you to open a page"
}

// ElicitationMode is ElicitationRequest.Mode: a form, or a page to open.
type ElicitationMode struct {
	Form *ElicitationSchema
	URL  *string
}

type modeWire struct {
	Form *struct {
		V ElicitationSchema `json:"_0"`
	} `json:"form,omitempty"`
	URL *struct {
		V string `json:"_0"`
	} `json:"url,omitempty"`
}

func (m ElicitationMode) MarshalJSON() ([]byte, error) {
	var w modeWire
	if m.Form != nil {
		w.Form = &struct {
			V ElicitationSchema `json:"_0"`
		}{*m.Form}
	} else if m.URL != nil {
		w.URL = &struct {
			V string `json:"_0"`
		}{*m.URL}
	}
	return json.Marshal(w)
}

func (m *ElicitationMode) UnmarshalJSON(b []byte) error {
	var w modeWire
	if err := json.Unmarshal(b, &w); err != nil {
		return err
	}
	*m = ElicitationMode{}
	switch {
	case w.Form != nil:
		m.Form = &w.Form.V
	case w.URL != nil:
		m.URL = &w.URL.V
	default:
		return fmt.Errorf("an elicitation is a form or a url")
	}
	return nil
}

// ElicitationSchema is ElicitationSchema: named properties, each with a kind.
type ElicitationSchema struct {
	Title       *string    `json:"title,omitempty"`
	Description *string    `json:"description,omitempty"`
	Properties  []Property `json:"properties"`
}

// Pages is ElicitationSchema.pages: a note box travels on the page of the question before it.
func (s ElicitationSchema) Pages() [][]Property {
	var pages [][]Property
	for _, p := range s.Properties {
		if n := len(pages); n > 0 && p.isNote(pages[n-1][len(pages[n-1])-1]) {
			pages[n-1] = append(pages[n-1], p)
		} else {
			pages = append(pages, []Property{p})
		}
	}
	return pages
}

// Property is ElicitationSchema.Property.
type Property struct {
	Name         string          `json:"name"`
	Title        *string         `json:"title,omitempty"`
	Description  *string         `json:"description,omitempty"`
	IsRequired   bool            `json:"isRequired"`
	Kind         PropertyKind    `json:"kind"`
	DefaultValue json.RawMessage `json:"defaultValue,omitempty"`
}

// isNote is Property.isNote(on:): optional plain text named after the property before it.
func (p Property) isNote(previous Property) bool {
	k := p.Kind
	return !p.IsRequired && strings.HasPrefix(p.Name, previous.Name+"_") && k.Type == KindString &&
		k.Format == nil && k.MinLength == nil && k.MaxLength == nil && k.Choices == nil
}

// Kind names: ElicitationSchema.Property.Kind's cases.
const (
	KindString      = "string"
	KindNumber      = "number"
	KindInteger     = "integer"
	KindBoolean     = "boolean"
	KindMultiSelect = "multiSelect"
)

// PropertyKind is ElicitationSchema.Property.Kind. Type names the case; only that case's
// fields are set.
type PropertyKind struct {
	Type string
	KindBody
}

// KindBody is the fields of every Kind case, nil left out.
type KindBody struct {
	Format    *string  `json:"format,omitempty"`
	MinLength *int     `json:"minLength,omitempty"`
	MaxLength *int     `json:"maxLength,omitempty"`
	Choices   []Choice `json:"choices,omitempty"`
	Minimum   *float64 `json:"minimum,omitempty"`
	Maximum   *float64 `json:"maximum,omitempty"`
	Items     []Choice `json:"items,omitempty"`
	MinItems  *int     `json:"minItems,omitempty"`
	MaxItems  *int     `json:"maxItems,omitempty"`
}

func (k PropertyKind) MarshalJSON() ([]byte, error) {
	return json.Marshal(map[string]KindBody{k.Type: k.KindBody})
}

func (k *PropertyKind) UnmarshalJSON(b []byte) error {
	var w map[string]KindBody
	if err := json.Unmarshal(b, &w); err != nil {
		return err
	}
	if len(w) != 1 {
		return fmt.Errorf("a property kind has one case")
	}
	for name, body := range w {
		*k = PropertyKind{Type: name, KindBody: body}
	}
	return nil
}

// Choice is ElicitationSchema.Property.Choice.
type Choice struct {
	Value       string  `json:"value"`
	Title       string  `json:"title"`
	Description *string `json:"description,omitempty"`
}

// AnswerElicitationRequest is DaemonAPI.AnswerElicitationRequest: elicitations/answer's request.
type AnswerElicitationRequest struct {
	RequestID string         `json:"requestID"`
	Action    string         `json:"action"`
	Content   map[string]any `json:"content"`
	SendID    string         `json:"sendID,omitempty"`
}
