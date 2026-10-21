package agentsd

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/jpeg"
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

// A simulator's screen is a YCbCr JPEG of about 3 million pixels, read each second. Its
// planes are read directly: At for each pixel made an allocation for each one (#1650).
func TestShrinkReadsAJPEGsPlanesDirectly(t *testing.T) {
	picture := image.NewYCbCr(image.Rect(0, 0, 1206, 2622), image.YCbCrSubsampleRatio420)
	// Colours a screen shows: no channel is clamped, so YCbCr and RGB averages agree.
	for i := range picture.Y {
		picture.Y[i] = uint8(80 + i%96)
	}
	for i := range picture.Cb {
		picture.Cb[i], picture.Cr[i] = uint8(112+i%32), uint8(120+i%16)
	}
	// One for each pixel is about 3 million. AllocsPerRun counts the whole process, so
	// goroutines other tests leave running add theirs: 1072 and 2083 on CI (#1957). The
	// limit is far under 3 million and far over that noise.
	if allocs := testing.AllocsPerRun(1, func() { shrink(picture, 1200) }); allocs > 100000 {
		t.Fatalf("%v allocations to shrink one screen", allocs)
	}
	// The same averages as a pixel-by-pixel read, within rounding.
	fast, slow := shrink(picture, 600), shrinkAny(picture, 600)
	for _, at := range []image.Point{{0, 0}, {137, 299}, {273, 599}} {
		fr, fg, fb, _ := fast.At(at.X, at.Y).RGBA()
		sr, sg, sb, _ := slow.At(at.X, at.Y).RGBA()
		for _, d := range []int{int(fr>>8) - int(sr>>8), int(fg>>8) - int(sg>>8), int(fb>>8) - int(sb>>8)} {
			if d < -2 || d > 2 {
				t.Fatalf("at %v: %d,%d,%d not %d,%d,%d", at, fr>>8, fg>>8, fb>>8, sr>>8, sg>>8, sb>>8)
			}
		}
	}
}

// shrinkAny is shrink through At alone, as a picture of an unknown kind is read.
func shrinkAny(picture image.Image, height int) image.Image {
	return shrink(struct{ image.Image }{picture}, height)
}

// A screen that did not change is not decoded and made smaller again (#1650).
func TestUnchangedScreenIsNotDecodedAgain(t *testing.T) {
	var shot bytes.Buffer
	if err := jpeg.Encode(&shot, image.NewGray(image.Rect(0, 0, 100, 200)), nil); err != nil {
		t.Fatal(err)
	}
	frames := &frameCache{}
	first, err := frames.screen("A", 100, shot.Bytes())
	if err != nil || first.Height != 100 || first.Width != 50 {
		t.Fatal(first.Width, first.Height, err)
	}
	if again, _ := frames.screen("A", 100, shot.Bytes()); frames.decodes != 1 || !bytes.Equal(again.Jpeg, first.Jpeg) {
		t.Fatalf("decoded %d times", frames.decodes)
	}
	if _, err := frames.screen("A", 50, shot.Bytes()); err != nil || frames.decodes != 2 {
		t.Fatalf("another height is another frame: %d", frames.decodes)
	}
	for i := range simulatorFramesMax * 2 {
		_, _ = frames.screen(string(rune('B'+i)), 100, shot.Bytes())
	}
	if len(frames.frames) > simulatorFramesMax {
		t.Fatalf("%d frames kept", len(frames.frames))
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
