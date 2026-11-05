package googlechatmcp

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeGoogle is Pub/Sub and the Chat API on this machine, as googlechat-mcp calls them: a
// subscription to pull and acknowledge, the app's spaces, and its messages posted and edited.
type fakeGoogle struct {
	t   *testing.T
	srv *httptest.Server

	mu     sync.Mutex
	queue  []map[string]any // waiting to be pulled
	acked  []string
	posted []map[string]any
	edited []map[string]any
	nextID int
	refuse int // the status every call gets, when set
	pulled chan struct{}
	spaces []map[string]any
}

const fakeSubscription = "projects/agents-fake/subscriptions/agents-chat"

func newFakeGoogle(t *testing.T) *fakeGoogle {
	f := &fakeGoogle{t: t, pulled: make(chan struct{}, 100),
		spaces: []map[string]any{{"name": "spaces/AAA", "displayName": "Team", "spaceType": "SPACE"}, {"name": "spaces/DM1", "spaceType": "DIRECT_MESSAGE"}}}
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeGoogle) account() Account {
	return Account{Subscription: fakeSubscription, ChatURL: f.srv.URL + "/", PubSubURL: f.srv.URL + "/"}
}

func (f *fakeGoogle) google() *Google {
	return &Google{Account: func() (Account, error) { return f.account(), nil }}
}

// send queues a Chat event as Pub/Sub gives it.
func (f *fakeGoogle) send(event map[string]any) string {
	data, _ := json.Marshal(event)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nextID++
	id := fmt.Sprintf("%d", 1000+f.nextID)
	f.queue = append(f.queue, map[string]any{"ackId": "ack-" + id, "message": map[string]any{
		"messageId": id, "publishTime": time.Now().UTC().Format(time.RFC3339Nano), "data": base64.StdEncoding.EncodeToString(data)}})
	return id
}

func (f *fakeGoogle) serve(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	var in map[string]any
	_ = json.Unmarshal(body, &in)
	f.mu.Lock()
	refuse := f.refuse
	f.mu.Unlock()
	if refuse != 0 {
		w.WriteHeader(refuse)
		_, _ = w.Write([]byte(`{"error":{"code":` + fmt.Sprint(refuse) + `,"message":"refused"}}`))
		return
	}
	answer := func(v any) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(v)
	}
	path := r.URL.Path
	switch {
	case r.Method == http.MethodPost && path == "/v1/"+fakeSubscription+":pull":
		f.mu.Lock()
		got := f.queue
		f.queue = nil
		f.mu.Unlock()
		if len(got) == 0 {
			select {
			case <-r.Context().Done():
			case <-time.After(50 * time.Millisecond):
			}
		}
		select {
		case f.pulled <- struct{}{}:
		default:
		}
		answer(map[string]any{"receivedMessages": got})
	case r.Method == http.MethodPost && path == "/v1/"+fakeSubscription+":acknowledge":
		f.mu.Lock()
		for _, id := range in["ackIds"].([]any) {
			f.acked = append(f.acked, id.(string))
		}
		f.mu.Unlock()
		answer(map[string]any{})
	case r.Method == http.MethodGet && path == "/v1/spaces":
		answer(map[string]any{"spaces": f.spaces})
	case r.Method == http.MethodPost && strings.HasPrefix(path, "/v1/spaces/") && strings.HasSuffix(path, "/messages"):
		space := strings.TrimSuffix(strings.TrimPrefix(path, "/v1/"), "/messages")
		f.mu.Lock()
		f.nextID++
		name := fmt.Sprintf("%s/messages/m%d", space, f.nextID)
		in["_name"], in["_replyOption"] = name, r.URL.Query().Get("messageReplyOption")
		f.posted = append(f.posted, in)
		f.mu.Unlock()
		thread := space + "/threads/t1"
		if th, ok := in["thread"].(map[string]any); ok {
			thread = th["name"].(string)
		}
		answer(map[string]any{"name": name, "thread": map[string]any{"name": thread}})
	case r.Method == http.MethodPatch && strings.HasPrefix(path, "/v1/spaces/"):
		f.mu.Lock()
		in["_name"], in["_mask"] = strings.TrimPrefix(path, "/v1/"), r.URL.Query().Get("updateMask")
		f.edited = append(f.edited, in)
		f.mu.Unlock()
		answer(in)
	default:
		f.t.Errorf("fake Google: %s %s", r.Method, r.URL)
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *fakeGoogle) snapshot() (acked []string, posted, edited []map[string]any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.acked...), append([]map[string]any(nil), f.posted...), append([]map[string]any(nil), f.edited...)
}

// chatEvent is a Chat app's interaction event.
func chatEvent(kind, space, spaceType string, user map[string]any, extra map[string]any) map[string]any {
	e := map[string]any{"type": kind, "eventTime": time.Now().UTC().Format(time.RFC3339Nano),
		"space": map[string]any{"name": space, "spaceType": spaceType, "displayName": "Team"}, "user": user}
	for k, v := range extra {
		e[k] = v
	}
	return e
}

var sam = map[string]any{"name": "users/111", "displayName": "Sam", "email": "Sam@Example.com", "type": "HUMAN"}
