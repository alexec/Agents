package machine

import (
	"os/exec"
	"regexp"
	"strings"
)

var platformUUID = regexp.MustCompile(`"IOPlatformUUID" = "([0-9A-Fa-f-]{36})"`)

// hardwareUUID is gethostuuid(2), which MachineID.current reads on a Mac: the platform
// expert's IOPlatformUUID, read without cgo (kern.uuid is another value). Upper case, as
// UUID.uuidString.
func hardwareUUID() string {
	out, err := exec.Command("/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice").Output()
	if err != nil {
		return ""
	}
	return parsePlatformUUID(string(out))
}

func parsePlatformUUID(ioreg string) string {
	m := platformUUID.FindStringSubmatch(ioreg)
	if m == nil {
		return ""
	}
	return strings.ToUpper(m[1])
}
