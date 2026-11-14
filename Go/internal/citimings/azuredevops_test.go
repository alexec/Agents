package citimings

import (
	"encoding/json"
	"testing"
)

func TestFromAzureDevOpsKeepsEachAttempt(t *testing.T) {
	var b AzureBuild
	if err := json.Unmarshal([]byte(`{"id":70,"status":"completed","result":"succeeded","queueTime":"2026-11-10T11:20:00.5Z",
	 "startTime":"2026-11-10T11:20:05Z","finishTime":"2026-11-10T13:10:00Z","sourceBranch":"refs/heads/main","sourceVersion":"abc",
	 "reason":"individualCI","definition":{"name":"CI"},"queue":{"name":"Default"}}`), &b); err != nil {
		t.Fatal(err)
	}
	// Two stages, each with a job named Build; Test / Build was run again.
	now := []byte(`{"records":[
	 {"id":"s1","type":"Stage","name":"Lint"},
	 {"id":"p1","parentId":"s1","type":"Phase","name":"Build","startTime":"2026-11-10T11:20:10.5Z"},
	 {"id":"j1","parentId":"p1","type":"Job","name":"Build","attempt":1,"result":"succeeded","startTime":"2026-11-10T11:20:30.5Z","finishTime":"2026-11-10T11:22:00.5Z"},
	 {"id":"s2","type":"Stage","name":"Test"},
	 {"id":"p2","parentId":"s2","type":"Phase","name":"Build","startTime":"2026-11-10T13:00:00.5Z"},
	 {"id":"j2","parentId":"p2","type":"Job","name":"Build","attempt":2,"result":"succeeded","startTime":"2026-11-10T13:01:00.5Z","finishTime":"2026-11-10T13:05:00.5Z",
	  "previousAttempts":[{"attempt":1,"timelineId":"tl-1","recordId":"j2-old"}]},
	 {"id":"t2","parentId":"j2","type":"Task","name":"Test","order":2,"result":"succeeded","startTime":"2026-11-10T13:01:01.5Z","finishTime":"2026-11-10T13:05:00.5Z"},
	 {"id":"t3","parentId":"j2","type":"Task","name":"Never","order":3,"result":"skipped"}]}`)
	old := []byte(`{"records":[
	 {"id":"p2-old","parentId":"s2","type":"Phase","name":"Build","startTime":"2026-11-10T11:22:10.5Z"},
	 {"id":"j2-old","parentId":"p2-old","type":"Job","name":"Build","attempt":1,"result":"failed","startTime":"2026-11-10T11:22:20.5Z","finishTime":"2026-11-10T11:24:00.5Z"}]}`)
	if ids := AzureEarlierTimelines(now); len(ids) != 1 || ids[0] != "tl-1" {
		t.Fatalf("earlier timelines %v", ids)
	}
	got, err := FromAzureDevOps(b, now, map[string][]byte{"tl-1": old}, "azuredevops:run:acme/web/app#70", true, false)
	if err != nil || len(got) != 2 {
		t.Fatalf("%+v %v", got, err)
	}
	first, second := got[0], got[1]
	if first.Attempt != 1 || first.Conclusion != "failure" || first.Workflow != "CI" || len(first.Jobs) != 2 || first.Started != 10 {
		t.Fatalf("first %+v", first)
	}
	lint, test := first.Jobs[0], first.Jobs[1]
	if lint.Name != "Lint / Build" || lint.Made != 10 || lint.Started != 30 || lint.Ended != 120 || lint.Runner != "Default" || lint.Conclusion != "success" {
		t.Fatalf("lint %+v", lint)
	}
	if test.Name != "Test / Build" || test.Made != 130 || test.Started != 140 || test.Ended != 240 || test.Conclusion != "failure" {
		t.Fatalf("attempt 1's test %+v", test)
	}
	if second.Attempt != 2 || second.Conclusion != "success" || second.Started != 4.5 || second.Ended != 6599.5 || !second.Default || len(second.Jobs) != 1 {
		t.Fatalf("second %+v", second)
	}
	if s := second.Jobs[0].Steps; len(s) != 1 || s[0].Name != "Test" || s[0].Number != 2 || s[0].Started != 6061 {
		t.Fatalf("steps %+v", s)
	}
	for in, want := range map[string]string{"partiallySucceeded": "neutral", "canceled": "cancelled", "failed": "failure", "succeeded": "success"} {
		if got := AzureConclusion(in); got != want {
			t.Errorf("%s is %s, want %s", in, got, want)
		}
	}
}
