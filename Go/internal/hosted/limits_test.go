package hosted

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// limited is a store held to p, on a memory store of its own.
func limited(p Plan) *limitedStore {
	return &limitedStore{Store: store.NewMemory(), account: "https://" + domain + "/account", plan: p}
}

// #2224 US5: machines and clients over the plan are refused with words that name the limit
// and the plan; a rewrite, and a record over a tombstone under the limit, are not.
func TestMachinesAndClientsHoldToThePlan(t *testing.T) {
	ctx := context.Background()
	l := limited(plans[PlanFree])
	for _, key := range []string{"v1/machines/a.json", "v1/machines/b.json"} {
		if _, err := l.Put(ctx, key, []byte(`{"id":"x"}`), store.Absent); err != nil {
			t.Fatal(key, err)
		}
	}
	_, err := l.Put(ctx, "v1/machines/c.json", []byte(`{"id":"c"}`), store.Absent)
	var limit *LimitError
	if !errors.As(err, &limit) || err.Error() != "Your Free plan allows 2 machines. Remove one, or upgrade at https://hosted.test/account." {
		t.Fatalf("%v", err)
	}
	if o, _ := l.Get(ctx, "v1/machines/c.json"); o != nil {
		t.Fatal("a refused machine was written")
	}
	// A rewrite of a machine there is not new.
	if _, err := l.Put(ctx, "v1/machines/a.json", []byte(`{"id":"a","name":"renamed"}`), store.Always); err != nil {
		t.Fatal(err)
	}
	// Forgotten: a tombstone does not count, and a new record may be written over one.
	if _, err := l.Put(ctx, "v1/machines/b.json", []byte(`{"forgotten":true}`), store.Always); err != nil {
		t.Fatal(err)
	}
	if _, err := l.Put(ctx, "v1/machines/c.json", []byte(`{"id":"c"}`), store.Absent); err != nil {
		t.Fatal(err)
	}
	if _, err := l.Put(ctx, "v1/machines/b.json", []byte(`{"id":"b"}`), store.Always); !errors.As(err, &limit) {
		t.Fatal("a record over a tombstone was let past the limit:", err)
	}
	for i := range 5 {
		if _, err := l.Put(ctx, "v1/clients/"+itoa(i)+".json", []byte(`{}`), store.Absent); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := l.Put(ctx, "v1/clients/9.json", []byte(`{}`), store.Absent); err == nil || !strings.Contains(err.Error(), "allows 5 clients") {
		t.Fatal(err)
	}
}

// #2224 US5: a write that grows the store past the plan is refused; one that grows nothing,
// and a delete, are not.
func TestStorageHoldsToThePlan(t *testing.T) {
	ctx := context.Background()
	p := plans[PlanFree]
	p.Storage = 1000
	l := limited(p)
	if _, err := l.Put(ctx, "v1/a.json", make([]byte, 600), store.Always); err != nil {
		t.Fatal(err)
	}
	_, err := l.Put(ctx, "v1/b.json", make([]byte, 600), store.Always)
	if err == nil || !strings.Contains(err.Error(), "allows 1000 bytes of storage. Delete something") {
		t.Fatal(err)
	}
	if _, err := l.Put(ctx, "v1/a.json", make([]byte, 500), store.Always); err != nil {
		t.Fatal("a smaller rewrite was refused:", err)
	}
	if l.used() != 500 {
		t.Fatal(l.used())
	}
	if err := l.Delete(ctx, "v1/a.json"); err != nil || l.used() != 0 {
		t.Fatal(err, l.used())
	}
	if _, err := l.Put(ctx, "v1/b.json", make([]byte, 600), store.Always); err != nil {
		t.Fatal(err)
	}
}

// countedGets counts reads of an account's objects, the ones a count of its bytes made.
type countedGets struct {
	store.Store
	gets atomic.Int64
}

func (c *countedGets) Get(ctx context.Context, key string) (*store.Object, error) {
	if strings.HasPrefix(key, accountsPrefix) && strings.Count(key, "/") > 1 {
		c.gets.Add(1)
	}
	return c.Store.Get(ctx, key)
}

// #3103: a start with no kept count counts the account's bytes from one listing, with no
// read of any object, so a large store does not hold the first request past its 30 s.
func TestACountReadsNoObject(t *testing.T) {
	ctx := context.Background()
	st := &countedGets{Store: store.NewMemory()}
	keeper := "base64key://" + base64.URLEncoding.EncodeToString(bytes.Repeat([]byte{3}, 32))
	s, err := New(ctx, Config{Store: st, Keeper: keeper, Domain: domain, Now: time.Now, MaxCopies: 10})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	acc, _, err := s.accounts.make(ctx, GitHubID{ID: 7, Login: "user"})
	if err != nil {
		t.Fatal(err)
	}
	own := accountStore(st.Store, acc.ID)
	for i := range 100 {
		if _, err := own.Put(ctx, "v1/events/2026-10-31/"+itoa(i)+".json", make([]byte, 10+i), store.Always); err != nil {
			t.Fatal(err)
		}
	}
	var want int64
	keys, _ := own.List(ctx, "")
	for _, k := range keys {
		o, _ := own.Get(ctx, k.Key)
		want += int64(len(o.Data))
	}
	st.gets.Store(0)
	l, err := s.limitedFor(ctx, acc)
	if err != nil {
		t.Fatal(err)
	}
	if l.used() != want {
		t.Fatal(l.used(), want)
	}
	if n := st.gets.Load(); n != 0 {
		t.Fatalf("the count read %d objects", n)
	}
}

// #2243: agents running at once holds to the plan too, with words that name the limit and
// the plan; under the limit, and a plan change, are not refused.
func TestAgentsRunningHoldsToThePlan(t *testing.T) {
	p := plans[PlanFree] // AgentsRunning: 3
	a := &agentsCap{plan: p, account: "https://" + domain + "/account"}
	if err := a.gate(2); err != nil {
		t.Fatal("under the limit was refused:", err)
	}
	err := a.gate(3)
	var limit *LimitError
	if !errors.As(err, &limit) || err.Error() != "Your Free plan allows 3 agents running at once. Wait for one to finish, or upgrade at https://hosted.test/account." {
		t.Fatalf("%v", err)
	}
	if err := a.gate(4); !errors.As(err, &limit) {
		t.Fatal("over the limit was not refused:", err)
	}
	// A plan change is read fresh, not cached.
	a.setPlan(plans[PlanPro]) // AgentsRunning: 30
	if err := a.gate(3); err != nil {
		t.Fatal("under the new plan's limit was refused:", err)
	}
}

// #2224 US5: the sweep deletes the days of events before the plan keeps.
func TestEventsPastThePlanGo(t *testing.T) {
	s, _, now, _ := idleService(t, 0)
	l := limited(plans[PlanFree])
	ctx := context.Background()
	old := now.Now().Add(-8 * day).Format("2006-01-02")
	kept := now.Now().Add(-6 * day).Format("2006-01-02")
	for _, key := range []string{"v1/events/" + old + "/1.json", "v1/events/" + old + "/2.json", "v1/events/" + kept + "/3.json"} {
		l.Put(ctx, key, []byte(`{}`), store.Always)
	}
	if n, err := s.sweepEvents(ctx, l); err != nil || n != 2 {
		t.Fatal(n, err)
	}
	if left, _ := l.List(ctx, "v1/events/"); len(left) != 1 || !strings.Contains(left[0].Key, kept) {
		t.Fatalf("%+v", left)
	}
	if l.used() != 2 {
		t.Fatal("the freed bytes were not counted:", l.used())
	}
}

// readsOf counts every read of an object.
type readsOf struct {
	store.Store
	gets atomic.Int64
}

func (r *readsOf) Get(ctx context.Context, key string) (*store.Object, error) {
	r.gets.Add(1)
	return r.Store.Get(ctx, key)
}

// #3105: an event write, a rewrite of a record this store wrote, and the sweep's deletes
// read no old object, and the bytes still come out right.
func TestWritesReadNoOldObject(t *testing.T) {
	s, _, now, _ := idleService(t, 0)
	ctx := context.Background()
	st := &readsOf{Store: store.NewMemory()}
	l := &limitedStore{Store: st, plan: plans[PlanFree]}
	old := now.Now().Add(-8 * day).Format("2006-01-02")
	for i := range 1000 {
		if _, err := l.Put(ctx, "v1/events/"+old+"/"+itoa(i)+".json", []byte(`{}`), store.Absent); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range []int{10, 30, 20} {
		if _, err := l.Put(ctx, "v1/copies/a.json", make([]byte, n), store.Always); err != nil {
			t.Fatal(err)
		}
	}
	if n := st.gets.Load(); n != 1 {
		t.Fatal("reads of old objects:", n)
	}
	if l.used() != 2000+20 {
		t.Fatal(l.used())
	}
	if n, err := s.sweepEvents(ctx, l); err != nil || n != 1000 {
		t.Fatal(n, err)
	}
	if err := l.Delete(ctx, "v1/copies/a.json"); err != nil {
		t.Fatal(err)
	}
	if n := st.gets.Load(); n != 1 || l.used() != 0 {
		t.Fatal("reads:", n, "bytes:", l.used())
	}
}

// #2224 US5: a machine joining a running copy over the plan is refused, and the control
// plane's error carries the words; the size survives the copy stopping.
func TestARunningCopyHoldsToItsPlan(t *testing.T) {
	s, _, _, ids := idleService(t, 1)
	ctx := context.Background()
	s.mu.Lock()
	c := s.copies[ids[0]]
	s.mu.Unlock()
	rs := c.service.Records()
	for _, h := range []string{"h1", "h2"} {
		if err := rs.AddHost(ctx, records.MachineRecord{ID: h, Name: h}); err != nil {
			t.Fatal(err)
		}
	}
	err := rs.AddHost(ctx, records.MachineRecord{ID: "h3", Name: "h3"})
	if err == nil || !strings.Contains(err.Error(), "Your Free plan allows 2 machines") {
		t.Fatal(err)
	}
	size := c.limits.used()
	if size == 0 {
		t.Fatal("no bytes counted")
	}
	s.stopCopy(ids[0])
	if kept := s.keptUsage(ctx, ids[0]); kept != size {
		t.Fatal(kept, size)
	}
	open(t, s, ids[0])
	s.mu.Lock()
	c = s.copies[ids[0]]
	s.mu.Unlock()
	if c.limits.used() < size {
		t.Fatal("the size was not kept across a stop:", c.limits.used(), size)
	}
	// A plan set by the operator reaches the running copy within a sweep.
	if err := (Admin{Store: s.cfg.Store}).SetPlan(ctx, ids[0], PlanPro); err != nil {
		t.Fatal(err)
	}
	s.sweepAccounts(ctx)
	if c.limits.planNow().ID != PlanPro {
		t.Fatal(c.limits.planNow())
	}
	if err := c.service.Records().AddHost(ctx, records.MachineRecord{ID: "h3", Name: "h3"}); err != nil {
		t.Fatal("a third machine on Pro:", err)
	}
}

// #2224 US5: WebSockets over the plan's connections get 429 and the words.
func TestConnectionsHoldToThePlan(t *testing.T) {
	s, browserFor := startWith(t, Config{Store: store.NewMemory(), SignUp: SignUpOpen})
	b := browserFor()
	to, _ := url.Parse(b.signIn("good").Header.Get("Location"))
	id := strings.TrimSuffix(to.Host, "."+domain)
	s.mu.Lock()
	c := s.copies[id]
	s.mu.Unlock()
	p := plans[PlanFree]
	p.Connections = 2
	c.limits.setPlan(p)
	connect := func() *http.Response {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, "https://"+to.Host+"/v1/connect", nil)
		for k, v := range map[string]string{"Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
			"Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="} {
			req.Header.Set(k, v)
		}
		res, err := b.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { res.Body.Close() })
		return res
	}
	for i := range 2 {
		if res := connect(); res.StatusCode != http.StatusSwitchingProtocols {
			t.Fatalf("socket %d: %d", i, res.StatusCode)
		}
	}
	res := connect()
	buf := new(bytes.Buffer)
	buf.ReadFrom(res.Body)
	if res.StatusCode != http.StatusTooManyRequests || res.Header.Get("Agents-Refusal") != "limit" ||
		!strings.Contains(buf.String(), "Your Free plan allows 2 connections at once. Close one") {
		t.Fatal(res.StatusCode, res.Header.Get("Agents-Refusal"), buf.String())
	}
	// The clients read the refusal's words back from /readyz (#3146).
	ready, err := b.client.Get("https://" + to.Host + "/readyz")
	if err != nil {
		t.Fatal(err)
	}
	buf.Reset()
	buf.ReadFrom(ready.Body)
	ready.Body.Close()
	if ready.Header.Get("Agents-Refusal") != "limit" || !strings.Contains(buf.String(), "Your Free plan allows 2 connections at once. Close one") {
		t.Fatal(ready.StatusCode, ready.Header.Get("Agents-Refusal"), buf.String())
	}
	// The account page shows the plan and its use.
	if _, page := b.get("https://" + domain + "/account"); !strings.Contains(page, "Free Plan") || !strings.Contains(page, "0 of 2") {
		t.Fatal(page)
	}
}

