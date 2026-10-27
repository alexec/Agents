package store

import "testing"

func TestMacFolders(t *testing.T) {
	home := "/Users/someone"
	l := macFolders(StandardRoot(home), home)
	if l.Cache != "/Users/someone/Library/Caches/com.alexecollins.agents" || l.Logs != "/Users/someone/Library/Logs/Agents" {
		t.Fatalf("the ordinary root: %+v", l)
	}
	other := "/Users/someone/elsewhere/Second"
	l = macFolders(other, home)
	own := "roots/Second-" + PathHash(other)
	if l.Cache != "/Users/someone/Library/Caches/com.alexecollins.agents/"+own || l.Logs != "/Users/someone/Library/Logs/Agents/"+own {
		t.Fatalf("another root: %+v", l)
	}
	l = macFolders("/tmp/run-x/host", home)
	if l.Cache != "/tmp/run-x/machine/cache" || l.Logs != "/tmp/run-x/machine/logs" {
		t.Fatalf("a temporary root: %+v", l)
	}
}
