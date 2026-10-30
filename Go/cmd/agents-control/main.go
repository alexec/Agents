// agents-control: the control plane as a service (058), in Go (#1137), with the same
// command line as the Swift one, so Agents Host and a scratch set-up can start either.
//
//	agents-control serve [--port N] [--bind ADDR] [--self-signed DIR] [--name NAME] [--key-fd N]
//	agents-control serve --home DIR [--no-bonjour] [--key-fd N]
//	agents-control serve … [--host-root DIR]    this Mac's host's root: its join in control/status (#113)
//	agents-control serve … [--log FILE]         stamped lines into FILE, rolled at 4 MB (#174)
//	agents-control serve … [--web DIR] [--web-port N] [--no-web]
//	agents-control serve … [--public-web DIR]   the page at AGENTS_CONTROL_URL too (#1459)
//	agents-control serve … [--views-url URL]    its views' sandbox proxy at URL (#1484)
//	agents-control serve … [--store-credentials-fd N]
//	agents-control serve … [--receive]          empty, for a handover to fill (AGENTS_CONTROL_RECEIVE=1)
//	agents-control serve … [--no-forwarding]    serve, even if this copy was forwarding
//	agents-control serve … [--log-format text|json] [--log-level debug|info|warn|error]
//	                                            JSON lines through log/slog (#2176); debug logs each request
//	agents-control serve … [--metrics ADDR]      Prometheus /metrics on a listener of its own (#2176)
//	agents-control serve … [--key-days N]       how long a client's or machine's key lives unused (#997, AGENTS_CONTROL_KEY_DAYS); 90
//	agents-control code (--client [--browser] | --host) [--minutes N] [--home DIR] [--command]
//	agents-control hosts | clients
//	agents-control key seal --key-fd N          seal a key handed in, with AGENTS_CONTROL_KMS
//	agents-control handover STEP --at URL|self … a step of a move to a copy elsewhere (R16, #1490)
//	agents-control store copy --from URL --to URL  every record into an empty store (Switch Store…)
//	agents-control key export --key-fd N        the key, raw, out on N: for a move back to a Mac
//	agents-control backup --to DIR              the store and what a restore needs beside it (#2137)
//	agents-control restore --from DIR [--new-kms]  a backup, into a new home and an empty store
//	agents-control audit verify [--store URL]   whether an audit entry was changed or removed (#1001)
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
//	AGENTS_CONTROL_PUBLIC_WEB   the built web app to serve at AGENTS_CONTROL_URL's own origin,
//	                            when --public-web is not given: behind a proxy with a public
//	                            certificate (compose.public.yaml), for a browser anywhere (#1459)
//	AGENTS_CONTROL_VIEWS_URL    the second name in front of this listener (views.<domain>), at
//	                            which the page's MCP Apps views are drawn (#1484), when
//	                            --views-url is not given; none draws no views there
//	AGENTS_CONTROL_URL          the one address clients and hosts are given
//	AGENTS_CONTROL_KEY_FILE     the control plane's private key, raw, 0600 (made if missing)
//	AGENTS_CONTROL_KEY          or the key itself, base64url
//	AGENTS_CONTROL_KMS          or sealed in the store by a keeper, never on the disk in clear
//	                            (a cloud machine's, #1458): gcpkms://… (Google Cloud KMS, with
//	                            GOOGLE_APPLICATION_CREDENTIALS), hashivault://…, base64key://…
//	AGENTS_CONTROL_TLS_CERT/_KEY  when this copy terminates TLS itself
//	AGENTS_CONTROL_PIN          the load balancer's certificate pin, when it terminates TLS
//	AGENTS_CONTROL_PEER_URL     where other copies reach this one (several copies, US3)
//	AGENTS_CONTROL_TRUSTED_PROXIES  the proxy in front (addresses or prefixes, commas): its
//	                            X-Forwarded-For is a socket's source, for the per-source budget
//	AGENTS_CONTROL_NAME, AGENTS_CONTROL_MACHINE_ID, AGENTS_CONTROL_SERVERS,
//	AGENTS_CONTROL_TOOLSETS
//	AGENTS_APNS_KEY_FILE, AGENTS_APNS_KEY_ID, AGENTS_APNS_TEAM_ID: the APNs key (#1460)
//	AGENTS_WEBPUSH_KEY_FILE, AGENTS_WEBPUSH_SUBJECT: the VAPID key for Web Push to a
//	                            browser (#1486), and the mailto: or https: address a push
//	                            service may write to about it
//	AGENTS_CONTROL_LOG_FORMAT, AGENTS_CONTROL_LOG_LEVEL  as --log-format and --log-level
//	AGENTS_CONTROL_METRICS      as --metrics: host:port, such as 127.0.0.1:9791; off when unset
//	AGENTS_CONTROL_METRICS_TOKEN  the bearer token a scraper sends; needed on any address but
//	                            loopback. AGENTS_CONTROL_METRICS_TOKEN_FILE reads it from a file
//	OTEL_EXPORTER_OTLP_ENDPOINT  the report figures to an OTLP/HTTP collector (#2019), off when
//	                            unset; OTEL_EXPORTER_OTLP_METRICS_ENDPOINT, _HEADERS and
//	                            OTEL_METRIC_EXPORT_INTERVAL as OpenTelemetry has them
//	AGENTS_TEST_APNS_URL        a walk's fake APNs, trusted by AGENTS_TEST_TRUST_ROOT (#1507)
package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
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
	"github.com/alexec/agents/Go/internal/controlplane/apns"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/internal/controlplane/webpush"
	"github.com/alexec/agents/Go/wire"
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
		logs.WriteAt(slog.LevelError, line)
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

