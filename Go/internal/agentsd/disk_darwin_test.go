package agentsd

import (
	"os"
	"syscall"
	"testing"
)

// A Mac's home is on the data volume, and its reading says the volume's name and "/",
// as Foundation's does, not "This server's disk" (#1138).
func TestDiskVolumeNamesTheMacsVolume(t *testing.T) {
	home, _ := os.UserHomeDir()
	var st syscall.Statfs_t
	if err := syscall.Statfs(home, &st); err != nil {
		t.Fatal(err)
	}
	name, mount := diskVolume(&st, 0)
	if mount != "/" {
		t.Errorf("mount = %q, want /", mount)
	}
	if name == "" || name == "/" || name == "This server’s disk" {
		t.Errorf("name = %q, want the volume's own name", name)
	}
	if got := volumeName("/"); got != name {
		t.Errorf("volumeName(/) = %q, the home's reading says %q", got, name)
	}
}
