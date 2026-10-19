package agentsd

import (
	"context"
	"image"
	"image/color"
	"testing"
)

// The iOS Simulator pane (#842): what `simctl list` says, read; a screen made smaller; and
// nothing but a UDID reaching simctl.
func TestParseSimulators(t *testing.T) {
	out := []byte(`{"devices":{
		"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"udid":"A","name":"iPhone 17","state":"Shutdown"}],
		"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[{"udid":"B","name":"iPad Pro","state":"Shutdown"},{"udid":"C","name":"Agents Walk","state":"Booted"}],
		"com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[{"udid":"D","name":"Watch","state":"Booted"}]}}`)
	sims := parseSimulators(out)
	if len(sims) != 3 {
		t.Fatalf("%+v", sims)
	}
	if sims[0].Udid != "C" || !sims[0].Booted || sims[0].Os != "iOS 27.0" {
		t.Fatalf("booted first: %+v", sims[0])
	}
	if sims[1].Udid != "B" || sims[2].Udid != "A" || sims[2].Os != "iOS 26.0" {
		t.Fatalf("then newest system: %+v", sims)
	}
	if got := parseSimulators([]byte("not json")); len(got) != 0 {
		t.Fatal(got)
	}
}

func TestShrinkAverages(t *testing.T) {
	picture := image.NewRGBA(image.Rect(0, 0, 4, 8))
	for y := range 8 {
		for x := range 4 {
			v := uint8(0)
			if x%2 == 0 {
				v = 200
			}
			picture.Set(x, y, color.RGBA{v, v, v, 255})
		}
	}
	small := shrink(picture, 4)
	if b := small.Bounds(); b.Dx() != 2 || b.Dy() != 4 {
		t.Fatal(b)
	}
	if r, _, _, _ := small.At(0, 0).RGBA(); r>>8 != 100 {
		t.Fatalf("average %d", r>>8)
	}
	if same := shrink(picture, 20); same != picture {
		t.Fatal("a small picture is kept as it is")
	}
}

func TestSimctlTakesOnlyAUDID(t *testing.T) {
	if noSimulators() != "" {
		t.Skip("no simulators here")
	}
	if _, err := simctl(context.Background(), "boot", "--help"); err == nil {
		t.Fatal("a flag reached simctl")
	}
}
