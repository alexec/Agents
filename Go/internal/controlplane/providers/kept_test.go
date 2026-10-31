package providers

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Start a machine by using it (#691 US3): a prompt or an agent start for a stopped host
// is kept, starts it, and goes once the host connects. Ports KeptRequestsTests.swift; the
// router's part (a client's line, a host's uplink) is the fake router's.

// keptHost is KeptHost: a host's end that answers each request, a start with a new agent's
// id, and remembers what it was sent.
type keptHost struct {
	mu     sync.Mutex
	heard  []delivered
	made   string
	refuse string
}

func (h *keptHost) answer(host, method string, params json.RawMessage) *Reply {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.heard = append(h.heard, delivered{host: host, method: method, params: params})
	switch {
	case method == MethodAgentsStart:
		return &Reply{Result: rawOf(h.made)}
	case h.refuse != "":
		return &Reply{Error: &Failure{Code: -32004, Message: h.refuse}}
	}
	return &Reply{Result: json.RawMessage(`{}`)}
}

func (h *keptHost) requests() []delivered {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]delivered{}, h.heard...)
}

func (h *harness) keeper() *Kept { return NewKeptFor(h.providers, nil) }

// connectHost is the host's uplink coming up: the router answers for it, and tells the
// keeper, as ControlRouter.attachHost does.
func (h *harness) connectHost(kept *Kept) *keptHost {
	host := &keptHost{made: records.NewUUID()}
	h.router.mu.Lock()
	h.router.answer = host.answer
	h.router.mu.Unlock()
	h.router.setOnline(devbox, true)
	go kept.Attached(devbox)
	return host
}

func promptParams(text string) json.RawMessage {
	return rawOf(map[string]string{"agentID": records.NewUUID(), "text": text})
}

