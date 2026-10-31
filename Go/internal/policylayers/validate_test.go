package policylayers

import (
	"strings"
	"testing"
)

func TestValidateRejectsAnOverSizeLayer(t *testing.T) {
	raw := []byte(`{"environment":{"passThrough":["` + strings.Repeat("A", maxLayerBytes) + `"]}}`)
	if _, err := Validate(raw); err == nil {
		t.Fatal("a layer over 16 KiB must be rejected")
	}
	if _, err := Validate([]byte(`{}`)); err != nil {
		t.Fatalf("an empty layer must be valid: %v", err)
	}
}

func TestValidateRejectsAnUnknownEnumValue(t *testing.T) {
	cases := []string{
		`{"permissionMode":"superadmin"}`,
		`{"permissionRequests":"maybe"}`,
		`{"sandbox":"sometimes"}`,
		`{"marketplaces":{"allowed":[],"customServers":"maybe"}}`,
	}
	for _, raw := range cases {
		if _, err := Validate([]byte(raw)); err == nil {
			t.Fatalf("%s: an unknown enum value must be rejected", raw)
		}
	}
}

func TestValidateRejectsANumberOutOfRange(t *testing.T) {
	cases := []string{
		`{"budgets":{"perAgentTokens":0}}`,
		`{"budgets":{"dailyTokens":-1}}`,
		`{"helpers":{"mostRunning":0}}`,
		`{"helpers":{"mostRunning":11}}`,
		`{"helpers":{"mostNotArchived":21}}`,
		`{"workflows":{"mostOn":0}}`,
		`{"workflows":{"mostOn":101}}`,
		`{"noticeLimits":{"burst":0}}`,
		`{"noticeLimits":{"burst":21}}`,
		`{"noticeLimits":{"waitMinutes":0}}`,
		`{"noticeLimits":{"waitMinutes":1441}}`,
	}
	for _, raw := range cases {
		if _, err := Validate([]byte(raw)); err == nil {
			t.Fatalf("%s: a number out of range must be rejected", raw)
		}
	}
	valid := []string{
		`{"helpers":{"mostRunning":1,"mostNotArchived":20}}`,
		`{"workflows":{"mostOn":100}}`,
		`{"noticeLimits":{"burst":20,"waitMinutes":1440}}`,
		`{"budgets":{"perAgentTokens":1,"dailyTokens":1}}`,
	}
	for _, raw := range valid {
		if _, err := Validate([]byte(raw)); err != nil {
			t.Fatalf("%s: must be valid: %v", raw, err)
		}
	}
}

func TestValidateRejectsAnEmptyListName(t *testing.T) {
	cases := []string{
		`{"marketplaces":{"allowed":[""],"customServers":"allow"}}`,
		`{"environment":{"passThrough":[""]}}`,
		`{"runtimes":{"claude":{"models":[""]}}}`,
	}
	for _, raw := range cases {
		if _, err := Validate([]byte(raw)); err == nil {
			t.Fatalf("%s: an empty name must be rejected", raw)
		}
	}
}

func TestValidateIgnoresAndLogsAnUnknownFieldOnce(t *testing.T) {
	rules, err := Validate([]byte(`{"permissionMode":"ask","notARule":true}`))
	if err != nil {
		t.Fatalf("an unknown field must be ignored, not rejected: %v", err)
	}
	if rules.PermissionMode == nil || *rules.PermissionMode != "ask" {
		t.Fatal("known fields beside an unknown one must still be read")
	}
	// Calling twice must not panic or error from the dedup map; it only logs once.
	if _, err := Validate([]byte(`{"notARule":true}`)); err != nil {
		t.Fatalf("an unknown field alone must still validate: %v", err)
	}
}

func TestValidateRejectsNotJSON(t *testing.T) {
	if _, err := Validate([]byte(`not json`)); err == nil {
		t.Fatal("invalid JSON must be rejected")
	}
}
