// agents-control: the control plane as a service (058), in Go (#1137), with the same
// command line as the Swift one, so Agents Host and a scratch set-up can start either.
//
//	agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
//	agents-control serve --home DIR [--no-bonjour] [--key-fd N]
//	agents-control serve … [--host-root DIR]    this Mac's host's root: its join in control/status (#113)
//	agents-control serve … [--log FILE]         stamped lines into FILE, rolled at 4 MB (#174)
//	agents-control serve … [--web DIR] [--web-port N] [--no-web]
//	agents-control serve … [--store-credentials-fd N]
//	agents-control code (--client [--browser] | --host) [--minutes N] [--home DIR] [--command]
//	agents-control hosts | clients
//	agents-control install-script               the script a server runs to become a host
//	agents-control store check [--store URL]
//	agents-control version
//
// --home is Agents Host's single copy (T057): its certificate and store in DIR, port 8791,
// this Mac's .local name, and Bonjour. Anything below still overrides it.
//
// The web remote (071): with --web DIR (the built Web/dist) and a port, a second listener
// on 127.0.0.1 and ::1 only serves it at http://localhost:<port>. --home defaults the port
// to 8792; without --home there is none unless given. --no-web turns it off.
//
// Where things are comes from the environment, as the Swift one reads it:
//
//	AGENTS_STORE                file:///path, or s3://bucket/prefix (an option)
//	AGENTS_STORE_ENDPOINT, AGENTS_STORE_PATH_STYLE=1, AWS_*: the bucket (contracts/store.md)
//	AGENTS_CONTROL_WEB_PORT     the web remote's loopback port, when --web-port is not given
//	AGENTS_CONTROL_URL          the one address clients and hosts are given
//	AGENTS_CONTROL_KEY_FILE     the control plane's private key, raw, 0600 (made if missing)
//	AGENTS_CONTROL_KEY          or the key itself, base64url
//	AGENTS_CONTROL_TLS_CERT/_KEY  when this copy terminates TLS itself
//	AGENTS_CONTROL_PIN          the load balancer's certificate pin, when it terminates TLS
//	AGENTS_CONTROL_NAME, AGENTS_CONTROL_MACHINE_ID, AGENTS_CONTROL_SERVERS
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
)

var (
	args = os.Args[1:]
	logs = controlplane.NewLog()
)

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
	line := "agents-control: " + fmt.Sprintf(format, a...)
	if logs.Taken() {
		logs.Write(line)
	} else {
		fmt.Fprintln(os.Stderr, line)
	}
	os.Exit(1)
}

// say is a line for whoever started it: into the log when serving with one, else out.
func say(line string) {
	if logs.Taken() {
		logs.Write("agents-control: " + line)
	} else {
		fmt.Println(line)
	}
}

func expand(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, _ := os.UserHomeDir()
		path = filepath.Join(home, path[2:])
	}
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return path
}

// home is Agents Host's folder for its single copy, when given.
func home() string {
	if h := value("--home"); h != "" {
		return expand(h)
	}
	return ""
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
		text = (&url.URL{Scheme: "file", Path: filepath.Join(home(), "store") + "/"}).String()
	}
	if text == "" {
		fail("say where the store is: AGENTS_STORE=file:///path or s3://bucket/prefix")
	}
	s, err := controlplane.OpenStore(text, os.Getenv, storeCredentials())
	if err != nil {
		fail("%v", err)
	}
	return s
}

var givenCredentials *controlplane.StoreCredentials

// storeCredentials are the bucket's keys, read once from the descriptor Agents Host
// handed over (T058a): they are never in a plist, a file or the environment.
func storeCredentials() *controlplane.StoreCredentials {
	fd := value("--store-credentials-fd")
	if fd == "" || givenCredentials != nil {
		return givenCredentials
	}
	n, err := strconv.Atoi(fd)
	if err != nil {
		fail("no bucket keys on descriptor %s", fd)
	}
	f := os.NewFile(uintptr(n), "credentials")
	data, _ := io.ReadAll(io.LimitReader(f, 64<<10))
	f.Close()
	var c controlplane.StoreCredentials
	if json.Unmarshal(data, &c) != nil || c.AccessKey == "" {
		fail("no bucket keys on descriptor %s", fd)
	}
	givenCredentials = &c
	return givenCredentials
}

// webConfig is the web remote's listener, or nil: a folder and a port both, and no
// --no-web (071).
func webConfig() *controlplane.WebConfig {
	folder := value("--web")
	if has("--no-web") || folder == "" {
		return nil
	}
	port, err := strconv.Atoi(value("--web-port"))
	if err != nil {
		port, err = strconv.Atoi(os.Getenv("AGENTS_CONTROL_WEB_PORT"))
	}
	if err != nil {
		if home() == "" {
			return nil
		}
		port = web.DefaultPort
	}
	return &controlplane.WebConfig{Folder: expand(folder), Port: port}
}