// flagOrEnv is the flag's value, or else the environment's.
func flagOrEnv(flag, env string) string {
	if v := value(flag); v != "" {
		return v
	}
	return os.Getenv(env)
}

// metricsToken is AGENTS_CONTROL_METRICS_TOKEN, or the first line of the file
// AGENTS_CONTROL_METRICS_TOKEN_FILE names (a compose secret).
func metricsToken() string {
	if token := os.Getenv("AGENTS_CONTROL_METRICS_TOKEN"); token != "" {
		return token
	}
	file := os.Getenv("AGENTS_CONTROL_METRICS_TOKEN_FILE")
	if file == "" {
		return ""
	}
	data, err := os.ReadFile(file)
	if err != nil {
		fail("AGENTS_CONTROL_METRICS_TOKEN_FILE: %v", err)
	}
	line, _, _ := strings.Cut(string(data), "\n")
	return strings.TrimSpace(line)
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

// publicWeb is the built web app to serve on the TLS listener at its own origin (#1459), or
// "": --public-web or AGENTS_CONTROL_PUBLIC_WEB, and no --no-web.
// pusher is the APNs key, Key ID and Team ID (#1460), a compose secret on the machine and
// never in the store: nil when there is no key, which the service says once. A key that
// can't be used is said here, and nothing is pushed.
func pusher() controlplane.Pusher {
	file := os.Getenv("AGENTS_APNS_KEY_FILE")
	if file == "" {
		return nil
	}
	if info, err := os.Stat(file); err != nil || info.Size() == 0 {
		return nil
	}
	cfg := apns.Config{KeyFile: file, KeyID: strings.TrimSpace(os.Getenv("AGENTS_APNS_KEY_ID")),
		TeamID: strings.TrimSpace(os.Getenv("AGENTS_APNS_TEAM_ID"))}
	// A walk's stand-in for Apple (#1507): every push goes to AGENTS_TEST_APNS_URL, whose
	// certificate chains to AGENTS_TEST_TRUST_ROOT, so a walk counts its pushes with a fake
	// key and nothing reaches Apple.
	if fake := strings.TrimSpace(os.Getenv("AGENTS_TEST_APNS_URL")); fake != "" {
		cfg.Hosts = map[wire.PushEnvironment]string{wire.PushEnvironmentProduction: fake, wire.PushEnvironmentDevelopment: fake}
		cfg.HTTP = &http.Client{Timeout: 30 * time.Second, Transport: &http.Transport{ForceAttemptHTTP2: true,
			TLSClientConfig: &tls.Config{RootCAs: controllink.TestTrustRoots()}}}
		say("pushes go to " + fake + ", a walk's stand-in for APNs")
	}
	client, err := apns.New(cfg)
	if err != nil {
		say("no pushes: " + err.Error())
		return nil
	}
	return client
}

// webPusher is the VAPID key (#1486), a compose secret on the machine as the APNs key is:
// nil when there is none, which the service says once.
func webPusher() controlplane.WebPusher {
	file := os.Getenv("AGENTS_WEBPUSH_KEY_FILE")
	if file == "" {
		return nil
	}
	if info, err := os.Stat(file); err != nil || info.Size() == 0 {
		return nil
	}
	client, err := webpush.New(webpush.Config{KeyFile: file, Subject: strings.TrimSpace(os.Getenv("AGENTS_WEBPUSH_SUBJECT"))})
	if err != nil {
		say("no Web Push: " + err.Error())
		return nil
	}
	return client
}

func publicWeb() string {
	folder := value("--public-web")
	if folder == "" {
		folder = os.Getenv("AGENTS_CONTROL_PUBLIC_WEB")
	}
	if has("--no-web") || folder == "" {
		return ""
	}
	return expand(folder)
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

// privateKey is the control plane's key, from where it is kept (kms.Source, #1458): a key
// file (control/control-key, the default, and a Mac's), or with AGENTS_CONTROL_KMS sealed in
// the store by a keeper (a cloud machine's: gcpkms://…), so it is never on the disk in
// clear. A key given by --key-fd or AGENTS_CONTROL_KEY is used as it is, or with a keeper
// is sealed the first time, as is a key file found. Otherwise a keeper makes a new one.
func privateKey(st store.Store) []byte {
	key, _ := keyAndKeeper(st)
	return key
}

// keyAndKeeper is privateKey, and where it is kept so control/rotate can keep a new one
// (#997): nil for a key handed in.
func keyAndKeeper(st store.Store) ([]byte, controlplane.KeyKeeper) {
	keeper := os.Getenv("AGENTS_CONTROL_KMS")
	given, file := givenKey(), keyFile()
	var source kms.Source
	found := ""
	switch {
	case keeper != "":
		kms.NoCredentialsFile()
		if given == nil && file != "" {
			if data, err := os.ReadFile(file); err == nil && controllink.ValidPrivateKey(data) {
				given, found = data, file
			}
		}
		source = kms.Kept{Store: st, Keeper: keeper, Given: given}
	case given != nil:
		return given, nil
	case file == "":
		fail("say where the control plane's key is: AGENTS_CONTROL_KEY_FILE, AGENTS_CONTROL_KEY, --key-fd or AGENTS_CONTROL_KMS")
	default:
		source = kms.File{Path: file}
	}
	key, err := source.ControlKey(context.Background())
	if err != nil {
		fail("the control key: %v", err)
	}
	if found != "" {
		say("the control key is sealed in the store: delete " + found + ", which holds it in clear")
	}
	return key, source.(controlplane.KeyKeeper)
}

// givenKey is the key handed in by --key-fd or AGENTS_CONTROL_KEY, or nil.
func givenKey() []byte {
	if fd := value("--key-fd"); fd != "" {
		if givenFromFD != nil {
			return givenFromFD
		}
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
		givenFromFD = data
		return data
	}
	if text := os.Getenv("AGENTS_CONTROL_KEY"); text != "" {
		key, err := controllink.FromB64URL(text)
		if err != nil || len(key) != 32 {
			fail("AGENTS_CONTROL_KEY is not a key")
		}
		return key
	}
	return nil
}

// givenFromFD keeps the key read from --key-fd: the descriptor can be read only once.
var givenFromFD []byte

// keyFile is AGENTS_CONTROL_KEY_FILE, or control-key in --home.
func keyFile() string {
	if file := os.Getenv("AGENTS_CONTROL_KEY_FILE"); file != "" {
		return file
	}
	if home() != "" {
		return filepath.Join(home(), "control-key")
	}
	return ""
}

// secretKeeper is the keeper that seals people's secrets (#1760, FR-025): AGENTS_CONTROL_KMS
// on a cloud machine, else a local key in secrets-key beside the control key's file, 0600
// and outside the store. A control plane with neither keeps no secrets.
func secretKeeper() string {
	if keeper := os.Getenv("AGENTS_CONTROL_KMS"); keeper != "" {
		return keeper
	}
	file := keyFile()
	if file == "" {
		return ""
	}
	path := filepath.Join(filepath.Dir(file), "secrets-key")
	keeper, err := kms.LocalKeeper(path)
	if errors.Is(err, os.ErrPermission) || errors.Is(err, syscall.EROFS) {
		// A folder this copy can't write, such as a read-only mount (#2163). Each copy making
		// its own would seal what the others can't open: every copy is given the same one.
		fail("the key for secrets: there is none at %s, and that folder can't be written. Give every copy the same "+
			"32-byte key there (deploy/make-secrets.sh makes deploy/secrets/secrets-key), or AGENTS_CONTROL_KMS", path)
	}
	if err != nil {
		fail("the key for secrets: %v", err)
	}
	return keeper
}

// sealKey seals a key handed in, such as a Mac's for a move to a cloud machine, in the
// store with AGENTS_CONTROL_KMS (#1458). Piped in on --key-fd 0, the key is never on the
// cloud machine's disk:
//
//	ssh machine docker compose … run --rm -T control key seal --key-fd 0 < control-key
func sealKey() {
	keeper := os.Getenv("AGENTS_CONTROL_KMS")
	if keeper == "" {
		fail("say which keeper seals it: AGENTS_CONTROL_KMS=gcpkms://…")
	}
	if givenKey() == nil {
		fail("give the key to seal: --key-fd N or AGENTS_CONTROL_KEY")
	}
	public, err := controllink.PublicKey(privateKey(openStore("")))
	if err != nil {
		fail("%v", err)
	}
	say("the control key " + controllink.B64URL(public) + " is sealed in the store by " + kms.Describe(keeper))
}

// exportKey writes the control key, raw, on --key-fd: the key sealed in the store with
// AGENTS_CONTROL_KMS, or the key file's. For a move back from a cloud machine to a Mac
// (T127, #1477), piped out over ssh into a 0600 file on the Mac:
//
//	ssh machine docker compose … run --rm -T control key export --key-fd 1 > control-key
//
// Only a shell on the machine can run it: no request asks a control plane for its key. It
// makes no key, and writes none to a terminal. What it says goes to stderr, as stdout can
// be the key.
func exportKey() {
	fd, err := strconv.Atoi(value("--key-fd"))
	if err != nil || fd < 0 {
		fail("say where the key goes: --key-fd N (1 for stdout)")
	}
	out := os.NewFile(uintptr(fd), "key")
	if out == nil {
		fail("descriptor %d is not open", fd)
	}
	if info, err := out.Stat(); err != nil {
		fail("descriptor %d is not open", fd)
	} else if info.Mode()&os.ModeCharDevice != 0 {
		fail("descriptor %d is a terminal: send the key to a file, as in ssh machine … key export --key-fd 1 > control-key", fd)
	}
	var key []byte
	if keeper := os.Getenv("AGENTS_CONTROL_KMS"); keeper != "" {
		kms.NoCredentialsFile()
		key, err = kms.Existing(context.Background(), openStore(""), keeper)
	} else if file := keyFile(); file != "" {
		key, err = os.ReadFile(file)
		if err == nil && !controllink.ValidPrivateKey(key) {
			err = fmt.Errorf("%s holds no key", file)
		}
	} else {
		fail("say where the control plane's key is: AGENTS_CONTROL_KMS or AGENTS_CONTROL_KEY_FILE")
	}
	if err != nil {
		fail("the control key: %v", err)
	}
	if _, err := out.Write(key); err != nil {
		fail("the key was not written: %v", err)
	}
	public, _ := controllink.PublicKey(key)
	fmt.Fprintln(os.Stderr, "agents-control: the control key "+controllink.B64URL(public)+" is written out. Keep it in a 0600 file, and delete it once it is used.")
}

func serve() {
	// Beside the rest of what it says, in control.log, rather than in the system log (#93).
	if file := value("--log"); file != "" {
		logs.Take(expand(file), controlplane.LogLimit)
	}
	if err := logs.Configure(flagOrEnv("--log-format", "AGENTS_CONTROL_LOG_FORMAT"), flagOrEnv("--log-level", "AGENTS_CONTROL_LOG_LEVEL")); err != nil {
		fail("%v", err)
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
	cfg := controlplane.Config{URL: text, Bind: value("--bind"), Port: port, Log: logs.Write, Logger: logs.Logger(),
		ServerFolder: controlplane.ServerFolder(), ToolsetFolder: controlplane.ToolsetFolder()}
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
	// How long a client's or machine's key lives unused (#997): 90 days unless said.
	if days := value("--key-days"); days != "" || os.Getenv("AGENTS_CONTROL_KEY_DAYS") != "" {
		if days == "" {
			days = os.Getenv("AGENTS_CONTROL_KEY_DAYS")
		}
		n, err := strconv.ParseFloat(days, 64)
		if err != nil || n <= 0 {
			fail("--key-days is a number of days, more than 0")
		}
		cfg.KeyLifetime = time.Duration(n * float64(24*time.Hour))
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
	// Machine providers (#691) keep their secrets beside the control plane's own key.
	cfg.ProviderHome = home()
	if cfg.ProviderHome == "" && os.Getenv("AGENTS_CONTROL_PROVIDER_HOME") != "" {
		cfg.ProviderHome = expand(os.Getenv("AGENTS_CONTROL_PROVIDER_HOME"))
	}
	if root := value("--host-root"); root != "" {
		cfg.HostJoinFile = filepath.Join(expand(root), "control-join.json")
	}
	// Where other copies reach this one: several copies over one store (US3).
	cfg.PeerURL = os.Getenv("AGENTS_CONTROL_PEER_URL")
	// Empty, for a handover to fill (R16); and forwarding again after a restart unless
	// told to serve.
	cfg.Receive = has("--receive") || os.Getenv("AGENTS_CONTROL_RECEIVE") == "1"
	cfg.NoForwarding = has("--no-forwarding") || os.Getenv("AGENTS_CONTROL_FORWARDING") == "0"
	// The proxy in front (Caddy), whose X-Forwarded-For is a socket's source (P3).
	if cfg.TrustedProxies, err = controlplane.ParseTrustedProxies(os.Getenv("AGENTS_CONTROL_TRUSTED_PROXIES")); err != nil {
		fail("AGENTS_CONTROL_TRUSTED_PROXIES: %v", err)
	}
	cfg.Web = webConfig()
	cfg.PublicWeb = publicWeb()
	if cfg.PublicViews = value("--views-url"); cfg.PublicViews == "" {
		cfg.PublicViews = os.Getenv("AGENTS_CONTROL_VIEWS_URL")
	}
	if p := pusher(); p != nil {
		cfg.Push = p
	}
	if p := webPusher(); p != nil {
		cfg.WebPush = p
	}
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
	cfg.PrivateKey, cfg.KeyKeeper = keyAndKeeper(cfg.Store)
	cfg.SecretKeeper = secretKeeper()
	s, err := controlplane.New(cfg)
	if err != nil {
		fail("%v", err)
	}
	listening, err := s.Start(context.Background())
	if err != nil {
		fail("%v", err)
	}
	if addr := flagOrEnv("--metrics", "AGENTS_CONTROL_METRICS"); addr != "" {
		if _, err := s.ServeMetrics(addr, metricsToken()); err != nil {
			fail("metrics: %v", err)
		}
	}
	if otlp, err := controlplane.OTLPFromEnv(os.Getenv); err != nil {
		fail("otlp: %v", err)
	} else if otlp != nil {
		s.ExportOTLP(*otlp)
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
	key := privateKey(st)
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
	// --browser: for a browser, good only through a page: the loopback listener's, or the
	// page on the control plane's own domain (071 R2, #1459).
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
       agents-control serve … [--public-web DIR] [--views-url URL]
       agents-control hosts | clients
       agents-control key seal (--key-fd N | AGENTS_CONTROL_KEY)
       agents-control handover status|announce|freeze|unfreeze|withdraw|copy|take|forward|stop|shares|relay …
       agents-control key export --key-fd N
       agents-control install-script
       agents-control store check [--store URL]
       agents-control store copy --from URL --to URL
       agents-control backup --to DIR [--home DIR]
       agents-control restore --from DIR [--home DIR] [--store URL] [--new-kms]
       agents-control audit verify [--store URL]`

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
	case first == "store" && len(args) > 1 && args[1] == "copy":
		copyStore()
	case first == "handover":
		handover()
	case first == "key" && len(args) > 1 && args[1] == "seal":
		sealKey()
	case first == "key" && len(args) > 1 && args[1] == "export":
		exportKey()
	case first == "backup":
		backup()
	case first == "restore":
		restore()
	case first == "audit" && len(args) > 1 && args[1] == "verify":
		verifyAudit()
	case first == "install-script":
		fmt.Print(controlplane.InstallScript)
	case first == "--version" || first == "version":
		fmt.Println("agents-control " + buildinfo.String())
	default:
		fail("%s", usage)
	}
}
