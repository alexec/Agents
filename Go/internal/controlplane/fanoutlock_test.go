package controlplane

import (
	"slices"
	"testing"
)

// A fan-out frame carries each checked channel's lock member (#3541): the router reads it on
// both paths and adds it to that channel's copy, so the client checks what the machine said.
func TestAFanOutFrameCarriesEachChannelsLockMember(t *testing.T) {
	const m = `{"jsonrpc":"2.0","method":"agent/changed","params":{"id":"A1"}}`
	const tail = `{"n":3,"mac":"` + "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" + `"}`
	for _, line := range []string{
		`{"f":[1,2],"l":[null,` + tail + `],"m":` + m + `}`,
		`{"m":` + m + `,"l":[null,` + tail + `],"f":[1,2]}`,
	} {
		f, ok := readHostFrame(line)
		if !ok || !slices.Equal(f.channels, []int{1, 2}) || f.msg != m || !slices.Equal(f.tails, []string{"", tail}) {
			t.Fatalf("%s: %+v %v", line, f, ok)
		}
		if got := withLock(f.msg, f.tails[1]); got != m[:len(m)-1]+`,"lock":`+tail+`}` {
			t.Fatalf("the copy %s", got)
		}
		if got := withLock(f.msg, f.tails[0]); got != m {
			t.Fatalf("a channel with no member %s", got)
		}
	}
	// A frame from a machine before #3541 has none.
	if f, ok := readHostFrame(`{"f":[1,2],"m":` + m + `}`); !ok || f.tails != nil || f.msg != m {
		t.Fatalf("an old frame %+v %v", f, ok)
	}
	// One member too few, or one that is not an object: the frame is not read.
	for _, line := range []string{
		`{"f":[1,2],"l":[null],"m":` + m + `}`,
		`{"f":[1,2],"l":[null,"x"],"m":` + m + `}`,
	} {
		if _, ok := readHostFrame(line); ok {
			t.Fatalf("read %s", line)
		}
	}
}
