package machine

import (
	"os/exec"
	"strings"
	"testing"
)

func TestParsePlatformUUID(t *testing.T) {
	out := `+-o J316sAP  <class IOPlatformExpertDevice>
    {
      "IOPlatformSerialNumber" = "X"
      "IOPlatformUUID" = "8ab85821-9D24-59CE-9737-8FC556923733"
    }`
	if got := parsePlatformUUID(out); got != "8AB85821-9D24-59CE-9737-8FC556923733" {
		t.Fatalf("got %q", got)
	}
	if got := parsePlatformUUID("nothing"); got != "" {
		t.Fatalf("got %q", got)
	}
}

// A Mac is its hardware UUID, the id its pinned workflows name, not its host name.
func TestAMacIsItsHardwareUUID(t *testing.T) {
	t.Setenv("AGENTS_MACHINE_ID", "")
	out, err := exec.Command("/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
	if err != nil {
		t.Skip(err)
	}
	want := parsePlatformUUID(string(out))
	if want == "" || ID() != want || strings.ToUpper(ID()) != ID() {
		t.Fatalf("ID %q, ioreg %q", ID(), want)
	}
}
