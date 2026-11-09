package agentsd

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"regexp"
	"strconv"
	"strings"

)

// generate_secret (#4000): agentsd makes a strong password, saves it in Settings ▸ Secrets
// and types it into a field on the page as fill_secret does (#3530). The agent is told
// "<NAME> made and filled", never the value, so a new account's password never reaches
// the transcript or the model.
//
// The rules are the passwordrules format (whatwg/html#3518), as the agent gives them or as
// the field carries them. No Go library parses it (Apple's parser, in Password Manager
// Resources, is JavaScript), so passwordRules below is our own, of the generator's part
// of the format only.

const generateSecretName = "generate_secret"

// generateSecretTool is generate_secret as tools/list sends it, with the browser tools.
var generateSecretTool = json.RawMessage(`{"name":"generate_secret","title":"Make a password and fill it into a page field",` +
	`"description":"Make a strong password for a new account or a password change, save it as one of the person's secrets (Settings ▸ Secrets), and type it into a field on the browser's page, without you seeing it. ` +
	`You get \"<NAME> made and filled\", never the value; the page is then closed to it as after fill_secret. For a confirm-password field, call fill_secret with the same name. ` +
	`With no rules, the field's own passwordrules, minlength, maxlength and pattern are used, or 24 characters of letters, digits and symbols. ` +
	`When the site says its rules only in words, write them as rules. Never make a password yourself.",` +
	`"inputSchema":{"type":"object","properties":{` +
	`"secret":{"type":"string","description":"The name to save it as in Settings ▸ Secrets, e.g. GITLAB_PASSWORD. Refused when it exists, unless replace is true."},` +
	`"target":{"type":"string","description":"Exact target element reference from the page snapshot, or a unique element selector"},` +
	`"element":{"type":"string","description":"The field, in words, for the person: e.g. \"Password field\"."},` +
	`"rules":{"type":"string","description":"The site's password rules in the passwordrules format, e.g. \"minlength: 12; maxlength: 16; required: lower, upper; required: digit; allowed: [-_]\", or a preset: alphanumeric, pin."},` +
	`"length":{"type":"integer","description":"For the pin preset only: how many digits (default 6)."},` +
	`"submit":{"type":"boolean","description":"Whether to press Enter after the fill."},` +
	`"replace":{"type":"boolean","description":"True on a change-password page, to overwrite a secret that exists. The old value is kept as <NAME>_PREVIOUS."}},` +
	`"required":["secret","target"],"additionalProperties":false},` +
	`"annotations":{"title":"Make a password","readOnlyHint":false,"destructiveHint":true,"openWorldHint":true}}`)

// The character classes of the passwordrules format. special leaves out the space, which
// the format allows, as sites often trim it.
const (
	rulesLower   = "abcdefghijklmnopqrstuvwxyz"
	rulesUpper   = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	rulesDigit   = "0123456789"
	rulesSpecial = "-~!@#$%^&*_+=`|(){}[:;\"'<>,.?]/"
)

// The longest password made, and the length when the rules give none.
const (
	generateLongest = 128
	generateLength  = 24
)

// passwordRules is what a password must be.
type passwordRules struct {
	required       []string // each set gives at least one character
	allowed        string   // the other characters it may have
	minLength      int
	maxLength      int
	maxConsecutive int
	pattern        *regexp.Regexp // the field's own pattern, whole value
}

// rulesClass is a class name or a [custom] set, as characters.
func rulesClass(s string) (string, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]") && len(s) > 2 {
		return s[1 : len(s)-1], nil
	}
	switch strings.ToLower(s) {
	case "lower":
		return rulesLower, nil
	case "upper":
		return rulesUpper, nil
	case "digit":
		return rulesDigit, nil
	case "special":
		return rulesSpecial, nil
	case "ascii-printable", "unicode":
		return rulesLower + rulesUpper + rulesDigit + rulesSpecial, nil
	}
	return "", errors.New("`" + s + "` is not a class: use lower, upper, digit, special, ascii-printable or [characters]")
}