// #2224 SC-005: two accounts' records, policies and keys stay apart.
func TestAccountsStayApart(t *testing.T) {
	s, st, _, ids := idleService(t, 2)
	ctx := context.Background()
	s.mu.Lock()
	a, b := s.copies[ids[0]], s.copies[ids[1]]
	s.mu.Unlock()
	if _, err := a.limits.Put(ctx, "v1/policy.json", []byte(`{"mode":"acceptEdits"}`), store.Always); err != nil {
		t.Fatal(err)
	}
	if err := a.service.Records().AddHost(ctx, records.MachineRecord{ID: "ah", Name: "a's"}); err != nil {
		t.Fatal(err)
	}
	if o, _ := b.limits.Get(ctx, "v1/policy.json"); o != nil {
		t.Fatal("one account's policy is in another's store")
	}
	if b.service.Records().Host("ah") != nil {
		t.Fatal("one account's machine is another's")
	}
	if o, _ := st.Get(ctx, "accounts/"+ids[0]+"/v1/policy.json"); o == nil {
		t.Fatal("the policy is not in its account's prefix")
	}
	ka, _ := st.Get(ctx, "accounts/"+ids[0]+"/v1/keys/control.sealed")
	kb, _ := st.Get(ctx, "accounts/"+ids[1]+"/v1/keys/control.sealed")
	if ka == nil || kb == nil || bytes.Equal(ka.Data, kb.Data) {
		t.Fatal("the accounts' control keys are not their own")
	}
}
