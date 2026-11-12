package agentsd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseDiskOverride(t *testing.T) {
	for text, want := range map[string]int64{"500GB\n": 500 * gigabyte, " 1.5 gb ": 1_500_000_000, "1500000000": 1_500_000_000, "0": 0} {
		if got, ok := parseDiskOverride(text); !ok || got != want {
			t.Errorf("%q = %d %v, want %d", text, got, ok, want)
		}
	}
	for _, text := range []string{"", "lots", "-1", "-2GB", "GB"} {
		if got, ok := parseDiskOverride(text); ok {
			t.Errorf("%q = %d, want no override", text, got)
		}
	}
}

// A scratch root's disk-free-override says each volume's free space (#195, #4851), so a
// video never shows the real disk; a root that may not read it shows the real one.
func TestAScratchRootsDiskOverrideSaysTheFreeSpace(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "disk-free-override"), []byte("1GB\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	d, _ := start(t, root)
	d.checkDisk()
	if len(d.diskVolumes) == 0 || d.diskVolumes[0].Reading.FreeBytes == gigabyte {
		t.Fatalf("the override was read with DiskOverride off: %+v", d.diskVolumes)
	}

	d.DiskOverride = true
	d.checkDisk()
	if len(d.diskVolumes) == 0 {
		t.Fatal("no disk")
	}
	for _, v := range d.diskVolumes {
		if v.Reading.FreeBytes != gigabyte {
			t.Fatalf("free %d, want the override's 1 GB: %+v", v.Reading.FreeBytes, v)
		}
	}
	if len(d.diskState().Alarms) == 0 {
		t.Fatal("1 GB free is an alarm on any disk over 10 GB")
	}

	// More than the disk holds is a full disk's worth free, not more.
	if err := os.WriteFile(filepath.Join(root, "disk-free-override"), []byte("1000000GB"), 0o600); err != nil {
		t.Fatal(err)
	}
	d.checkDisk()
	for _, v := range d.diskVolumes {
		if v.Reading.FreeBytes != v.Reading.TotalBytes {
			t.Fatalf("free %d of %d", v.Reading.FreeBytes, v.Reading.TotalBytes)
		}
	}
	if n := len(d.diskState().Alarms); n != 0 {
		t.Fatalf("%d alarms on a free disk", n)
	}
}
