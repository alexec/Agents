package workspacecommands

// The Compute Engine preset (#1346) and Google's service-account sign-in, against a fake
// token endpoint and a fake Compute Engine API. No real account is reached.

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
)

// fakeGoogle is a token endpoint and a Compute Engine zone's instances.
type fakeGoogle struct {
	mu        sync.Mutex
	public    *rsa.PublicKey
	tokens    int
	states    map[string]string
	requests  []string
	made      map[string]any
	badSigner bool
}

func (f *fakeGoogle) serve(t *testing.T) *httptest.Server {
	var s *httptest.Server
	s = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		body, _ := io.ReadAll(r.Body)
		if r.URL.Path == "/token" {
			form, _ := url.ParseQuery(string(body))
			parts := strings.Split(form.Get("assertion"), ".")
			if form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" || len(parts) != 3 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			signature, _ := base64.RawURLEncoding.DecodeString(parts[2])
			digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
			claims, _ := base64.RawURLEncoding.DecodeString(parts[1])
			var said map[string]any
			_ = json.Unmarshal(claims, &said)
			if f.badSigner || rsa.VerifyPKCS1v15(f.public, crypto.SHA256, digest[:], signature) != nil ||
				said["iss"] != "walker@p.iam.gserviceaccount.com" || said["aud"] != s.URL+"/token" ||
				said["scope"] != "https://www.googleapis.com/auth/compute" {
				w.WriteHeader(http.StatusBadRequest)
				fmt.Fprint(w, `{"error":"invalid_grant","error_description":"Invalid JWT Signature."}`)
				return
			}
			f.tokens++
			fmt.Fprint(w, `{"access_token":"ya29.fake","expires_in":3599,"token_type":"Bearer"}`)
			return
		}
		f.requests = append(f.requests, strings.TrimSpace(r.Method+" "+r.URL.RequestURI()))
		if r.Header.Get("Authorization") != "Bearer ya29.fake" {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `{"error":{"code":401,"message":"Request had invalid authentication credentials."}}`)
			return
		}
		const prefix = "/compute/v1/projects/p/zones/us-west1-b/instances"
		name := strings.TrimPrefix(strings.TrimPrefix(r.URL.Path, prefix), "/")
		switch {
		case r.Method == http.MethodGet:
			var items []any
			for n, state := range f.states {
				item := map[string]any{"name": n, "status": state, "labels": map[string]any{"agents": ""}}
				if state == "RUNNING" {
					item["networkInterfaces"] = []any{map[string]any{"accessConfigs": []any{map[string]any{"natIP": "203.0.113.20"}}}}
				}
				items = append(items, item)
			}
			out := map[string]any{"kind": "compute#instanceList"}
			if len(items) > 0 {
				out["items"] = items
			}
			_ = json.NewEncoder(w).Encode(out)
		case r.Method == http.MethodPost && strings.HasSuffix(name, "/start"):
			f.states[strings.TrimSuffix(name, "/start")] = "RUNNING"
			fmt.Fprint(w, `{"kind":"compute#operation","status":"RUNNING"}`)
		case r.Method == http.MethodPost && strings.HasSuffix(name, "/stop"):
			f.states[strings.TrimSuffix(name, "/stop")] = "TERMINATED"
			fmt.Fprint(w, `{"kind":"compute#operation","status":"RUNNING"}`)
		case r.Method == http.MethodPost && name == "":
			_ = json.Unmarshal(body, &f.made)
			f.states[fmt.Sprint(f.made["name"])] = "PROVISIONING"
			fmt.Fprint(w, `{"kind":"compute#operation"}`)
		case r.Method == http.MethodDelete:
			delete(f.states, name)
			fmt.Fprint(w, `{"kind":"compute#operation"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"error":{"code":404,"message":"The resource was not found"}}`)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// gcpProvider is the preset's provider at a fake Google, with a key made for the test.
func gcpProvider(t *testing.T, f *fakeGoogle) (*Provider, string) {
	t.Helper()
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	f.public = &private.PublicKey
	der, _ := x509.MarshalPKCS8PrivateKey(private)
	s := f.serve(t)
	key, _ := json.Marshal(map[string]string{"type": "service_account", "client_email": "walker@p.iam.gserviceaccount.com",
		"private_key": string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})), "token_uri": s.URL + "/token"})
	p, _ := apiProvider(t, fmt.Sprintf(`{"preset":"gcp-compute-api","project":"p","zone":"us-west1-b","api":%q,"sshKeys":["ssh-ed25519 AAAA walk"]}`, s.URL),
		GoogleSecret, string(key))
	return p, string(key)
}

