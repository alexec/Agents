package whatsappmcp

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// The inbox (#1352): what people sent the number, as Meta's webhook calls give it, kept in
// order so that every events/poll, each with its own cursor, reads the same list. The server
// serves the webhook itself, checks each call's signature with the app's secret, and answers
// at once; Meta sends a call again until it is answered, so a message already in the inbox
// is not kept twice. The inbox keeps the newest maxKept for keptFor.

const (
	maxKept = 1000
	keptFor = 24 * time.Hour
	// maxBody is the largest webhook call read; Meta's are a few kilobytes.
	maxBody = 4 << 20
)

// Kind is what happened.
type Kind string

const (
	// Message: a person wrote to the number.
	Message Kind = "message"
	// Answer: a person pressed an option on a question the number asked (ask_question).
	Answer Kind = "answer"
)

// Person is who wrote, as WhatsApp names them: their number (wa_id) and their profile's name.
type Person struct {
	WaID string `json:"wa_id"`
	Name string `json:"name"`
}

// Item is one thing that happened, in the inbox's order.
type Item struct {
	Seq  uint64
	ID   string // the message's id, wamid.…
	Kind Kind
	At   time.Time
	// Type is WhatsApp's type of the message: text, button, interactive, image….
	Type string
	// Text is what the person wrote, or a media message's caption.
	Text string
	// ReplyTo is the message the person replied to, when they did: for an Answer, the question.
	ReplyTo string
	// Question, Answer and Label are an Answer's: the question's id, the option's id and words.
	Question, Answer, Label string
	From                    Person
}

// answerPrefix starts the id of each option of ask_question's buttons and lists:
// agents|<question>|<option>. A question's and an option's ids never hold a |.
const answerPrefix = "agents|"

func optionID(question, option string) string { return answerPrefix + question + "|" + option }

// webhook is the part of a Cloud API webhook call that the server reads.
type webhook struct {
	Object string `json:"object"`
	Entry  []struct {
		Changes []struct {
			Field string `json:"field"`
			Value struct {
				Metadata struct {
					PhoneNumberID string `json:"phone_number_id"`
				} `json:"metadata"`
				Contacts []struct {
					WaID    string `json:"wa_id"`
					Profile struct {
						Name string `json:"name"`
					} `json:"profile"`
				} `json:"contacts"`
				Messages []incoming `json:"messages"`
			} `json:"value"`
		} `json:"changes"`
	} `json:"entry"`
}

type caption struct {
	Caption string `json:"caption"`
}

