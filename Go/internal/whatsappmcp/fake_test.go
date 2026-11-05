package whatsappmcp

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"
)

// fakeMeta is the Cloud API on this machine, as whatsapp-mcp calls it: messages sent, and
// messages marked read.
type fakeMeta struct {
	t   *testing.T
	srv *httptest.Server

	mu     sync.Mutex
	sent   []map[string]any
	read   []string
	nextID int
	// refuse, when set, is the status and the error every call gets.
	refuse     int
	refuseCode int
}

const (
	fakePhoneNumberID = "106540352242922"
	fakeSecret        = "app-secret"
	fakeVerify        = "a-word-of-my-own"
)

func newFakeMeta(t *testing.T) *fakeMeta {
	f := &fakeMeta{t: t}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeMeta) account() Account {
	return Account{Token: "token", PhoneNumberID: fakePhoneNumberID, AppSecret: fakeSecret, VerifyToken: fakeVerify, Addr: "127.0.0.1:0", APIURL: f.srv.URL + "/v24.0"}
}

func (f *fakeMeta) accountFunc() func() (Account, error) {
	return func() (Account, error) { return f.account(), nil }
}

func (f *fakeMeta) meta() *Meta { return &Meta{Account: f.accountFunc()} }

func (f *fakeMeta) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var in map[string]any
	_ = json.Unmarshal(body, &in)
	if r.Method != http.MethodPost || r.URL.Path != "/v24.0/"+fakePhoneNumberID+"/messages" || r.Header.Get("Authorization") != "Bearer token" {
		f.t.Errorf("fake Meta: %s %s %q", r.Method, r.URL, r.Header.Get("Authorization"))
		w.WriteHeader(http.StatusNotFound)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.refuse != 0 {
		w.WriteHeader(f.refuse)
		_, _ = fmt.Fprintf(w, `{"error":{"message":"refused","type":"OAuthException","code":%d,"error_data":{"details":"why"}}}`, f.refuseCode)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	if in["status"] == "read" {
		f.read = append(f.read, in["message_id"].(string))
		_, _ = w.Write([]byte(`{"success":true}`))
		return
	}
	f.nextID++
	f.sent = append(f.sent, in)
	_ = json.NewEncoder(w).Encode(map[string]any{"messaging_product": "whatsapp",
		"contacts": []any{map[string]any{"input": in["to"], "wa_id": in["to"]}}, "messages": []any{map[string]any{"id": "wamid.SENT" + strconv.Itoa(f.nextID)}}})
}

func (f *fakeMeta) snapshot() (sent []map[string]any, read []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]map[string]any(nil), f.sent...), append([]string(nil), f.read...)
}

// call is one webhook call with messages to the number, as Meta sends it.
func call(phoneNumberID string, contacts []map[string]any, messages ...map[string]any) []byte {
	cs := []any{}
	for _, c := range contacts {
		cs = append(cs, map[string]any{"wa_id": c["wa_id"], "profile": map[string]any{"name": c["name"]}})
	}
	ms := []any{}
	for _, m := range messages {
		ms = append(ms, m)
	}
	data, _ := json.Marshal(map[string]any{"object": "whatsapp_business_account", "entry": []any{map[string]any{"id": "WABA1", "changes": []any{
		map[string]any{"field": "messages", "value": map[string]any{"messaging_product": "whatsapp",
			"metadata": map[string]any{"display_phone_number": "15550001111", "phone_number_id": phoneNumberID},
			"contacts": cs, "messages": ms}},
	}}}})
	return data
}

func text(id, from, body string) map[string]any {
	return map[string]any{"from": from, "id": id, "timestamp": strconv.FormatInt(time.Now().Unix(), 10), "type": "text", "text": map[string]any{"body": body}}
}

func pressed(id, from, kind, optionID, title, question string) map[string]any {
	reply := map[string]any{"type": kind}
	reply[kind] = map[string]any{"id": optionID, "title": title}
	return map[string]any{"from": from, "id": id, "timestamp": strconv.FormatInt(time.Now().Unix(), 10), "type": "interactive",
		"interactive": reply, "context": map[string]any{"from": "15550001111", "id": question}}
}

func signature(body []byte, secret string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write(body)
	return "sha256=" + hex.EncodeToString(mac.Sum(nil))
}

// deliver posts body to the inbox's webhook, signed with secret, and gives the status.
func deliver(in *Inbox, body []byte, secret string) int {
	r := httptest.NewRequest(http.MethodPost, "/webhook", bytes.NewReader(body))
	if secret != "" {
		r.Header.Set("X-Hub-Signature-256", signature(body, secret))
	}
	w := httptest.NewRecorder()
	in.ServeHTTP(w, r)
	return w.Code
}

var sam = map[string]any{"wa_id": "15551234567", "name": "Sam"}
