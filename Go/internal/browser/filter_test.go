package browser

import (
	"bytes"
	"errors"
	"testing"
)

// The filter (#3534): what a browser tool sends back, with every filled value out.

func TestTheFilterHidesNothingAtFirst(t *testing.T) {
	var f Filter
	if f.Hides() || f.Text("4111 1111 1111 1111") != "4111 1111 1111 1111" {
		t.Fatal("hid something")
	}
	if img, err := f.Image([]byte("png"), "image/png"); err != nil || string(img) != "png" {
		t.Fatal(string(img), err)
	}
}

func TestTheFilterTakesOutEachFormOfAValue(t *testing.T) {
	var f Filter
	f.Hide("CARD", "4111111111111111")
	f.Hide("PASSWORD", `p@ss "word"/1`)
	f.Hide("PIN", "123") // too short to hide
	for in, want := range map[string]string{
		"number: 4111111111111111.":                 "number: <secret CARD ending 1111>.",
		"number: 4111 1111 1111 1111":               "number: <secret CARD ending 1111>",
		"number: 4111-1111-1111-1111":               "number: <secret CARD ending 1111>",
		`{"password":"p@ss \"word\"/1"}`:            `{"password":"<secret PASSWORD>"}`,
		"?password=p%40ss+%22word%22%2F1&x=1":       "?password=<secret PASSWORD>&x=1",
		`value: p@ss "word"/1 and 4111111111111111`: "value: <secret PASSWORD> and <secret CARD ending 1111>",
		"pin 123, ending 1111":                      "pin 123, ending 1111",
	} {
		if got := f.Text(in); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
	if !f.Hides() {
		t.Fatal("hides nothing")
	}
	f.Forget()
	if f.Hides() || f.Text("4111111111111111") != "4111111111111111" {
		t.Fatal("still hides after Forget")
	}
}

// #3531: a card's CVC is hidden as a whole number only, so prices and longer numbers with
// its digits stay.
func TestTheFilterHidesACodeAsAWholeNumber(t *testing.T) {
	var f Filter
	f.HideCode("CARD.cvc", "abc") // not a number
	if f.Hides() {
		t.Fatal("hid a code that is not a number")
	}
	f.Hide("CARD.number", "4111111111111123")
	f.HideCode("CARD.cvc", "123")
	for in, want := range map[string]string{
		`textbox "CVC": 123`:            `textbox "CVC": <secret CARD.cvc>`,
		"cvc=123&x=1":                   "cvc=<secret CARD.cvc>&x=1",
		"price $1234, ref e123, 0.1230": "price $1234, ref e123, 0.1230",
		"4111111111111123":              "<secret CARD.number ending 1123>",
	} {
		if got := f.Text(in); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
	f.Forget()
	if f.Hides() || f.Text("123") != "123" {
		t.Fatal("still hides after Forget")
	}
}

func TestTheFilterMasksImages(t *testing.T) {
	var f Filter
	f.SetMask(func(data []byte, mime string) ([]byte, error) {
		if mime != "image/png" {
			return nil, errors.New("not a png")
		}
		return bytes.ToUpper(data), nil
	})
	if img, err := f.Image([]byte("png"), "image/png"); err != nil || string(img) != "PNG" {
		t.Fatal(string(img), err)
	}
	if _, err := f.Image([]byte("jpg"), "image/jpeg"); err == nil {
		t.Fatal("no error")
	}
}

func TestTheFilterIsForgottenWithTheBrowser(t *testing.T) {
	m := &Machine{}
	m.Filter.Hide("CARD", "4111111111111111")
	m.running = &process{stop: func() {}, done: make(chan struct{})}
	m.Profile = t.TempDir() + "/profile"
	m.Stop()
	if m.Filter.Hides() {
		t.Fatal("the values outlived the pages")
	}
}
