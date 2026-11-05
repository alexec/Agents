package controllink

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The sealing vectors (#3397): what Go seals, the web page (Web/test/sealing.test.mjs) and
// AgentsKit (SealingTests) open with the same key and the same associated data, made by each
// language from the same inputs. go test -run TestTheSealingVectorsOpen -args -write-sealing-vectors
// seals them afresh.
const sealingVectors = "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/sealing/vectors.json"

var writeSealingVectors = flag.Bool("write-sealing-vectors", false, "seal the sealing vectors afresh")

type sealingVector struct {
	Item      string                 `json:"item"`
	ID        string                 `json:"id,omitempty"`
	User      string                 `json:"user,omitempty"`
	Recipient string                 `json:"recipient"`
	Field     string                 `json:"field"`
	Version   int64                  `json:"version"`
	Kind      wire.OrgRouteKind      `json:"kind,omitempty"`
	Vendor    *wire.OrgRouteVendor   `json:"vendor,omitempty"`
	Settings  *wire.OrgRouteSettings `json:"settings,omitempty"`
	AD        string                 `json:"ad"`
	Value     string                 `json:"value"`
	Sealed    wire.SealedEnvelope    `json:"sealed"`
}

type sealingVectorFile struct {
	// PrivateKey is the recipient's P-256 scalar, hex: a test key, for these vectors only.
	PrivateKey string          `json:"privateKey"`
	PublicKey  []byte          `json:"publicKey"`
	Vectors    []sealingVector `json:"vectors"`
}

func (v sealingVector) ad() []byte {
	if v.Item == "userSecret" {
		return UserSecretAD(v.User, v.Recipient, v.Field, v.Version)
	}
	return OrgRouteAD(v.ID, v.Recipient, v.Field, v.Version, v.Kind, v.Vendor, v.Settings)
}

func (v sealingVector) info() string {
	if v.Item == "userSecret" {
		return UserSecretPurpose
	}
	return OrgRoutePurpose
}

func TestTheSealingVectorsOpen(t *testing.T) {
	anthropic := wire.OrgRouteVendorAnthropic
	vectors := []sealingVector{
		{Item: "orgRoute", ID: "acme", Recipient: MachineRecipient("host-1"), Field: "apiKey", Version: 2, Kind: wire.OrgRouteKindBaseURL,
			Vendor: &anthropic, Settings: &wire.OrgRouteSettings{Address: new("https://llm.acme.example"), Header: new("X-Key")},
			AD:    "orgroute.v3|acme|m:host-1|apiKey|2|baseURL|anthropic|944e36afb363daaf3ed4e5d5f15f09b6239d46a11edbfa500cb1c1eea8583220",
			Value: "sk-ant-fixture-0123"},
		{Item: "orgRoute", ID: "vertex", Recipient: ClientRecipient("5b0c9a2e-1111-4c2d-9e8f-0a1b2c3d4e5f"), Field: "serviceAccount", Version: 1,
			Kind: wire.OrgRouteKindVertex, Settings: &wire.OrgRouteSettings{Project: new("acme-ai"), Location: new("us-east5")},
			Value: `{"client_email":"a@b"}`},
		{Item: "userSecret", User: "sam", Recipient: MachineRecipient("host-1"), Field: "GITHUB_TOKEN", Version: 1762300000000,
			AD: "usersecret.v1|sam|m:host-1|GITHUB_TOKEN|1762300000000", Value: "ghp_fixture"},
	}
	if *writeSealingVectors {
		private := NewPrivateKey()
		public, _ := PublicKey(private)
		file := sealingVectorFile{PrivateKey: hex.EncodeToString(private), PublicKey: public}
		for _, v := range vectors {
			v.AD = string(v.ad())
			sealed, err := Seal(public, v.info(), v.ad(), []byte(v.Value))
			if err != nil {
				t.Fatal(err)
			}
			v.Sealed = sealed
			file.Vectors = append(file.Vectors, v)
		}
		b, _ := json.MarshalIndent(file, "", "  ")
		os.MkdirAll(filepath.Dir(sealingVectors), 0o755)
		if err := os.WriteFile(sealingVectors, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	b, err := os.ReadFile(sealingVectors)
	if err != nil {
		t.Fatal(err)
	}
	var file sealingVectorFile
	if err := json.Unmarshal(b, &file); err != nil {
		t.Fatal(err)
	}
	private, _ := hex.DecodeString(file.PrivateKey)
	if len(file.Vectors) != len(vectors) {
		t.Fatalf("%d vectors, not %d", len(file.Vectors), len(vectors))
	}
	for i, v := range file.Vectors {
		if want := vectors[i].AD; want != "" && v.AD != want {
			t.Errorf("%s: the associated data is %q, not %q", v.ID+v.User, v.AD, want)
		}
		if got := string(v.ad()); got != v.AD {
			t.Errorf("%s: made %q, the vector says %q", v.ID+v.User, got, v.AD)
		}
		plain, err := Open(private, v.info(), v.ad(), v.Sealed)
		if err != nil || string(plain) != v.Value {
			t.Errorf("%s: %q %v", v.ID+v.User, plain, err)
		}
		// Another field, recipient or version does not open it.
		other := v
		other.Version++
		if _, err := Open(private, v.info(), other.ad(), v.Sealed); err == nil {
			t.Errorf("%s opens at another version", v.ID+v.User)
		}
	}
}
