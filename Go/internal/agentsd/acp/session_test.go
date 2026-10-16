package acp

import (
	"bufio"
	"io"
	"strings"
	"testing"

	sdk "github.com/coder/acp-go-sdk"
)

// The runtime's own params reach the daemon, propertyOrder and all, though the SDK's typed
// request has no place for it; what the SDK reads is unchanged.
func TestTheRuntimesOwnElicitationParamsAreKept(t *testing.T) {
	c := &client{}
	in := `{"jsonrpc":"2.0","id":7,"method":"elicitation/create","params":{"mode":"form","message":"M","requestedSchema":{"propertyOrder":["b","a"],"properties":{}}}}` + "\n" +
		`{"jsonrpc":"2.0","method":"session/update","params":{}}` + "\n"
	out, err := io.ReadAll(&rawElicitations{r: bufio.NewReader(strings.NewReader(in)), c: c})
	if err != nil || string(out) != in {
		t.Fatalf("what the SDK read changed: %q %v", out, err)
	}
	if len(c.raw) != 1 || !strings.Contains(string(c.raw[0]), "propertyOrder") {
		t.Fatalf("%q", c.raw)
	}
	m := "M"
	got := c.takeRaw(sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Message: m}})
	if !strings.Contains(string(got), `"propertyOrder":["b","a"]`) || len(c.raw) != 0 {
		t.Fatalf("%s", got)
	}
	// None kept: the typed request itself.
	if got := c.takeRaw(sdk.UnstableCreateElicitationRequest{Form: &sdk.UnstableCreateElicitationForm{Message: "other"}}); !strings.Contains(string(got), `"other"`) {
		t.Fatalf("%s", got)
	}
}