// parsePasswordRules reads rules in the passwordrules format, or a preset.
func parsePasswordRules(text string, pinLength int) (passwordRules, error) {
	switch strings.TrimSpace(strings.ToLower(text)) {
	case "":
		return passwordRules{required: []string{rulesLower, rulesUpper, rulesDigit, rulesSpecial}}, nil
	case "alphanumeric":
		return passwordRules{required: []string{rulesLower, rulesUpper, rulesDigit}}, nil
	case "pin":
		if pinLength == 0 {
			pinLength = 6
		}
		return passwordRules{required: []string{rulesDigit}, minLength: pinLength, maxLength: pinLength}, nil
	}
	var r passwordRules
	for _, rule := range strings.Split(text, ";") {
		if strings.TrimSpace(rule) == "" {
			continue
		}
		key, value, ok := strings.Cut(rule, ":")
		if !ok {
			return r, errors.New("`" + strings.TrimSpace(rule) + "` is not `name: value`")
		}
		key, value = strings.ToLower(strings.TrimSpace(key)), strings.TrimSpace(value)
		switch key {
		case "required", "allowed":
			set := ""
			for _, c := range splitClasses(value) {
				chars, err := rulesClass(c)
				if err != nil {
					return r, err
				}
				set += chars
			}
			if key == "required" {
				r.required = append(r.required, set)
			} else {
				r.allowed += set
			}
		case "minlength", "maxlength", "max-consecutive":
			n, err := strconv.Atoi(value)
			if err != nil || n < 1 {
				return r, errors.New(key + " is a whole number above 0")
			}
			switch key {
			case "minlength":
				r.minLength = max(r.minLength, n)
			case "maxlength":
				r.maxLength = minSet(r.maxLength, n)
			default:
				r.maxConsecutive = minSet(r.maxConsecutive, n)
			}
		default:
			return r, errors.New("`" + key + "` is not a rule: use required, allowed, minlength, maxlength or max-consecutive")
		}
	}
	if len(r.required) == 0 && r.allowed == "" {
		r.allowed = rulesLower + rulesUpper + rulesDigit + rulesSpecial
	}
	return r, nil
}

