package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/jpeg"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The iOS Simulator pane (#842): the simulators on this Mac, booted and shut down only on
// the person's press, and a booted one's screen as a picture. The pane asks for a picture
// while it is on screen; nothing here runs on its own.

const (
	// simulatorsMax is the most simulators one list carries.
	simulatorsMax = 50
	// simulatorScreenHeight is how tall a screen comes back when the pane does not say.
	simulatorScreenHeight = 1200
	simulatorTimeout      = 20 * time.Second
)

var simulatorUDID = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)

func (d *Daemon) registerSimulators() {
	On(d, wire.CallSimulatorsList, func(ctx context.Context, _ *Client, _ wire.Empty) (wire.SimulatorList, error) {
		return listSimulators(ctx), nil
	})
	On(d, wire.CallSimulatorsBoot, func(ctx context.Context, _ *Client, r wire.SimulatorRequest) (wire.Empty, error) {
		_, err := simctl(ctx, "boot", r.Udid)
		return wire.Empty{}, err
	})
	On(d, wire.CallSimulatorsShutdown, func(ctx context.Context, _ *Client, r wire.SimulatorRequest) (wire.Empty, error) {
		_, err := simctl(ctx, "shutdown", r.Udid)
		return wire.Empty{}, err
	})
	On(d, wire.CallSimulatorsScreen, func(ctx context.Context, _ *Client, r wire.SimulatorScreenRequest) (wire.SimulatorScreen, error) {
		height := simulatorScreenHeight
		if r.MaxHeight != nil && *r.MaxHeight > 0 {
			height = int(min(*r.MaxHeight, int64(simulatorScreenHeight)))
		}
		return simulatorScreen(ctx, r.Udid, height)
	})
}

// noSimulators says why a host lists none: not a Mac, or no Xcode on it.
func noSimulators() string {
	if goruntime.GOOS != "darwin" {
		return "Simulators run on a Mac. This host is not a Mac."
	}
	if _, err := exec.LookPath("xcrun"); err != nil {
		return "Xcode is not on this Mac, so it has no simulators."
	}
	return ""
}

// simctl runs `xcrun simctl verb udid…`, for a UDID only: nothing else reaches the command.
func simctl(ctx context.Context, verb, udid string, args ...string) ([]byte, error) {
	if reason := noSimulators(); reason != "" {
		return nil, &Error{Code: wire.FailureNotSupported, Message: reason}
	}
	if !simulatorUDID.MatchString(udid) {
		return nil, Invalid("not a simulator's UDID: %s", udid)
	}
	ctx, cancel := context.WithTimeout(ctx, simulatorTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "xcrun", append([]string{"simctl", verb, udid}, args...)...).CombinedOutput()
	if err != nil {
		said := strings.TrimSpace(string(out))
		if said == "" {
			said = err.Error()
		}
		return nil, &Error{Code: CodeServer, Message: "simctl " + verb + ": " + said}
	}
	return out, nil
}

func listSimulators(ctx context.Context) wire.SimulatorList {
	list := wire.SimulatorList{Simulators: []wire.Simulator{}}
	if reason := noSimulators(); reason != "" {
		list.Reason = &reason
		return list
	}
	ctx, cancel := context.WithTimeout(ctx, simulatorTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "xcrun", "simctl", "list", "devices", "available", "-j").Output()
	if err != nil {
		reason := "simctl could not list the simulators: " + err.Error()
		list.Reason = &reason
		return list
	}
	list.Simulators = parseSimulators(out)
	return list
}

// parseSimulators reads `simctl list devices -j`: iOS and iPadOS ones, booted first, then
// by system (newest first) and name.
func parseSimulators(out []byte) []wire.Simulator {
	var listed struct {
		Devices map[string][]struct {
			UDID  string `json:"udid"`
			Name  string `json:"name"`
			State string `json:"state"`
		} `json:"devices"`
	}
	sims := []wire.Simulator{}
	if json.Unmarshal(out, &listed) != nil {
		return sims
	}
	for runtimeID, devices := range listed.Devices {
		system := simulatorOS(runtimeID)
		if !strings.HasPrefix(system, "iOS") {
			continue
		}
		for _, d := range devices {
			sims = append(sims, wire.Simulator{Udid: d.UDID, Name: d.Name, Os: system, Booted: d.State == "Booted"})
		}
	}
	sort.SliceStable(sims, func(i, j int) bool {
		a, b := sims[i], sims[j]
		if a.Booted != b.Booted {
			return a.Booted
		}
		if a.Os != b.Os {
			return a.Os > b.Os
		}
		return a.Name < b.Name
	})
	return sims[:min(len(sims), simulatorsMax)]
}

// simulatorOS is "iOS 27.0" for "com.apple.CoreSimulator.SimRuntime.iOS-27-0".
func simulatorOS(runtimeID string) string {
	name := runtimeID[strings.LastIndex(runtimeID, ".")+1:]
	system, version, ok := strings.Cut(name, "-")
	if !ok {
		return name
	}
	return system + " " + strings.ReplaceAll(version, "-", ".")
}

// simulatorScreen is a booted simulator's screen, made smaller to `height` pixels tall.
func simulatorScreen(ctx context.Context, udid string, height int) (wire.SimulatorScreen, error) {
	dir, err := os.MkdirTemp("", "agents-simulator-")
	if err != nil {
		return wire.SimulatorScreen{}, err
	}
	defer os.RemoveAll(dir)
	file := filepath.Join(dir, "screen.jpg")
	if _, err := simctl(ctx, "io", udid, "screenshot", "--type=jpeg", file); err != nil {
		return wire.SimulatorScreen{}, err
	}
	shot, err := os.ReadFile(file)
	if err != nil {
		return wire.SimulatorScreen{}, err
	}
	picture, err := jpeg.Decode(bytes.NewReader(shot))
	if err != nil {
		return wire.SimulatorScreen{}, &Error{Code: CodeServer, Message: "the simulator's screen did not read: " + err.Error()}
	}
	smaller := shrink(picture, height)
	var b bytes.Buffer
	if err := jpeg.Encode(&b, smaller, &jpeg.Options{Quality: 75}); err != nil {
		return wire.SimulatorScreen{}, err
	}
	size := smaller.Bounds().Size()
	return wire.SimulatorScreen{Jpeg: b.Bytes(), Width: int64(size.X), Height: int64(size.Y)}, nil
}

// shrink is `picture` at most `height` tall, each pixel the average of the ones it covers.
func shrink(picture image.Image, height int) image.Image {
	bounds := picture.Bounds()
	if bounds.Dy() <= height || height <= 0 {
		return picture
	}
	width := max(1, bounds.Dx()*height/bounds.Dy())
	out := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := range height {
		y0, y1 := bounds.Min.Y+y*bounds.Dy()/height, bounds.Min.Y+(y+1)*bounds.Dy()/height
		for x := range width {
			x0, x1 := bounds.Min.X+x*bounds.Dx()/width, bounds.Min.X+(x+1)*bounds.Dx()/width
			var r, g, bl, n uint32
			for sy := y0; sy < max(y1, y0+1); sy++ {
				for sx := x0; sx < max(x1, x0+1); sx++ {
					pr, pg, pb, _ := picture.At(sx, sy).RGBA()
					r, g, bl, n = r+pr, g+pg, bl+pb, n+1
				}
			}
			i := out.PixOffset(x, y)
			out.Pix[i], out.Pix[i+1], out.Pix[i+2], out.Pix[i+3] = uint8(r/n>>8), uint8(g/n>>8), uint8(bl/n>>8), 0xFF
		}
	}
	return out
}