type incoming struct {
	From      string `json:"from"`
	ID        string `json:"id"`
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Text      struct {
		Body string `json:"body"`
	} `json:"text"`
	Button struct {
		Text    string `json:"text"`
		Payload string `json:"payload"`
	} `json:"button"`
	Interactive struct {
		Type        string `json:"type"`
		ButtonReply struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"button_reply"`
		ListReply struct {
			ID    string `json:"id"`
			Title string `json:"title"`
		} `json:"list_reply"`
	} `json:"interactive"`
	Image    caption `json:"image"`
	Video    caption `json:"video"`
	Document caption `json:"document"`
	Context  struct {
		ID string `json:"id"`
	} `json:"context"`
}

// parse is a webhook call's messages to phoneNumberID as Items. What the server does not raise
// is left out: a status (sent, delivered, read), a message to another number of the account,
// and a message with no words (a sticker, a voice note, a location).
func parse(body []byte, phoneNumberID string) []Item {
	var w webhook
	if json.Unmarshal(body, &w) != nil || w.Object != "whatsapp_business_account" {
		return nil
	}
	out := []Item{}
	for _, e := range w.Entry {
		for _, c := range e.Changes {
			if c.Field != "messages" || c.Value.Metadata.PhoneNumberID != phoneNumberID {
				continue
			}
			names := map[string]string{}
			for _, contact := range c.Value.Contacts {
				names[contact.WaID] = contact.Profile.Name
			}
			for _, m := range c.Value.Messages {
				if it, ok := item(m, names); ok {
					out = append(out, it)
				}
			}
		}
	}
	return out
}

func item(m incoming, names map[string]string) (Item, bool) {
	if m.ID == "" || m.From == "" {
		return Item{}, false
	}
	it := Item{ID: m.ID, Kind: Message, Type: m.Type, ReplyTo: m.Context.ID, From: Person{WaID: m.From, Name: names[m.From]}, At: time.Now()}
	if secs, err := strconv.ParseInt(m.Timestamp, 10, 64); err == nil && secs > 0 {
		it.At = time.Unix(secs, 0)
	}
	switch m.Type {
	case "text":
		it.Text = m.Text.Body
	case "button":
		it.Text = m.Button.Text // a template's quick reply
	case "image":
		it.Text = m.Image.Caption
	case "video":
		it.Text = m.Video.Caption
	case "document":
		it.Text = m.Document.Caption
	case "interactive":
		id, label := m.Interactive.ButtonReply.ID, m.Interactive.ButtonReply.Title
		if m.Interactive.Type == "list_reply" {
			id, label = m.Interactive.ListReply.ID, m.Interactive.ListReply.Title
		}
		rest, ours := strings.CutPrefix(id, answerPrefix)
		question, answer, split := strings.Cut(rest, "|")
		if !ours || !split || question == "" || answer == "" {
			return Item{}, false
		}
		it.Kind, it.Question, it.Answer, it.Label, it.Text = Answer, question, answer, label, label
		return it, true
	}
	it.Text = strings.TrimSpace(it.Text)
	return it, it.Text != ""
}

// signed is true when signature (X-Hub-Signature-256: sha256=<hex>) is body's HMAC with secret.
func signed(body []byte, signature, secret string) bool {
	hexSum, ok := strings.CutPrefix(strings.TrimSpace(signature), "sha256=")
	if !ok {
		return false
	}
	got, err := hex.DecodeString(hexSum)
	if err != nil {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return hmac.Equal(got, mac.Sum(nil))
}

// Inbox serves the webhook and keeps what it was sent.
type Inbox struct {
	Account func() (Account, error)
	Logger  *slog.Logger
	// Seen is told of each new item as it comes, to mark it read. It runs on its own, so the
	// webhook answers at once.
	Seen func(context.Context, Item)

	mu       sync.Mutex
	items    []Item
	seq      uint64
	started  bool
	failure  error
	boot     string
	ctx      context.Context
	listened chan struct{}
}

// NewInbox is an inbox; boot tells a cursor of this run from one of an earlier run.
func NewInbox(account func() (Account, error), logger *slog.Logger) *Inbox {
	return &Inbox{Account: account, Logger: logger, boot: time.Now().UTC().Format("20060102T150405.000000000"),
		ctx: context.Background(), listened: make(chan struct{})}
}

// Start serves the webhook on the account's address, once; it ends with ctx. When the address
// cannot be listened on (another server has it), it tries again, more slowly each time.
func (in *Inbox) Start(ctx context.Context) {
	in.mu.Lock()
	if in.started {
		in.mu.Unlock()
		return
	}
	in.started, in.ctx = true, ctx
	in.mu.Unlock()
	go in.loop(ctx)
}

// Listening is closed once the webhook listens.
func (in *Inbox) Listening() <-chan struct{} { return in.listened }

func (in *Inbox) loop(ctx context.Context) {
	wait := time.Second
	once := sync.Once{}
	for ctx.Err() == nil {
		err := in.serve(ctx, func() { once.Do(func() { close(in.listened) }) })
		if ctx.Err() != nil {
			return
		}
		in.setFailure(err)
		if in.Logger != nil {
			in.Logger.Warn("whatsapp-mcp: webhook", "err", err)
		}
		select {
		case <-ctx.Done():
		case <-time.After(wait):
		}
		wait = min(2*wait, time.Minute)
	}
}

// serve listens and serves until ctx ends or the server fails.
func (in *Inbox) serve(ctx context.Context, listening func()) error {
	a, err := in.Account()
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", a.Addr)
	if err != nil {
		return fmt.Errorf("the webhook cannot listen on %s (WHATSAPP_WEBHOOK_ADDR): %w", a.Addr, err)
	}
	in.setFailure(nil)
	listening()
	srv := &http.Server{Handler: in, ReadHeaderTimeout: 10 * time.Second, ReadTimeout: time.Minute, WriteTimeout: time.Minute, IdleTimeout: 2 * time.Minute}
	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()
	if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("the webhook on %s: %w", a.Addr, err)
	}
	return nil
}

// ServeHTTP is the webhook: GET is Meta's check when it is set up, POST a call with messages.
func (in *Inbox) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	a, err := in.Account()
	if err != nil {
		http.Error(w, "not connected", http.StatusServiceUnavailable)
		return
	}
	switch r.Method {
	case http.MethodGet:
		q := r.URL.Query()
		if q.Get("hub.mode") != "subscribe" || subtle.ConstantTimeCompare([]byte(q.Get("hub.verify_token")), []byte(a.VerifyToken)) != 1 {
			http.Error(w, "the verify token does not match WHATSAPP_VERIFY_TOKEN", http.StatusForbidden)
			return
		}
		// Meta's challenge is a number; nothing else is said back.
		challenge, err := strconv.ParseUint(q.Get("hub.challenge"), 10, 64)
		if err != nil {
			http.Error(w, "hub.challenge is not a number", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		_, _ = io.WriteString(w, strconv.FormatUint(challenge, 10))
	case http.MethodPost:
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			http.Error(w, "too large", http.StatusRequestEntityTooLarge)
			return
		}
		if !signed(body, r.Header.Get("X-Hub-Signature-256"), a.AppSecret) {
			if in.Logger != nil {
				in.Logger.Warn("whatsapp-mcp: a webhook call whose signature is not the app secret's; check WHATSAPP_APP_SECRET")
			}
			http.Error(w, "the signature does not match", http.StatusUnauthorized)
			return
		}
		in.keep(parse(body, a.PhoneNumberID))
		w.WriteHeader(http.StatusOK)
	default:
		http.Error(w, "GET or POST", http.StatusMethodNotAllowed)
	}
}

// keep puts new items in the inbox, and tells Seen of each.
func (in *Inbox) keep(got []Item) {
	kept := []Item{}
	in.mu.Lock()
	for _, it := range got {
		if in.has(it.ID) || it.Kind == Answer && in.answered(it.Question) {
			continue
		}
		in.seq++
		it.Seq = in.seq
		in.items = append(in.items, it)
		kept = append(kept, it)
	}
	in.trim(time.Now())
	ctx := in.ctx
	in.mu.Unlock()
	if in.Seen == nil {
		return
	}
	for _, it := range kept {
		go func() {
			c, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			in.Seen(c, it)
		}()
	}
}

// has is true when the inbox holds the message already (Meta sent the call again).
func (in *Inbox) has(id string) bool {
	for _, it := range in.items {
		if it.ID == id {
			return true
		}
	}
	return false
}

// answered is true when the inbox holds an answer to the question already: only the first
// press counts, as WhatsApp keeps the buttons after a press.
func (in *Inbox) answered(question string) bool {
	for _, it := range in.items {
		if it.Kind == Answer && it.Question == question {
			return true
		}
	}
	return false
}

func (in *Inbox) trim(now time.Time) {
	drop := max(0, len(in.items)-maxKept)
	for drop < len(in.items) && now.Sub(in.items[drop].At) > keptFor {
		drop++
	}
	if drop > 0 {
		in.items = append([]Item(nil), in.items[drop:]...)
	}
}

func (in *Inbox) setFailure(err error) {
	in.mu.Lock()
	in.failure = err
	in.mu.Unlock()
}

// Head is this run's boot and the newest item's number.
func (in *Inbox) Head() (string, uint64) {
	in.mu.Lock()
	defer in.mu.Unlock()
	return in.boot, in.seq
}

// After is the items after seq, at most limit, whether there are more, and the webhook's
// failure.
func (in *Inbox) After(seq uint64, limit int) ([]Item, bool, error) {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := []Item{}
	for _, it := range in.items {
		if it.Seq <= seq {
			continue
		}
		if len(out) == limit {
			return out, true, in.failure
		}
		out = append(out, it)
	}
	return out, false, in.failure
}

// Newest is the newest messages, newest first, at most limit; only one person's when from is
// set.
func (in *Inbox) Newest(from string, limit int) []Item {
	in.mu.Lock()
	defer in.mu.Unlock()
	out := []Item{}
	for i := len(in.items) - 1; i >= 0 && len(out) < limit; i-- {
		if from == "" || in.items[i].From.WaID == from {
			out = append(out, in.items[i])
		}
	}
	return out
}

// Failure is the webhook's failure, nil when it listens.
func (in *Inbox) Failure() error {
	in.mu.Lock()
	defer in.mu.Unlock()
	return in.failure
}
