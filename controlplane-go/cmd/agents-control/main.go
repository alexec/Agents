// agents-control, in Go (#1126 spike): the same command line as the Swift one for what
// a scratch set-up uses, so run-app's set-up can start this one in its place.
//
//	agents-control serve [--home DIR] [--port N] [--bind ADDR] [--name NAME] [--self-signed DIR]
//	                     [--web DIR --web-port N | --no-web] [--host-root DIR] [--no-bonjour]
//	agents-control code (--client [--browser] | --host) [--minutes N] [--home DIR] [--command]
//	agents-control hosts | clients [--home DIR]
//	agents-control store check [--store URL]
//
// Environment, as the Swift one reads it: AGENTS_STORE (file:///path or s3://bucket/prefix,
// with AGENTS_STORE_ENDPOINT, AGENTS_STORE_PATH_STYLE=1 and AWS_*), AGENTS_CONTROL_URL,
// AGENTS_CONTROL_KEY_FILE or AGENTS_CONTROL_KEY, AGENTS_CONTROL_TLS_CERT/_KEY,
// AGENTS_CONTROL_KMS (a gocloud.dev/secrets keeper URL: the key sealed in the store),
// AGENTS_CONTROL_PEER_URL (where other copies reach this one: several copies over one store),
// AGENTS_CONTROL_PIN, AGENTS_CONTROL_NAME, AGENTS_CONTROL_MACHINE_ID, AGENTS_CONTROL_WEB_PORT.
package main

