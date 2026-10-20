package workspacecommands

// The AWS EC2 preset (#1345): SigV4 against AWS's own test vector, and the preset against a
// fake EC2 Query API that answers XML. No real account is reached.

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	awsKey    = "AKIDEXAMPLE"
	awsSecret = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
)

// AWS's Signature Version 4 test suite, get-vanilla.
func TestSigV4MatchesAWSsTestVector(t *testing.T) {
	r, _ := http.NewRequest("GET", "https://example.amazonaws.com/", nil)
	signAWS(r, nil, AWSSign{Service: "service", Region: "us-east-1"}, awsKey, awsSecret, "",
		time.Date(2015, 8, 30, 12, 36, 0, 0, time.UTC))
	want := "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
		"SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
	if got := r.Header.Get("Authorization"); got != want {
		t.Errorf("%s", got)
	}
	if r.Header.Get("X-Amz-Date") != "20150830T123600Z" {
		t.Errorf("%v", r.Header)
	}
}

func TestSigV4SignsTheQueryInItsCanonicalOrderAndASessionToken(t *testing.T) {
	r, _ := http.NewRequest("GET", "https://ec2.us-east-1.amazonaws.com/?Version=2016-11-15&Action=Describe+Instances&B=a%2Fb", nil)
	signAWS(r, nil, AWSSign{Service: "ec2", Region: "us-east-1"}, awsKey, awsSecret, "session-1",
		time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC))
	if r.URL.RawQuery != "Action=Describe%20Instances&B=a%2Fb&Version=2016-11-15" {
		t.Errorf("%s", r.URL.RawQuery)
	}
	if r.Header.Get("X-Amz-Security-Token") != "session-1" ||
		!strings.Contains(r.Header.Get("Authorization"), "SignedHeaders=host;x-amz-date;x-amz-security-token,") {
		t.Errorf("%v", r.Header)
	}
}

// fakeEC2 answers DescribeInstances, StartInstances and StopInstances as EC2 does, in XML.
type fakeEC2 struct {
	mu      sync.Mutex
	states  map[string]string
	queries []string
	headers []http.Header
}

