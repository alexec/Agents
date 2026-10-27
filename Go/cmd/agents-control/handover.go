package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// handoverLink is Handover.Link: a handover session with one copy, dialled and proved as
// x:handover-<id> with the copies' key, which only the control plane's key gives.
type handoverLink struct {
	lines *controllink.Lines
	next  int
}

func dialHandover(ctx context.Context, base, pin string, key []byte) (*handoverLink, error) {
	public, err := controllink.PublicKey(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, 4)
	rand.Read(nonce)
	lines, _, err := controllink.Join(ctx, base, pin, controllink.Credentials{
		Identity: "x:handover-" + hex.EncodeToString(nonce), Key: controllink.CopyKey(key), Kind: "copy", ControlKey: public})
	if err != nil {
		return nil, err
	}
	return &handoverLink{lines: lines, next: 1}, nil
}

// rpcFailure is a copy's refusal, in its own words.
type rpcFailure struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (f *rpcFailure) Error() string { return f.Message }

func (l *handoverLink) call(method string, params any) (json.RawMessage, error) {
	id := l.next
	l.next++
	if params == nil {
		params = map[string]any{}
	}
	line, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := l.lines.Write(ctx, string(line)); err != nil {
		return nil, err
	}
	for {
		text, err := l.lines.Read(ctx)
		if err != nil {
			return nil, fmt.Errorf("the copy stopped answering: %w", err)
		}
		var m struct {
			ID     *int            `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *rpcFailure     `json:"error"`
		}
		if json.Unmarshal([]byte(text), &m) != nil || m.ID == nil || *m.ID != id {
			continue
		}
		if m.Error != nil {
			return nil, m.Error
		}
		return m.Result, nil
	}
}

// peerStore is PeerStore: a copy's store over its handover session, read from a frozen
// copy and written into a receiving one, so CopyStore runs between two machines.
type peerStore struct{ link *handoverLink }

func (p peerStore) Get(_ context.Context, key string) (*store.Object, error) {
	reply, err := p.link.call("store/get", map[string]string{"key": key})
	if err != nil {
		return nil, err
	}
	var o struct{ Data, ETag string }
	if json.Unmarshal(reply, &o) != nil || o.Data == "" && o.ETag == "" {
		return nil, nil
	}
	data, err := base64.StdEncoding.DecodeString(o.Data)
	if err != nil {
		return nil, err
	}
	return &store.Object{Data: data, ETag: o.ETag}, nil
}

func (p peerStore) Put(_ context.Context, key string, data []byte, when store.Condition) (string, error) {
	if !when.IsAbsent() {
		return "", errors.New("a handover only creates records")
	}
	reply, err := p.link.call("store/put", map[string]string{"key": key, "data": base64.StdEncoding.EncodeToString(data)})
	var refused *rpcFailure
	if errors.As(err, &refused) && refused.Code == wire.FailureChangedElsewhere {
		return "", &store.ConflictError{Key: key}
	}
	if err != nil {
		return "", err
	}
	var tag string
	json.Unmarshal(reply, &tag)
	return tag, nil
}

func (p peerStore) Delete(context.Context, string) error {
	return errors.New("a handover never deletes")
}

func (p peerStore) List(_ context.Context, prefix string) ([]store.Key, error) {
	reply, err := p.link.call("store/list", map[string]string{"prefix": prefix})
	if err != nil {
		return nil, err
	}
	var entries []struct{ Key, ETag string }
	if err := json.Unmarshal(reply, &entries); err != nil {
		return nil, err
	}
	keys := make([]store.Key, 0, len(entries))
	for _, e := range entries {
		keys = append(keys, store.Key{Key: e.Key, ETag: e.ETag})
	}
	return keys, nil
}

// ownCopy is `self`: with --home, the address and pin `serve --home` gives itself, so a
// copy started empty to receive is reachable too (T127); otherwise what its settings say.
func ownCopy() (string, string) {
	if home() != "" {
		port := 8791
		if p, err := strconv.Atoi(value("--port")); err == nil {
			port = p
		}
		text := os.Getenv("AGENTS_CONTROL_URL")
		if text == "" {
			text = fmt.Sprintf("https://%s:%d", controlplane.LocalHostName(), port)
		}
		u, err := url.Parse(text)
		if err != nil || u.Hostname() == "" {
			fail("%s is not an address", text)
		}
		_, pin, err := controlplane.SelfSigned(filepath.Join(home(), "tls"), u.Hostname())
		if err != nil {
			fail("this Mac's certificate: %v", err)
		}
		return text, pin
	}
	r := records.New(openStore(""))
	if err := r.Load(context.Background()); err != nil {
		fail("%v", err)
	}
	settings := r.Settings()
	if settings == nil || settings.URL == nil {
		fail("this store has no control plane yet")
	}
	pin := ""
	if settings.Pin != nil {
		pin = *settings.Pin
	}
	return *settings.URL, pin
}

// handover is a handover of the running control plane to a copy elsewhere (058, R16), one
// step at a time, with the control plane's key: Agents Host's Move to Another Machine…,
// Run It Here Again… and Relay for my devices, or by hand. --at is the copy the step is for.
func handover() {
	step := ""
	if len(args) > 1 {
		step = args[1]
	}
	if step == "" || strings.HasPrefix(step, "-") {
		fail("%s", handoverUsage)
	}
	var key []byte
	link := func(flag, pinFlag string) *handoverLink {
		text, pin := value(flag), value(pinFlag)
		if text == "" {
			fail("say %s https://… (or self) for the copy", flag)
		}
		if text == "self" {
			text, pin = ownCopy()
		}
		if key == nil {
			key = privateKey(openStore(""))
		}
		l, err := dialHandover(context.Background(), text, pin, key)
		if err != nil {
			fail("couldn't reach %s as this control plane: %v", text, err)
		}
		return l
	}
	endpoints := func() []records.Endpoint {
		text := value("--endpoint")
		if text == "" {
			fail("say --endpoint https://… (or self) [--endpoint-pin PIN]")
		}
		pin := value("--endpoint-pin")
		if text == "self" {
			text, pin = ownCopy()
		}
		e := records.Endpoint{URL: text}
		if pin != "" {
			e.Pin = &pin
		}
		return []records.Endpoint{e}
	}
	show := func(result json.RawMessage, err error) {
		if err != nil {
			fail("%v", err)
		}
		var status wire.HandoverStatus
		if json.Unmarshal(result, &status) != nil || status.Phase == "" {
			fmt.Println(string(result))
			return
		}
		if has("--json") {
			fmt.Println(string(result))
			return
		}
		fmt.Printf("phase\t%s\n", status.Phase)
		if status.ForwardingUntil != nil {
			fmt.Printf("until\t%s\n", status.ForwardingUntil.Time().UTC().Format(time.RFC3339))
		}
		records := "none"
		if status.HasRecords {
			records = "yes"
		}
		fmt.Printf("records\t%s\n", records)
		epoch := "-"
		if status.Epoch != nil {
			epoch = strconv.FormatInt(*status.Epoch, 10)
		}
		fmt.Printf("epoch\t%s\n", epoch)
		for _, e := range status.Endpoints {
			pin := "-"
			if e.Pin != nil {
				pin = *e.Pin
			}
			fmt.Printf("endpoint\t%s\t%s\n", e.URL, pin)
		}
		for _, m := range status.Members {
			known, online := "-", "-"
			if m.KnownEpoch != nil {
				known = strconv.FormatInt(*m.KnownEpoch, 10)
			}
			if m.Online != nil && *m.Online {
				online = "online"
			}
			fmt.Printf("member\t%s\t%s\t%s\t%s\t%s\n", m.ID, m.Name, m.Kind, known, online)
		}
	}
	switch step {
	case "status", "freeze", "unfreeze", "withdraw", "take", "stop":
		show(link("--at", "--pin").call("handover/"+step, nil))
	case "announce":
		show(link("--at", "--pin").call("handover/announce", map[string]any{"endpoint": endpoints()[0], "force": has("--force")}))
	case "forward":
		// 30 days at most, the copy's own rule; --days for fewer.
		params := map[string]any{"endpoints": endpoints()}
		if days, err := strconv.ParseFloat(value("--days"), 64); err == nil {
			params["until"] = wire.DateOf(time.Now().Add(time.Duration(days * 24 * float64(time.Hour))))
		}
		show(link("--at", "--pin").call("handover/forward", params))
	case "shares":
		// Whether two copies read one store (a bucket, R16 3): a mark left at one is found
		// at the other.
		at, with := link("--at", "--pin"), link("--with", "--with-pin")
		nonce := make([]byte, 16)
		rand.Read(nonce)
		mark := hex.EncodeToString(nonce)
		if _, err := at.call("handover/mark", map[string]any{"nonce": mark, "leave": true}); err != nil {
			fail("%v", err)
		}
		reply, err := with.call("handover/mark", map[string]any{"nonce": mark})
		var found struct{ Found bool }
		if err != nil || json.Unmarshal(reply, &found) != nil || !found.Found {
			fail("not the same store: %s doesn't see what %s wrote", value("--with"), value("--at"))
		}
		fmt.Println("the same store")
	case "relay":
		// Relay for my devices (#809): the relay host switched on or off, keeping its
		// enrolment, over the session the control plane's key proves.
		host := value("--host")
		if host == "" || has("--on") == has("--off") {
			fail("say --host ID and --on or --off")
		}
		request := wire.MachineRelayRequest{Host: wire.MachineRef(host), Relay: has("--on")}
		if _, err := link("--at", "--pin").call("relay/set", request); err != nil {
			fail("%v", err)
		}
		if request.Relay {
			fmt.Println(host + " relays")
		} else {
			fmt.Println(host + " is switched off")
		}
	case "copy":
		// Either end a copy (https://… or self, over its handover session) or a store this
		// machine opens (file://…, s3://…).
		end := func(flag, pinFlag string) store.Store {
			text := value(flag)
			if text == "" {
				fail("say %s", flag)
			}
			if text == "self" || strings.HasPrefix(text, "https://") || strings.HasPrefix(text, "http://") {
				return peerStore{link(flag, pinFlag)}
			}
			return openStore(text)
		}
		from := end("--from", "--from-pin")
		to := end("--to", "--to-pin")
		reportCopy(controlplane.CopyStore(context.Background(), from, to))
	default:
		fail("%s", handoverUsage)
	}
}

// copyStore is Switch Store… (T058b): with no copy serving, every record into an empty
// store.
func copyStore() {
	from, to := value("--from"), value("--to")
	if from == "" || to == "" {
		fail("say --from URL --to URL")
	}
	reportCopy(controlplane.CopyStore(context.Background(), openStore(from), openStore(to)))
}

func reportCopy(copied, skipped int, err error) {
	if err != nil {
		fail("%v", err)
	}
	fmt.Printf("copied %d records (left out %d leases, copies and sealed keys, which each copy makes its own)\n", copied, skipped)
}

const handoverUsage = `usage: agents-control handover status|freeze|unfreeze|withdraw|take|stop --at URL [--pin PIN] [--json]
       agents-control handover shares --at URL [--pin PIN] --with URL [--with-pin PIN]
       agents-control handover announce|forward --at URL [--pin PIN] --endpoint URL [--endpoint-pin PIN] [--days N] [--force]
       agents-control handover copy --from URL|STORE [--from-pin PIN] --to URL|STORE [--to-pin PIN]
       agents-control handover relay --at URL [--pin PIN] --host ID --on|--off
(URL may be self: this copy, at the address and pin serve --home gives itself, or its settings say)`