func TestComputeListsLabelledVMsWithATokenFromTheKey(t *testing.T) {
	f := &fakeGoogle{states: map[string]string{"vm-a": "TERMINATED", "vm-b": "RUNNING"}}
	p, _ := gcpProvider(t, f)
	all, err := p.List()
	if err != nil || len(all) != 2 {
		t.Fatalf("%v %+v", err, all)
	}
	for _, w := range all {
		if w.Name == "vm-a" && (w.State != Stopped || w.SSH() != nil) || w.Name == "vm-b" && (w.State != Running || *w.SSH() != "agents@203.0.113.20") {
			t.Errorf("%+v", w)
		}
	}
	if f.requests[0] != "GET /compute/v1/projects/p/zones/us-west1-b/instances?filter=labels.agents%3A%2A" {
		t.Errorf("%s", f.requests[0])
	}
	// The token is kept: a second list asks for none.
	if _, err := p.List(); err != nil || f.tokens != 1 {
		t.Errorf("%v tokens %d", err, f.tokens)
	}
}

func TestComputeWithNoVMsListsNone(t *testing.T) {
	f := &fakeGoogle{states: map[string]string{}}
	p, _ := gcpProvider(t, f)
	if all, err := p.List(); err != nil || len(all) != 0 {
		t.Errorf("%v %+v", err, all)
	}
}

func TestComputeStartsStopsMakesAndDeletes(t *testing.T) {
	f := &fakeGoogle{states: map[string]string{"vm-a": "TERMINATED"}}
	p, _ := gcpProvider(t, f)
	if w, err := p.Start("vm-a"); err != nil || w.State != Running {
		t.Fatalf("%v %+v", err, w)
	}
	if w, err := p.Stop("vm-a"); err != nil || w.State != Stopped {
		t.Fatalf("%v %+v", err, w)
	}
	if !p.Config.Making.FirstBootRuns() {
		t.Error("its startup script runs the first boot")
	}
	firstBoot := "curl -fsSL https://cp.example/v1/install.sh | sh -s -- 'HOSTCODE' 'vm-new'"
	if _, err := p.Create("vm-new", map[string]any{"machineType": "e2-micro"}, firstBoot); err != nil {
		t.Fatal(err)
	}
	made, _ := json.Marshal(f.made)
	var body struct {
		Name        string
		MachineType string
		Labels      map[string]string
		Disks       []struct{ InitializeParams map[string]string }
		Metadata    struct{ Items []struct{ Key, Value string } }
	}
	_ = json.Unmarshal(made, &body)
	if body.Name != "vm-new" || body.MachineType != "zones/us-west1-b/machineTypes/e2-micro" || len(body.Labels) != 1 ||
		body.Disks[0].InitializeParams["sourceImage"] != "projects/debian-cloud/global/images/family/debian-12" {
		t.Errorf("%s", made)
	}
	script := body.Metadata.Items[0].Value
	if body.Metadata.Items[0].Key != "startup-script" || !strings.Contains(script, "\n"+firstBoot+"\n") ||
		!strings.Contains(script, "agents-first-boot-done") || !strings.Contains(script, "su - agents") {
		t.Errorf("%s", script)
	}
	// The keys are not Google's ssh-keys, whose user the guest agent makes a sudoer.
	if body.Metadata.Items[1].Key != "agents-ssh-keys" || body.Metadata.Items[1].Value != "ssh-ed25519 AAAA walk\n" ||
		!strings.Contains(script, "attributes/agents-ssh-keys") {
		t.Errorf("%+v", body.Metadata.Items)
	}
	if err := p.Delete("vm-new"); err != nil || f.requests[len(f.requests)-1] != "DELETE /compute/v1/projects/p/zones/us-west1-b/instances/vm-new" {
		t.Errorf("%v %q", err, f.requests)
	}
}

func TestAKeyGoogleRefusesIsSaidInItsWords(t *testing.T) {
	f := &fakeGoogle{states: map[string]string{}, badSigner: true}
	p, _ := gcpProvider(t, f)
	_, err := p.List()
	if err == nil || !strings.Contains(err.Error(), "It can't get a token: 127.0.0.1") || !strings.Contains(err.Error(), "invalid_grant: Invalid JWT Signature.") {
		t.Fatalf("%v", err)
	}
	if strings.Contains(err.Error(), "PRIVATE KEY") {
		t.Error("the key is in the error")
	}
	p.Env = func(string) (string, bool) { return `{"type":"x"}`, true }
	if _, err := p.List(); err == nil || err.Error() != "Its GOOGLE_SERVICE_ACCOUNT_KEY secret isn't a service account's JSON key." {
		t.Errorf("%v", err)
	}
}

func TestComputeChecksItsNames(t *testing.T) {
	refused(t, `{"preset":"gcp-compute-api","zone":"z"}`, "the gcp-compute-api preset needs a project")
	refused(t, `{"preset":"gcp-compute-api","project":"p"}`, "the gcp-compute-api preset needs a zone")
	refused(t, `{"preset":"gcp-compute-api","project":"p/../x","zone":"z"}`, "the gcp-compute-api preset's project is lower-case letters, digits and dashes")
	refused(t, `{"list":{"url":"https://x/y","googleAuth":{}},"json":{"id":"id"},"start":"a","stop":"b"}`, "list.googleAuth needs a scope")
}