func privateKey() []byte {
	if fd := value("--key-fd"); fd != "" {
		n, err := strconv.Atoi(fd)
		if err != nil {
			fail("no key on descriptor %s", fd)
		}
		f := os.NewFile(uintptr(n), "key")
		data, _ := io.ReadAll(io.LimitReader(f, 64))
		f.Close()
		if len(data) != 32 {
			fail("no key on descriptor %s", fd)
		}
		return data
	}
	if text := os.Getenv("AGENTS_CONTROL_KEY"); text != "" {
		key, err := controllink.FromB64URL(text)
		if err != nil || len(key) != 32 {
			fail("AGENTS_CONTROL_KEY is not a key")
		}
		return key
	}
	file := os.Getenv("AGENTS_CONTROL_KEY_FILE")
	if file == "" && home() != "" {
		file = filepath.Join(home(), "control-key")
	}
	if file == "" {
		fail("say where the control plane's key is: AGENTS_CONTROL_KEY_FILE, AGENTS_CONTROL_KEY or --key-fd")
	}
	key, err := controllink.LoadOrMakeKey(file)
	if err != nil {
		fail("the key file: %v", err)
	}
	return key
}

func serve() {
	// Beside the rest of what it says, in control.log, rather than in the system log (#93).
	if file := value("--log"); file != "" {
		logs.Take(expand(file), controlplane.LogLimit)
	}
	homePort := 8791
	if p, err := strconv.Atoi(value("--port")); err == nil {
		homePort = p
	}
	text := os.Getenv("AGENTS_CONTROL_URL")
	if text == "" && home() != "" {
		text = fmt.Sprintf("https://%s:%d", controlplane.LocalHostName(), homePort)
	}
	u, err := url.Parse(text)
	if text == "" || err != nil || u.Hostname() == "" {
		fail("say the control plane's address: AGENTS_CONTROL_URL=https://…")
	}
	port := 8791
	if p, err := strconv.Atoi(value("--port")); err == nil {
		port = p
	} else if p, err := strconv.Atoi(u.Port()); err == nil {
		port = p
	}
	cfg := controlplane.Config{URL: text, Bind: value("--bind"), Port: port, Log: logs.Write,
		ServerFolder: controlplane.ServerFolder()}
	if dir := value("--self-signed"); dir != "" || home() != "" {
		if dir == "" {
			dir = filepath.Join(home(), "tls")
		}
		tlsConfig, pin, err := controlplane.SelfSigned(expand(dir), u.Hostname())
		if err != nil {
			fail("TLS: %v", err)
		}
		cfg.TLS, cfg.Pin = tlsConfig, pin
	} else if cert, key := os.Getenv("AGENTS_CONTROL_TLS_CERT"), os.Getenv("AGENTS_CONTROL_TLS_KEY"); cert != "" && key != "" {
		tlsConfig, _, err := controlplane.LoadTLS(cert, key)
		if err != nil {
			fail("TLS: %v", err)
		}
		// A certificate given by path is taken to be publicly trusted: no pin.
		cfg.TLS = tlsConfig
	}
	// Behind a load balancer that terminates TLS, the pin is its certificate's, given.
	if cfg.Pin == "" {
		cfg.Pin = os.Getenv("AGENTS_CONTROL_PIN")
	}
	cfg.Name = value("--name")
	if cfg.Name == "" {
		cfg.Name = os.Getenv("AGENTS_CONTROL_NAME")
	}
	if cfg.Name == "" {
		cfg.Name = u.Hostname()
		if home() != "" {
			cfg.Name = controlplane.LocalName()
		}
	}
	cfg.MachineID = os.Getenv("AGENTS_CONTROL_MACHINE_ID")
	if cfg.MachineID == "" {
		cfg.MachineID = controlplane.MachineID()
	}
	if root := value("--host-root"); root != "" {
		cfg.HostJoinFile = filepath.Join(expand(root), "control-join.json")
	}
	cfg.Web = webConfig()
	// Whether the page is served, for Agents Host to read (071 R3): this run's, or none.
	if home() != "" {
		file := filepath.Join(home(), "web.json")
		os.Remove(file)
		cfg.WebChanged = func(status web.Status) {
			data, _ := json.Marshal(map[string]any{"pid": os.Getpid(), "status": status})
			tmp := file + ".tmp"
			if os.WriteFile(tmp, data, 0o644) == nil {
				os.Rename(tmp, file)
			}
		}
	}
	cfg.Store = openStore("")
	cfg.PrivateKey = privateKey()
	s, err := controlplane.New(cfg)
	if err != nil {
		fail("%v", err)
	}
	listening, err := s.Start(context.Background())
	if err != nil {
		fail("%v", err)
	}
	if cfg.Pin != "" {
		say("pin " + cfg.Pin)
	}
	// Found by the window on this network (frame K2). Not for a walk that must stay out
	// of sight: --no-bonjour.
	var advertiser *exec.Cmd
	if home() != "" && !has("--no-bonjour") && runtime.GOOS == "darwin" {
		if advertiser = advertise(cfg.Name, listening, cfg.Pin); advertiser != nil {
			say("advertised as " + cfg.Name)
		}
	}
	// SIGUSR1: try the web remote's listener again (Agents Host's Try Again, 071 R3).
	retry := make(chan os.Signal, 1)
	signal.Notify(retry, syscall.SIGUSR1)
	go func() {
		for range retry {
			s.RetryWeb()
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	if advertiser != nil && advertiser.Process != nil {
		advertiser.Process.Kill()
	}
	s.Stop()
}

// advertise is Advertiser.swift: _agents-control._tcp under this Mac's name, with the
// pin in the TXT record so the one found is the one dialled. Through dns-sd, as there is
// no cgo; it lives as long as this process.
func advertise(name string, port int, pin string) *exec.Cmd {
	txt := []string{"v=2"}
	if pin != "" {
		txt = append(txt, "pin="+pin)
	}
	cmd := exec.Command("/usr/bin/dns-sd", append([]string{"-R", name, "_agents-control._tcp", "local", strconv.Itoa(port)}, txt...)...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if cmd.Start() != nil {
		return nil
	}
	return cmd
}

// code is a code made against the store: any copy serving it takes it.
func code() {
	host := has("--host")
	// Every client may do everything (#111): --client operator or --client device is the
	// same code, and the word after is let go.
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
	key := privateKey()
	public, err := controllink.PublicKey(key)
	if err != nil || !bytes.Equal(public, settings.ControlKey) {
		fail("that key is not this control plane's")
	}
	pin := ""
	if settings.Pin != nil {
		pin = *settings.Pin
	}
	codes := &controlplane.Codes{Store: st, Private: key, Public: public, URL: *settings.URL, Pin: pin, Name: settings.Name}
	minutes := controllink.CodeLifetime.Minutes()
	if m, err := strconv.ParseFloat(value("--minutes"), 64); err == nil {
		minutes = m
	}
	// --browser: for a browser on this Mac, good only through the loopback listener (071 R2).
	shown, err := codes.Issue(context.Background(), host, has("--browser"), time.Duration(minutes*float64(time.Minute)))
	if err != nil {
		fail("%v", err)
	}
	fmt.Println(shown.Text)
	// The line a server runs to join with it (T070), for Agents Host to run over ssh.
	if has("--command") && host {
		fmt.Println("command\t" + controlplane.InstallCommand(*settings.URL, pin, shown.Text))
	}
}

// checkStore is the start-up probe on its own (contracts/store.md rule 4): Agents Host's
// Check.
func checkStore() {
	err := store.Probe(context.Background(), openStore(""), "check")
	if err == nil {
		fmt.Println("works, with safe concurrent writes")
		return
	}
	var down *store.UnavailableError
	switch {
	case store.IsConflict(err):
		fail("It can't be used: another writer changed the probe while it ran. Check again.")
	case asUnavailable(err, &down):
		fail("It can't be used: %s.", down.Why)
	default:
		fail("%v", err)
	}
}

func asUnavailable(err error, down **store.UnavailableError) bool {
	d, ok := err.(*store.UnavailableError)
	*down = d
	return ok
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

const usage = `usage: agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
       agents-control code (--client [--browser] | --host) [--minutes N]
       agents-control serve --home DIR [--no-bonjour]
       agents-control serve … [--host-root DIR] [--log FILE] [--web DIR] [--web-port N] [--no-web]
       agents-control hosts | clients
       agents-control install-script
       agents-control store check [--store URL]`

func main() {
	first := ""
	if len(args) > 0 {
		first = args[0]
	}
	switch {
	case first == "serve":
		serve()
	case first == "code":
		code()
	case first == "hosts":
		list(true)
	case first == "clients":
		list(false)
	case first == "store" && len(args) > 1 && args[1] == "check":
		checkStore()
	case first == "install-script":
		fmt.Print(controlplane.InstallScript)
	case first == "--version" || first == "version":
		fmt.Println("agents-control " + buildinfo.String())
	default:
		fail("%s", usage)
	}
}