func keptSummary(t *testing.T, f *Failure) KeptRequest {
	t.Helper()
	if f == nil || f.Code != CodeKept {
		t.Fatalf("not kept: %v", f)
	}
	var s KeptRequest
	if err := json.Unmarshal(f.Data, &s); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestAPromptForAStoppedHostIsKeptStartsItAndGoesOnceItConnects(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	f := kept.Keep(devbox, MethodAgentsPrompt, promptParams("run the migration again"), h.caller)
	if f == nil || f.Message != "devbox is starting. This is sent when it connects." {
		t.Fatalf("%v", f)
	}
	if keptSummary(t, f).Text != "run the migration again" {
		t.Error("text")
	}
	h.waitFor("starting", devbox, 5, nil)
	// The row says starting before the call reaches the provider, as in Swift.
	eventually(t, func() bool { starts, _ := h.provider.count(); return starts == 1 })
	if starts, _ := h.provider.count(); starts != 1 || len(kept.All()) != 1 {
		t.Errorf("starts %d, kept %d", starts, len(kept.All()))
	}
	host := h.connectHost(kept)
	eventually(t, func() bool { return len(kept.All()) == 0 })
	requests := host.requests()
	if len(requests) != 1 || requests[0].method != MethodAgentsPrompt {
		t.Fatalf("%+v", requests)
	}
	// An id the host dedupes by, as the client sent none.
	var params map[string]any
	json.Unmarshal(requests[0].params, &params)
	if !isUUID(strOr(params["sendID"])) {
		t.Errorf("%v", params)
	}
	if !eventually(t, func() bool { return h.router.heard(NoticeKeptDelivered) }) {
		t.Error("not said delivered")
	}
	// Sent as the client that asked.
	if d := h.router.deliveries()[0]; d.client != strings.ToUpper(h.caller.Client) || d.kind != "mac" {
		t.Errorf("%+v", d)
	}
}

func TestAKeptStartSaysWhichAgentItMade(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	start := map[string]any{"runtimeID": "claude", "cwd": "file:///home/alex/app", "prompt": "fix the login", "draftID": records.NewUUID()}
	s := keptSummary(t, kept.Keep(devbox, MethodAgentsStart, rawOf(start), h.caller))
	if s.Kind != "start" || deref(s.Folder) != "file:///home/alex/app" || deref(s.RuntimeID) != "claude" || s.Text != "fix the login" {
		t.Errorf("%+v", s)
	}
	host := h.connectHost(kept)
	if !eventually(t, func() bool { return h.router.heard(host.made) }) {
		t.Error("the agent it made was not said")
	}
	var sent map[string]any
	json.Unmarshal(host.requests()[0].params, &sent)
	if !isUUID(strOr(sent["requestID"])) {
		t.Error("no requestID")
	}
	// The draft was a runtime on the host before it stopped; there is none now.
	if _, ok := sent["draftID"]; ok {
		t.Error("draftID sent")
	}
}

func TestWhatIsKeptOutlivesARestartOfTheControlPlane(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	kept.Keep(devbox, MethodAgentsPrompt, promptParams("one"), h.caller)
	time.Sleep(2 * time.Millisecond)
	kept.Keep(devbox, MethodAgentsPrompt, promptParams("two"), h.caller)
	again := h.keeper()
	var texts []string
	for _, k := range again.All() {
		texts = append(texts, k.Text)
	}
	if !reflect.DeepEqual(texts, []string{"one", "two"}) {
		t.Fatalf("%v", texts)
	}
	host := h.connectHost(again)
	eventually(t, func() bool { return len(host.requests()) == 2 })
	var sent []string
	for _, r := range host.requests() {
		var p map[string]any
		json.Unmarshal(r.params, &p)
		sent = append(sent, strOr(p["text"]))
	}
	if !reflect.DeepEqual(sent, []string{"one", "two"}) {
		t.Errorf("%v", sent)
	}
}

func TestADroppedPromptIsNotSentAndTheStartGoesOn(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	s := keptSummary(t, kept.Keep(devbox, MethodAgentsPrompt, promptParams("never"), h.caller))
	h.must(MethodHostsDropKept, KeptRequestID{Host: devbox, ID: s.ID})
	if len(kept.All()) != 0 || h.row(devbox).State != "starting" {
		t.Errorf("%v %+v", kept.All(), h.row(devbox))
	}
	host := h.connectHost(kept)
	time.Sleep(200 * time.Millisecond)
	if len(host.requests()) != 0 {
		t.Error("sent")
	}
}

func TestTwentyArePlentyForOneHost(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	for range KeptLimit {
		if f := kept.Keep(devbox, MethodAgentsPrompt, promptParams("n"), h.caller); f == nil || f.Code != CodeKept {
			t.Fatalf("%v", f)
		}
	}
	f := kept.Keep(devbox, MethodAgentsPrompt, promptParams("more"), h.caller)
	if f == nil || f.Code != CodeHostOffline || f.Message != "devbox is starting; too many prompts are waiting." {
		t.Errorf("%v", f)
	}
}

func TestAReadIsNeverKept(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	if f := kept.Keep(devbox, "agents/transcript", rawOf(map[string]string{"agentID": records.NewUUID()}), h.caller); f != nil {
		t.Errorf("%v", f)
	}
	// The router answers it with the offline refusal, which says it is stopped (FR-022).
	if OfflineRefusal(h.router.workspace(devbox)).Message != "That machine is stopped. Start it to reach it." {
		t.Error("refusal")
	}
	if starts, _ := h.provider.count(); starts != 0 {
		t.Error("started")
	}
}

func TestWithStartWhenUsedOffAPromptIsRefusedAsToday(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	off := false
	h.must(MethodHostsSetOptions, MachineOptions{Host: devbox, StartWhenUsed: &off})
	kept := h.keeper()
	if f := kept.Keep(devbox, MethodAgentsPrompt, promptParams("hello"), h.caller); f != nil {
		t.Errorf("%v", f)
	}
	if starts, _ := h.provider.count(); starts != 0 {
		t.Error("started")
	}
}

func TestAFailedStartLeavesWhatWasKeptNotSentWithWhyAndTryAgainStartsAgain(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	h.provider.set("", "Error: droplet is locked", 0)
	kept := h.keeper()
	s := keptSummary(t, kept.Keep(devbox, MethodAgentsPrompt, promptParams("go"), h.caller))
	eventually(t, func() bool { return deref(kept.All()[0].Failed) != "" })
	if deref(kept.All()[0].Failed) != "Couldn’t start devbox: Error: droplet is locked" {
		t.Errorf("%q", deref(kept.All()[0].Failed))
	}
	h.provider.set("", "", 0)
	h.must(MethodHostsRetryKept, KeptRequestID{Host: devbox, ID: s.ID})
	if deref(kept.All()[0].Failed) != "" {
		t.Error("still failed")
	}
	h.waitFor("starting", devbox, 5, func(r row) bool { return deref(r.Workspace.Phase) == "connecting" })
	if starts, _ := h.provider.count(); starts != 2 {
		t.Errorf("starts %d", starts)
	}
}

func TestAPromptTheHostRefusesIsShownNotSentInItsWords(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	kept.Keep(devbox, MethodAgentsPrompt, promptParams("go"), h.caller)
	host := &keptHost{refuse: "Its folder has gone."}
	h.router.mu.Lock()
	h.router.answer = host.answer
	h.router.mu.Unlock()
	h.router.setOnline(devbox, true)
	go kept.Attached(devbox)
	eventually(t, func() bool { return deref(kept.All()[0].Failed) != "" })
	if deref(kept.All()[0].Failed) != "Its folder has gone." {
		t.Errorf("%q", deref(kept.All()[0].Failed))
	}
}

func TestARemovedHostTakesWhatWasKeptForIt(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	kept.Keep(devbox, MethodAgentsPrompt, promptParams("go"), h.caller)
	kept.Forget(devbox)
	keys, _ := h.store.List(context.Background(), KeptPrefix)
	if len(kept.All()) != 0 || len(keys) != 0 {
		t.Errorf("%v %v", kept.All(), keys)
	}
}

func TestAClientWhoseHostLinkClosedKeepsThroughTheControlPlane(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	_, err := h.call(MethodHostsKeep, KeepRequest{Host: devbox, Method: MethodAgentsPrompt, Params: promptParams("hello")})
	if f := failureOf(err); f == nil || f.Code != CodeKept || len(kept.All()) != 1 || kept.All()[0].Text != "hello" {
		t.Fatalf("%v", err)
	}
	// Any other method is the host's own, and is refused.
	_, err = h.call(MethodHostsKeep, KeepRequest{Host: devbox, Method: "agents/transcript", Params: json.RawMessage(`{}`)})
	if f := failureOf(err); f == nil || f.Code != CodeHostOffline {
		t.Errorf("%v", err)
	}
}

func TestAKeptRecordIsStoredAsSwiftStoresIt(t *testing.T) {
	h := newHarness(t)
	h.link(h.add(), devbox, "agents-devbox")
	kept := h.keeper()
	kept.Keep(devbox, MethodAgentsPrompt, promptParams("go"), h.caller)
	keys, _ := h.store.List(context.Background(), KeptPrefix+devbox+"/")
	if len(keys) != 1 || !strings.HasSuffix(keys[0].Key, ".json") {
		t.Fatalf("%v", keys)
	}
	object, _ := h.store.Get(context.Background(), keys[0].Key)
	var stored map[string]any
	json.Unmarshal(object.Data, &stored)
	for _, key := range []string{"id", "host", "method", "params", "client", "clientKind", "at"} {
		if _, ok := stored[key]; !ok {
			t.Errorf("no %s in %s", key, object.Data)
		}
	}
	if at, _ := stored["at"].(string); !strings.HasSuffix(at, "Z") {
		t.Errorf("at %v", stored["at"])
	}
}

// personRouter is the fake router that tells each person their own: what each was told.
type personRouter struct {
	*fakeRouter
	toldTo map[string][]string
}

func (r *personRouter) BroadcastControlEach(method string, params func(person string) any) {
	for _, person := range []string{"ann", "bob"} {
		r.TellPerson(person, method, params(person))
	}
}

func (r *personRouter) TellPerson(person, method string, params any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.toldTo[person] = append(r.toldTo[person], method+" "+string(rawOf(params)))
}

func (r *personRouter) told(person string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return strings.Join(r.toldTo[person], "\n")
}

// What is kept for a host is its owner's alone: no one else lists it, drops it, tries it
// again or is told of it (FR-018, FR-019).
func TestWhatIsKeptIsShownToTheHostsOwnerAlone(t *testing.T) {
	h := newHarness(t)
	for i, host := range []string{devbox, other} {
		record := keptRecord{ID: records.NewUUID(), Host: host, Method: MethodAgentsPrompt,
			Params: promptParams("secret of " + host), Client: records.NewUUID(), ClientKind: "mac",
			At: records.Stamp{Time: time.Now()}}
		data, err := records.Encode(record)
		if err != nil {
			t.Fatal(err)
		}
		key := KeptPrefix + host + "/" + sequence(time.Now().Add(time.Duration(i)*time.Millisecond)) + ".json"
		if _, err := h.store.Put(context.Background(), key, data, store.Always); err != nil {
			t.Fatal(err)
		}
	}
	owners := map[string]string{devbox: "ann", other: "bob"}
	router := &personRouter{fakeRouter: h.router, toldTo: map[string][]string{}}
	kept := NewKept(h.store, router, KeptHooks{Start: func(string, string) {}, OwnerOf: func(host string) string { return owners[host] }}, nil)

	list := func(person string) []KeptRequest {
		t.Helper()
		answer, err := kept.Answer(MethodHostsListKept, nil, person)
		if err != nil {
			t.Fatal(err)
		}
		return answer.(KeptList).Kept
	}
	ann := list("ann")
	if len(ann) != 1 || string(ann[0].Host) != devbox || ann[0].Text != "secret of "+devbox {
		t.Fatalf("ann sees %+v", ann)
	}
	if bob := list("bob"); len(bob) != 1 || string(bob[0].Host) != other {
		t.Fatalf("bob sees %+v", bob)
	}
	if eve := list("eve"); len(eve) != 0 {
		t.Fatalf("eve sees %+v", eve)
	}

	which := rawOf(KeptRequestID{Host: ann[0].Host, ID: ann[0].ID})
	for _, method := range []string{MethodHostsDropKept, MethodHostsRetryKept} {
		if _, err := kept.Answer(method, which, "bob"); err == nil {
			t.Errorf("bob's %s of ann's was not refused", method)
		}
	}
	if len(list("ann")) != 1 {
		t.Fatal("bob dropped ann's")
	}

	// Delivered: told to the owner alone, and so is what is left.
	h.router.mu.Lock()
	h.router.answer = (&keptHost{}).answer
	h.router.mu.Unlock()
	kept.Attached(devbox)
	if len(list("ann")) != 0 {
		t.Fatal("not delivered")
	}
	if !strings.Contains(router.told("ann"), NoticeKeptDelivered) || !strings.Contains(router.told("ann"), NoticeKeptChanged) {
		t.Errorf("ann was told %q", router.told("ann"))
	}
	if told := router.told("bob"); strings.Contains(told, devbox) || strings.Contains(told, NoticeKeptDelivered) {
		t.Errorf("bob was told %q", told)
	}
	if h.router.heard(NoticeKeptChanged) || h.router.heard(NoticeKeptDelivered) {
		t.Error("told to everyone")
	}
}