// splitClasses splits "lower, [-,_], digit" at the commas outside brackets.
func splitClasses(s string) []string {
	var out []string
	depth, start := 0, 0
	for i, c := range s {
		switch {
		case c == '[':
			depth++
		case c == ']' && depth > 0:
			depth--
		case c == ',' && depth == 0:
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

// minSet is the smaller of a and b, where 0 is not set.
func minSet(a, b int) int {
	if a == 0 || b < a {
		return b
	}
	return a
}

// length is the longest length the rules allow, or the reason none.
func (r passwordRules) length() (int, error) {
	n := r.maxLength
	if n == 0 {
		n = max(generateLength, r.minLength)
	}
	n = min(n, generateLongest)
	switch {
	case r.minLength > n:
		return 0, errors.New("minlength is more than maxlength (or " + strconv.Itoa(generateLongest) + ")")
	case len(r.required) > n:
		return 0, errors.New("more classes are required than the password has characters")
	}
	return n, nil
}

// generatePassword makes a password the rules allow, with crypto/rand.
func generatePassword(r passwordRules) (string, error) {
	n, err := r.length()
	if err != nil {
		return "", err
	}
	all := r.allowed
	for _, set := range r.required {
		all += set
	}
	// A few tries meet max-consecutive and the field's pattern; a rule no try meets is
	// most likely one no password can.
	for range 200 {
		b := make([]byte, n)
		for i := range b {
			b[i] = pick(all)
		}
		// One of each required class, at places of their own.
		places := shuffled(n)
		for i, set := range r.required {
			b[places[i]] = pick(set)
		}
		p := string(b)
		if r.maxConsecutive > 0 && longestRun(p) > r.maxConsecutive {
			continue
		}
		if r.pattern != nil && !r.pattern.MatchString(p) {
			continue
		}
		return p, nil
	}
	if r.pattern != nil {
		return "", errors.New("no password of these rules matches the field's pattern; write the site's rules as `rules`")
	}
	return "", errors.New("no password meets max-consecutive with these characters")
}

func pick(set string) byte {
	i, err := rand.Int(rand.Reader, big.NewInt(int64(len(set))))
	if err != nil {
		panic(err) // crypto/rand does not fail on the platforms agentsd runs on
	}
	return set[i.Int64()]
}

// shuffled is 0..n-1 in a random order (Fisher–Yates).
func shuffled(n int) []int {
	out := make([]int, n)
	for i := range out {
		out[i] = i
	}
	for i := n - 1; i > 0; i-- {
		j, _ := rand.Int(rand.Reader, big.NewInt(int64(i+1)))
		out[i], out[j.Int64()] = out[j.Int64()], out[i]
	}
	return out
}

func longestRun(s string) int {
	best, run := 0, 0
	for i := range s {
		if i > 0 && s[i] == s[i-1] {
			run++
		} else {
			run = 1
		}
		best = max(best, run)
	}
	return best
}

// fieldRules reads the field's own rules attributes.
const fieldRules = `(el) => JSON.stringify({rules: el.getAttribute('passwordrules') || '', min: el.minLength || 0, max: el.maxLength || 0, pattern: el.getAttribute('pattern') || ''})`

// generateSecretCheck is the refusal for a call that cannot make a password, before the
// lease: a bad name or target, a name that exists, or rules that cannot be read.
func (d *Daemon) generateSecretCheck(args map[string]json.RawMessage) string {
	name := strings.TrimSpace(argString(args, "secret"))
	if !secretAskName.MatchString(name) {
		return "Nothing was made: `secret` is the name to save it as, letters, digits and underscores, e.g. GITLAB_PASSWORD."
	}
	if strings.TrimSpace(argString(args, "target")) == "" {
		return "Nothing was made: `target` is the field, a reference from browser_snapshot or a selector."
	}
	home := d.personalHome()
	if home == "" {
		return "Nothing was made: this machine has no personal home to keep secrets in."
	}
	if string(args["replace"]) != "true" && secretIsSet(home, name) {
		return "Nothing was made: " + name + " exists. Fill it with fill_secret, or set replace to true on a change-password page."
	}
	if _, err := parsePasswordRules(argString(args, "rules"), pinLength(args)); err != nil {
		return "Nothing was made: " + err.Error() + "."
	}
	return ""
}

// pinLength is the pin preset's length, or 0 for its default.
func pinLength(args map[string]json.RawMessage) int {
	n, _ := argInt(args, "length")
	return max(n, 0)
}

// generateSecret makes the password, saves it, and fills it into the field.
func (d *Daemon) generateSecret(ctx context.Context, drive *browserDrive, args map[string]json.RawMessage) ([]any, bool, string) {
	name := strings.TrimSpace(argString(args, "secret"))
	rules, _ := parsePasswordRules(argString(args, "rules"), pinLength(args))
	if strings.TrimSpace(argString(args, "rules")) == "" {
		if r, ok := d.fieldPasswordRules(ctx, drive, args); ok {
			rules = r
		}
	}
	value, err := generatePassword(rules)
	if err != nil {
		return fillWords("Nothing was made: " + err.Error() + ".")
	}
	// An agent's write: Ask before use is on, the old value's too (#4014).
	if string(args["replace"]) == "true" {
		if old, ok, _ := d.localSecret("", name); ok && old != "" {
			if err := d.saveSecret(name+"_PREVIOUS", old, true); err != nil {
				return fillWords("Nothing was made: " + err.Error() + ".")
			}
		}
	}
	if err := d.saveSecret(name, value, true); err != nil {
		return fillWords("Nothing was made: " + err.Error() + ".")
	}
	_, isError, note := d.fillSecret(ctx, drive, secretFill{label: name, value: value, hide: map[string]string{name: value}}, args)
	if isError {
		msg := name + " was made and saved, but not filled: " + strings.TrimPrefix(note, "Nothing was filled: ") + " Fill it with fill_secret."
		return fillWords(msg)
	}
	note = strings.Replace(note, name+" filled", name+" made and filled", 1)
	return []any{map[string]any{"type": "text", "text": note}}, false, note
}

// fieldPasswordRules is the field's own rules, or false when it has none.
func (d *Daemon) fieldPasswordRules(ctx context.Context, drive *browserDrive, args map[string]json.RawMessage) (passwordRules, bool) {
	call := map[string]json.RawMessage{"function": rawString(fieldRules), "target": args["target"]}
	if e, ok := args["element"]; ok {
		call["element"] = e
	}
	res, err := drive.call(ctx, "browser_evaluate", call)
	if err != nil || res.IsError {
		return passwordRules{}, false
	}
	_, after, ok := strings.Cut(resultText(res), "### Result\n")
	if !ok {
		return passwordRules{}, false
	}
	line, _, _ := strings.Cut(after, "\n")
	var raw string
	var attrs struct {
		Rules   string `json:"rules"`
		Min     int    `json:"min"`
		Max     int    `json:"max"`
		Pattern string `json:"pattern"`
	}
	if json.Unmarshal([]byte(line), &raw) != nil || json.Unmarshal([]byte(raw), &attrs) != nil {
		return passwordRules{}, false
	}
	if attrs.Rules == "" && attrs.Min <= 0 && attrs.Max <= 0 && attrs.Pattern == "" {
		return passwordRules{}, false
	}
	r, err := parsePasswordRules(attrs.Rules, 0)
	if err != nil {
		r, _ = parsePasswordRules("", 0)
	}
	if attrs.Min > 0 {
		r.minLength = max(r.minLength, attrs.Min)
	}
	if attrs.Max > 0 {
		r.maxLength = minSet(r.maxLength, attrs.Max)
	}
	if attrs.Pattern != "" {
		// HTML matches the pattern against the whole value; one Go cannot read is left out.
		r.pattern, _ = regexp.Compile("^(?:" + attrs.Pattern + ")$")
	}
	return r, true
}
