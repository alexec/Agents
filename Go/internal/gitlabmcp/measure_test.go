package gitlabmcp

import (
	"flag"
	"strconv"
	"testing"
	"time"
)

var measure = flag.Bool("measure", false, "run the measurements")

// The measurement of P20261020-1, run by hand with `-args -measure`: HTTP requests per poll
// of one `issue.labelled label=agent` wait over 100 polls, with N issues updated since it
// started and none labelled agent.
func TestMeasureLabelledRequestsPerPoll(t *testing.T) {
	if !*measure {
		t.Skip("-args -measure to measure")
	}
	for _, n := range []int{10, 100, 500, 1000} {
		f := newFake(t)
		f.addMembers()
		agent := newPoller(t, f, "issue.labelled", map[string]any{"label": "agent"})
		agent.poll()
		f.set(func() {
			for i := 1; i <= n; i++ {
				updated := timeString(start.Add(time.Duration(i) * time.Millisecond))
				f.issues = append(f.issues, issueObj(i, dev, obj{"updated_at": updated, "labels": []string{"bug"}}))
				f.labelled[i] = []obj{{"id": i, "action": "add", "created_at": updated, "user": dev, "label": obj{"name": "bug"}}}
			}
		})
		began := time.Now()
		var first, last, total int
		for poll := 1; poll <= 100; poll++ {
			before := len(f.asked())
			agent.poll()
			asked := len(f.asked()) - before
			total += asked
			if poll == 1 {
				first = asked
			}
			last = asked
		}
		t.Logf("N=%d requests: poll 1 %d, poll 100 %d, total %d; %s ms", n, first, last, total,
			strconv.FormatInt(time.Since(began).Milliseconds(), 10))
	}
}
