package main

import "testing"

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