import (
	"context"
	"fmt"
	"log"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/kms"
	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/service"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

var args = os.Args[1:]

func value(flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func has(flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "agents-control: "+format+"\n", a...)
	os.Exit(1)
}

func home() string {
	h := value("--home")
	if h == "" {
		return ""
	}
	if abs, err := filepath.Abs(h); err == nil {
		return abs
	}
	return h
}

func openStore(given string) store.Store {
	text := given
	if text == "" {
		text = value("--store")
	}
	if text == "" {
		text = os.Getenv("AGENTS_STORE")
	}
	if text == "" && home() != "" {
		text = (&url.URL{Scheme: "file", Path: filepath.Join(home(), "store")}).String()
	}
	if text == "" {
		fail("say where the store is: AGENTS_STORE=file:///path or s3://bucket/prefix")
	}
	s, err := store.Open(context.Background(), text)
	if err != nil {
		fail("%v", err)
	}
	return s
}

// privateKey is the control plane's key. With AGENTS_CONTROL_KMS it lives in the store,
// sealed (stage 4): a key file or AGENTS_CONTROL_KEY, if there is one, is sealed the first
// time; otherwise a new key is made, and no file is written.
func privateKey(st store.Store) []byte {
	if keeper := os.Getenv("AGENTS_CONTROL_KMS"); keeper != "" {
		k, err := kms.ControlKey(context.Background(), st, keeper, func() []byte {
			if given := plainKey(false); given != nil {
				return given
			}
			return auth.NewPrivateKey()
		})
		if err != nil {
			fail("the control key: %v", err)
		}
		return k
	}
	return plainKey(true)
}

func plainKey(makeFile bool) []byte {
	if text := os.Getenv("AGENTS_CONTROL_KEY"); text != "" {
		k, err := auth.B64URL(text)
		if err != nil || len(k) != 32 {
			fail("AGENTS_CONTROL_KEY is not a key")
		}
		return k
	}
	file := os.Getenv("AGENTS_CONTROL_KEY_FILE")
	if file == "" && home() != "" {
		file = filepath.Join(home(), "control-key")
	}
	if file == "" {
		if !makeFile {
			return nil
		}
		fail("say where the control plane's key is: AGENTS_CONTROL_KEY_FILE, AGENTS_CONTROL_KEY or AGENTS_CONTROL_KMS")
	}
	if b, err := os.ReadFile(file); err == nil && len(b) == 32 {
		return b
	}
	if !makeFile {
		return nil
	}
	k := auth.NewPrivateKey()
	os.MkdirAll(filepath.Dir(file), 0o700)
	if err := os.WriteFile(file, k, 0o600); err != nil {
		fail("the key file: %v", err)
	}
	return k
}

func serve() {
	logger := log.New(os.Stderr, "", log.LstdFlags|log.Lmicroseconds)
	port, _ := strconv.Atoi(value("--port"))
	if port == 0 {
		port = 8791
	}
	text := os.Getenv("AGENTS_CONTROL_URL")
	if text == "" && home() != "" {
		h, _ := os.Hostname()
		text = fmt.Sprintf("https://%s:%d", h, port)
	}
	if text == "" {
		fail("say the control plane's address: AGENTS_CONTROL_URL=https://…")
	}
	u, err := url.Parse(text)
	if err != nil {
		fail("%v", err)
	}
	if value("--port") == "" && u.Port() != "" {
		port, _ = strconv.Atoi(u.Port())
	}
	st := openStore("")
	cfg := service.Config{Store: st, PrivateKey: privateKey(st), URL: text, Bind: value("--bind"), Port: port,
		HostRoot: value("--host-root"), PeerURL: os.Getenv("AGENTS_CONTROL_PEER_URL"), Log: func(l string) { logger.Println(l) }}
	dir := value("--self-signed")
	if dir == "" && home() != "" {
		dir = filepath.Join(home(), "tls")
	}
	if dir != "" {
		tlsConfig, pin, err := service.SelfSigned(dir, u.Hostname())
		if err != nil {
			fail("TLS: %v", err)
		}
		cfg.TLS, cfg.Pin = tlsConfig, pin
	} else if c, k := os.Getenv("AGENTS_CONTROL_TLS_CERT"), os.Getenv("AGENTS_CONTROL_TLS_KEY"); c != "" && k != "" {
		tlsConfig, _, err := service.LoadTLS(c, k)
		if err != nil {
			fail("TLS: %v", err)
		}
		cfg.TLS, cfg.Pin = tlsConfig, os.Getenv("AGENTS_CONTROL_PIN")
	} else {
		cfg.Pin = os.Getenv("AGENTS_CONTROL_PIN")
	}
	cfg.Name = value("--name")
	if cfg.Name == "" {
		cfg.Name = os.Getenv("AGENTS_CONTROL_NAME")
	}
	if cfg.Name == "" {
		cfg.Name = u.Hostname()
		if home() != "" {
			cfg.Name = service.LocalName()
		}
	}
	cfg.MachineID = os.Getenv("AGENTS_CONTROL_MACHINE_ID")
	if cfg.MachineID == "" {
		cfg.MachineID = service.MachineID()
	}
	if folder := value("--web"); folder != "" && !has("--no-web") {
		wp, _ := strconv.Atoi(value("--web-port"))
		if wp == 0 {
			wp, _ = strconv.Atoi(os.Getenv("AGENTS_CONTROL_WEB_PORT"))
		}
		if wp == 0 && home() != "" {
			wp = 8792
		}
		if wp != 0 {
			cfg.Web = &service.WebConfig{Folder: folder, Port: wp}
		}
	}
	s, err := service.New(cfg)
	if err != nil {
		fail("%v", err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		fail("%v", err)
	}
	if cfg.Pin != "" {
		logger.Println("agents-control: pin " + cfg.Pin)
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	s.Stop()
}

func code() {
	host := has("--host")
	if !host && !has("--client") {
		fail("say what the code is for: --client or --host")
	}
	st := openStore("")
	r := records.New(st)
	if err := r.Load(context.Background()); err != nil {
		fail("%v", err)
	}
	settings := r.Settings()
	if settings == nil || settings.URL == nil {
		fail("this store has no control plane yet: start one with `agents-control serve` first")
	}
	key := privateKey(st)
	pub, _ := auth.PublicKey(key)
	if string(pub) != string(settings.ControlKey) {
		fail("that key is not this control plane's")
	}
	pin := ""
	if settings.Pin != nil {
		pin = *settings.Pin
	}
	codes := &service.Codes{Store: st, Private: key, Public: pub, URL: *settings.URL, Pin: pin, Name: settings.Name}
	minutes, _ := strconv.ParseFloat(value("--minutes"), 64)
	if minutes == 0 {
		minutes = 5
	}
	shown, err := codes.Issue(context.Background(), host, has("--browser"), time.Duration(minutes*float64(time.Minute)))
	if err != nil {
		fail("%v", err)
	}
	fmt.Println(shown.Text)
	if has("--command") && host && shown.Command != nil {
		fmt.Println("command\t" + *shown.Command)
	}
}

func list(hosts bool) {
	r := records.New(openStore(""))
	if err := r.Load(context.Background()); err != nil {
		fail("%v", err)
	}
	if hosts {
		for _, h := range r.Hosts() {
			fmt.Printf("%s\t%s\t%s\t%s\n", h.ID, h.Name, h.Platform, h.Version)
		}
		return
	}
	for _, c := range r.Clients() {
		fmt.Printf("%s\t%s\t%s\n", c.ID, c.Name, c.Kind)
	}
}

func main() {
	if len(args) == 0 {
		fail("say serve, code, hosts, clients or store check")
	}
	switch args[0] {
	case "serve":
		serve()
	case "code":
		code()
	case "hosts":
		list(true)
	case "clients":
		list(false)
	case "store":
		if len(args) > 1 && args[1] == "check" {
			if err := store.Probe(context.Background(), openStore(""), "check"); err != nil {
				fail("It can't be used: %v.", err)
			}
			fmt.Println("works, with safe concurrent writes")
			return
		}
		fail("say store check")
	default:
		fail("no command %s", args[0])
	}
}
