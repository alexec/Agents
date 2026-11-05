package browser

import (
	"encoding/json"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// Filter is what every browser tool's result goes through before an agent gets it (#3534,
// spike #3527): each value filled into this browser comes out of the text as
// <secret NAME>, and each image goes through its mask. The fill (#3530) adds the values;
// it draws each filled field as dots in the page, so images need no mask of their own yet.
type Filter struct {
	mu     sync.Mutex
	hidden map[string]string // value → its secret's name
	codes  map[string]string // a short code (a card's CVC) → its secret's name; hidden as a whole number
	forms  *regexp.Regexp    // every form of every value, longest first; nil for none
	names  map[string]string // each form → its secret's name
	// mask paints over what must not be seen in an image (the boxes of filled fields) and
	// gives the image back; nil lets it through as it is.
	mask func(data []byte, mime string) ([]byte, error)
}

// Hide takes value out of every text after this, as <secret name>. A value of fewer than
// four characters is not hidden: it would take out half the page.
func (f *Filter) Hide(name, value string) {
	if len([]rune(value)) < 4 {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.hidden == nil {
		f.hidden = map[string]string{}
	}
	f.hidden[value] = name
	f.compile()
}

// HideCode takes a short number, such as a card's CVC (#3531), out of every text after this,
// where it stands as a whole number: a code of three digits would take every price and
// date with those digits out, so only the number on its own goes.
func (f *Filter) HideCode(name, code string) {
	if code == "" || strings.Trim(code, "0123456789") != "" {
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.codes == nil {
		f.codes = map[string]string{}
	}
	f.codes[code] = name
	f.compile()
}

// Forget hides nothing any more: the browser's pages, and the values in them, are gone.
func (f *Filter) Forget() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hidden, f.codes, f.forms, f.names = nil, nil, nil, nil
}

// Hides is whether any value is hidden now.
func (f *Filter) Hides() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.hidden) > 0 || len(f.codes) > 0
}

// Text is s with every form of every hidden value replaced.
func (f *Filter) Text(s string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.forms == nil {
		return s
	}
	return f.forms.ReplaceAllStringFunc(s, func(m string) string {
		name := f.names[m]
		if name == "" {
			// A card number written with other spaces or dashes: the forms regexp matched
			// it, so its digits are a hidden value.
			name = f.names[digitsOnly(m)]
		}
		return placeholder(name, m)
	})
}

// Image is data after the mask, or as it is when there is no mask.
func (f *Filter) Image(data []byte, mime string) ([]byte, error) {
	f.mu.Lock()
	mask := f.mask
	f.mu.Unlock()
	if mask == nil {
		return data, nil
	}
	return mask(data, mime)
}

// SetMask sets what paints over an image's hidden parts; nil lets images through.
func (f *Filter) SetMask(mask func(data []byte, mime string) ([]byte, error)) {
	f.mu.Lock()
	f.mask = mask
	f.mu.Unlock()
}

// placeholder is what a hidden value becomes: its secret's name, and for a card number
// its last four digits, as a receipt shows it.
func placeholder(name, match string) string {
	if d := digitsOnly(match); len(d) >= 12 && numberLike(match) {
		return "<secret " + name + " ending " + d[len(d)-4:] + ">"
	}
	return "<secret " + name + ">"
}

// compile makes the forms regexp from hidden. Under mu.
func (f *Filter) compile() {
	f.names = map[string]string{}
	var patterns []string
	for value, name := range f.hidden {
		for _, form := range formsOf(value) {
			f.names[form] = name
			patterns = append(patterns, regexp.QuoteMeta(form))
		}
		// A number (a card, an account) may be shown with spaces or dashes anywhere.
		if d := digitsOnly(value); len(d) >= 8 && numberLike(value) {
			f.names[d] = name
			var b strings.Builder
			for i, r := range d {
				if i > 0 {
					b.WriteString(`[ \-]?`)
				}
				b.WriteRune(r)
			}
			patterns = append(patterns, b.String())
		}
	}
	// Longest first, so a value is not cut in two by a shorter one inside it.
	sort.Slice(patterns, func(i, j int) bool { return len(patterns[i]) > len(patterns[j]) })
	// A code goes last: a value with the code's digits in it is taken out whole first.
	codes := make([]string, 0, len(f.codes))
	for code, name := range f.codes {
		if _, ok := f.names[code]; !ok {
			f.names[code] = name
		}
		codes = append(codes, code)
	}
	sort.Strings(codes)
	for _, code := range codes {
		patterns = append(patterns, `\b`+code+`\b`)
	}
	if len(patterns) == 0 {
		f.forms = nil
		return
	}
	f.forms = regexp.MustCompile(strings.Join(patterns, "|"))
}

// formsOf is how a value can show in a page's text, its network bodies and its addresses:
// as typed, escaped in JSON, and escaped in a URL.
func formsOf(value string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(s string) {
		if s != "" && !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	add(value)
	if b, err := json.Marshal(value); err == nil {
		add(string(b[1 : len(b)-1]))
	}
	add(url.QueryEscape(value))
	add(url.PathEscape(value))
	return out
}

func digitsOnly(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, s)
}

// numberLike is whether s is digits, with only spaces or dashes between them.
func numberLike(s string) bool {
	return strings.Trim(s, "0123456789 -") == ""
}