func (f *fakeEC2) serve(t *testing.T) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.queries = append(f.queries, r.URL.RawQuery)
		f.headers = append(f.headers, r.Header.Clone())
		w.Header().Set("Content-Type", "text/xml")
		if !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 Credential="+awsKey+"/") ||
			!strings.Contains(r.Header.Get("Authorization"), "/us-east-1/ec2/aws4_request, SignedHeaders=host;x-amz-date, Signature=") {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `<?xml version="1.0" encoding="UTF-8"?>
<Response><Errors><Error><Code>AuthFailure</Code><Message>AWS was not able to validate the provided access credentials</Message></Error></Errors><RequestID>r-1</RequestID></Response>`)
			return
		}
		q := r.URL.Query()
		switch q.Get("Action") {
		case "DescribeInstances":
			fmt.Fprint(w, `<?xml version="1.0" encoding="UTF-8"?>
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/"><requestId>r-2</requestId><reservationSet>`)
			for _, id := range []string{"i-0aaa", "i-0bbb"} {
				ip := ""
				if f.states[id] == "running" {
					ip = "<ipAddress>198.51.100.4</ipAddress>"
				}
				fmt.Fprintf(w, `<item><reservationId>r-%s</reservationId><instancesSet><item><instanceId>%s</instanceId>
<instanceState><code>16</code><name>%s</name></instanceState>%s<privateIpAddress>10.0.0.9</privateIpAddress>
<tagSet><item><key>agents</key><value></value></item><item><key>Name</key><value>dev %s</value></item></tagSet></item></instancesSet></item>`,
					id, id, f.states[id], ip, id)
			}
			fmt.Fprint(w, `</reservationSet></DescribeInstancesResponse>`)
		case "StartInstances", "StopInstances":
			id := q.Get("InstanceId.1")
			if _, ok := f.states[id]; !ok {
				w.WriteHeader(http.StatusBadRequest)
				fmt.Fprintf(w, `<Response><Errors><Error><Code>InvalidInstanceID.NotFound</Code><Message>The instance ID '%s' does not exist</Message></Error></Errors></Response>`, id)
				return
			}
			if q.Get("Action") == "StartInstances" {
				f.states[id] = "running"
			} else {
				f.states[id] = "stopped"
			}
			fmt.Fprintf(w, `<StartInstancesResponse><instancesSet><item><instanceId>%s</instanceId></item></instancesSet></StartInstancesResponse>`, id)
		default:
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func ec2Provider(t *testing.T, f *fakeEC2, secrets map[string]string) (*Provider, *[]string) {
	t.Helper()
	s := f.serve(t)
	p, logged := apiProvider(t, fmt.Sprintf(`{"preset":"aws-ec2-api","region":"us-east-1","api":%q}`, s.URL), "", "")
	p.Env = func(name string) (string, bool) { v, ok := secrets[name]; return v, ok }
	return p, logged
}

var ec2Keys = map[string]string{AWSKeySecret: awsKey, AWSSecretSecret: awsSecret}

func TestEC2ListsTaggedInstancesAcrossReservations(t *testing.T) {
	f := &fakeEC2{states: map[string]string{"i-0aaa": "stopped", "i-0bbb": "running"}}
	p, _ := ec2Provider(t, f, ec2Keys)
	all, err := p.List()
	if err != nil || len(all) != 2 {
		t.Fatalf("%v %+v", err, all)
	}
	if all[0].ID != "i-0aaa" || all[0].Name != "dev i-0aaa" || all[0].State != Stopped || all[0].SSH() != nil {
		t.Errorf("%+v", all[0])
	}
	if all[1].State != Running || *all[1].SSH() != "ec2-user@198.51.100.4" {
		t.Errorf("%+v", all[1])
	}
	q := f.queries[0]
	for _, part := range []string{"Action=DescribeInstances", "Version=2016-11-15", "Filter.1.Name=tag-key",
		"Filter.1.Value.1=agents", "Filter.2.Name=instance-state-name", "Filter.2.Value.2=running"} {
		if !strings.Contains(q, part) {
			t.Errorf("%s has no %s", q, part)
		}
	}
	for _, h := range f.headers {
		for _, values := range h {
			for _, v := range values {
				if strings.Contains(v, awsSecret) {
					t.Errorf("the secret key was sent: %s", v)
				}
			}
		}
	}
}

func TestEC2StartsAndStopsAndWaitsForTheState(t *testing.T) {
	f := &fakeEC2{states: map[string]string{"i-0aaa": "stopped", "i-0bbb": "running"}}
	p, logged := ec2Provider(t, f, ec2Keys)
	w, err := p.Start("i-0aaa")
	if err != nil || w.State != Running || *w.SSH() != "ec2-user@198.51.100.4" {
		t.Fatalf("%v %+v", err, w)
	}
	if w, err := p.Stop("i-0bbb"); err != nil || w.State != Stopped {
		t.Errorf("%v %+v", err, w)
	}
	var actions []string
	for _, q := range f.queries {
		if !strings.Contains(q, "DescribeInstances") {
			actions = append(actions, q)
		}
	}
	if len(actions) != 2 || !strings.Contains(actions[0], "Action=StartInstances") || !strings.Contains(actions[0], "InstanceId.1=i-0aaa") ||
		!strings.Contains(actions[1], "Action=StopInstances") || !strings.Contains(actions[1], "InstanceId.1=i-0bbb") {
		t.Errorf("%q", actions)
	}
	for _, line := range *logged {
		if strings.Contains(line, awsSecret) || strings.Contains(line, awsKey) {
			t.Errorf("%s", line)
		}
	}
}

func TestEC2SaysItsRefusalInItsWordsWithoutTheKeys(t *testing.T) {
	f := &fakeEC2{states: map[string]string{"i-0aaa": "stopped"}}
	p, _ := ec2Provider(t, f, map[string]string{AWSKeySecret: "AKIAWRONG", AWSSecretSecret: awsSecret})
	_, err := p.List()
	if err == nil || !strings.Contains(err.Error(), "answered 401: AWS was not able to validate the provided access credentials. Check its secrets") {
		t.Fatalf("%v", err)
	}
	if strings.Contains(err.Error(), awsSecret) || strings.Contains(err.Error(), "AKIAWRONG") {
		t.Errorf("%v", err)
	}
	p, _ = ec2Provider(t, f, ec2Keys)
	if _, err := p.Start("i-0nope"); err == nil || !strings.Contains(err.Error(), "There is no workspace i-0nope.") {
		t.Errorf("%v", err)
	}
}

func TestEC2WithoutItsKeysSaysWhichToGive(t *testing.T) {
	f := &fakeEC2{states: map[string]string{}}
	p, _ := ec2Provider(t, f, map[string]string{AWSKeySecret: awsKey})
	if _, err := p.List(); err == nil || err.Error() != "It needs the AWS_SECRET_ACCESS_KEY secret." {
		t.Errorf("%v", err)
	}
	if len(f.queries) != 0 {
		t.Errorf("%q", f.queries)
	}
}

func TestEC2NeedsARegionAndTakesItsOptions(t *testing.T) {
	refused(t, `{"preset":"aws-ec2-api"}`, "the aws-ec2-api preset needs a region, such as us-east-1")
	refused(t, `{"preset":"aws-ec2-api","region":"us-east-1.evil.example/x"}`, "the aws-ec2-api preset's region is a name such as us-east-1")
	c := config(t, `{"preset":"aws-ec2-api","region":"eu-west-2","tag":"team a","user":"ubuntu"}`)
	if c.Listing.Request.URL[:37] != "https://ec2.eu-west-2.amazonaws.com/?" || !strings.Contains(c.Listing.Request.URL, "Filter.1.Value.1=team+a") ||
		*c.Listing.Commands.SSH != "ubuntu@${ip}" || c.Listing.Request.Sign.Region != "eu-west-2" || c.Making.CanCreate() {
		t.Errorf("%+v %+v", c.Listing.Request, c.Listing.Commands)
	}
}

func TestXMLIsReadAsJSONIs(t *testing.T) {
	v, err := xmlValue([]byte(`<R><a>1</a><emptySet/><b><item><k>x</k></item><item><k>y</k></item></b><c><d>t</d></c></R>`))
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := PathText("a", v); got != "1" {
		t.Errorf("%v", v)
	}
	if got, _ := PathText("b[k=y].k", v); got != "y" {
		t.Errorf("%v", v)
	}
	if got, _ := PathText("c.d", v); got != "t" {
		t.Errorf("%v", v)
	}
	if list, ok := PathValue("emptySet", v).([]any); !ok || len(list) != 0 {
		t.Errorf("an empty Set is an empty list: %v", PathValue("emptySet", v))
	}
}

func TestAnEmptyStepJoinsTheListsItFinds(t *testing.T) {
	v := j(t, `{"r":[{"i":[{"id":1},{"id":2}]},{"i":[]},{"i":[{"id":3}]},{"x":1}]}`)
	list, ok := PathValue("r[].i", v).([]any)
	if !ok || len(list) != 3 {
		t.Fatalf("%v", PathValue("r[].i", v))
	}
	if got, _ := PathText("r[].i[2].id", v); got != "" {
		t.Errorf("a step after the lists are joined goes into each item: %s", got)
	}
	if ids := PathValue("r[].i[].id", v).([]any); len(ids) != 3 {
		t.Errorf("%v", ids)
	}
}
