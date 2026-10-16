package providers

import (
	"encoding/base64"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Verdict is DraftSafety.Verdict: run a draft's check without asking, or ask, with why.
// Ask is "" for run.
type Verdict struct{ Ask string }

// Run is the verdict to run without asking.
var Run = Verdict{}

func ask(format string, args ...any) Verdict { return Verdict{fmt.Sprintf(format, args...)} }

// allowed is DraftSafety.allowed: a list's name must have one of these words.
var allowed = map[string]bool{"list": true, "ls": true, "get": true, "describe": true, "status": true, "show": true}

// blocked is DraftSafety.blocked: and none of these.
var blocked = map[string]bool{}

func init() {
	for _, w := range []string{"create", "delete", "destroy", "remove", "rm", "rmi", "power", "start", "stop", "restart",
		"reboot", "resize", "update", "set", "terminate", "kill", "shutdown", "halt", "reset", "rebuild", "restore",
		"purge", "prune", "drop", "wipe", "suspend", "down"} {
		blocked[w] = true
	}
}

// safetyWords is DraftSafety.words: the words of a tool's name or a command, split on
// anything not a letter or digit, and at a lower-case letter followed by a capital
// (dropletList), lower-cased.
func safetyWords(text string) []string {
	var words []string
	var current strings.Builder
	var last rune
	hasLast := false
	for _, c := range text {
		if unicode.IsLetter(c) || unicode.IsNumber(c) {
			if hasLast && unicode.IsLower(last) && unicode.IsUpper(c) && current.Len() > 0 {
				words = append(words, current.String())
				current.Reset()
			}
			current.WriteRune(c)
		} else if current.Len() > 0 {
			words = append(words, current.String())
			current.Reset()
		}
		last, hasLast = c, true
	}
	if current.Len() > 0 {
		words = append(words, current.String())
	}
	for i := range words {
		words[i] = strings.ToLower(words[i])
	}
	return words
}

// notAList is DraftSafety.notAList: why the words are not plainly a list; "" when they are.
func notAList(words []string) string {
	for _, w := range words {
		if blocked[w] {
			return "it has the word “" + w + "”"
		}
	}
	for _, w := range words {
		if allowed[w] {
			return ""
		}
	}
	return "its name has none of the words list, ls, get, describe, status or show"
}

// ListTool is DraftSafety.listTool: whether a tool map's list may be called alone. tools
// is the server's tools/list, for the list tool's annotations.
func ListTool(draft any, tools []any) Verdict {
	name, ok := str(get(get(draft, "list"), "tool"))
	if !ok {
		return Run
	}
	for _, key := range []string{"start", "stop", "create", "delete", "options"} {
		if other, ok := str(get(get(draft, key), "tool")); ok && other == name {
			return ask("%s is the map’s %s as well", name, key)
		}
	}
	var annotations any
	for _, t := range tools {
		if strOr(get(t, "name")) == name {
			annotations = get(t, "annotations")
			break
		}
	}
	if b, ok := boolean(get(annotations, "destructiveHint")); ok && b {
		return ask("the server says %s is destructive", name)
	}
	if b, ok := boolean(get(annotations, "readOnlyHint")); ok && !b {
		return ask("the server says %s changes something", name)
	}
	if reason := notAList(safetyWords(name)); reason != "" {
		return Verdict{reason}
	}
	if arguments := get(get(draft, "list"), "arguments"); has(get(draft, "list"), "arguments") {
		if reason := carriesOut(compact(arguments)); reason != "" {
			return ask("its arguments hold %s", reason)
		}
	}
	return Run
}

// CommandsVerdict is DraftSafety.commands: whether a command-provider config's check may
// run alone. What it runs is its list, or each workspace's status. A preset runs only its
// own fixed commands.
func CommandsVerdict(config any, cli string) Verdict {
	if _, ok := str(get(config, "preset")); ok {
		return Run
	}
	var lines []string
	if list, ok := str(get(config, "list")); ok {
		lines = []string{list}
	} else {
		ws, _ := arr(get(config, "workspaces"))
		for _, w := range ws {
			if status, ok := str(get(w, "status")); ok {
				lines = append(lines, status)
			}
		}
	}
	for _, line := range lines {
		if v := Command(line, cli); v != Run {
			return v
		}
	}
	return Run
}

// Command is DraftSafety.command: one command a check would run.
func Command(line, cli string) Verdict {
	trimmed := trimSpaces(line)
	first := ""
	for _, w := range strings.Split(trimmed, " ") {
		if w != "" {
			first = w
			break
		}
	}
	if cli == "" || first != cli {
		return ask("`%s` doesn’t start with %s", trimmed, cli)
	}
	for _, bad := range []string{";", "&", "|", ">", "<", "`", "$", "\n", "\r"} {
		if strings.Contains(trimmed, bad) {
			if bad == "\n" || bad == "\r" {
				return ask("`%s` has a new line", trimmed)
			}
			return ask("`%s` has “%s”", trimmed, bad)
		}
	}
	if reason := carriesOut(trimmed); reason != "" {
		return ask("`%s` holds %s", trimmed, reason)
	}
	if reason := notAList(safetyWords(trimmed[len(first):])); reason != "" {
		return ask("`%s`: %s", trimmed, reason)
	}
	return Run
}

var plainWord = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

// HelpWords is DraftSafety.helpWords: why read_help's words are refused (FR-014); "" when
// they may run. seen is every help the CLI has printed for this draft.
func HelpWords(given []string, seen string) string {
	if len(given) > 3 {
		return "At most three words."
	}
	printed := map[string]bool{}
	for _, w := range safetyWords(seen) {
		printed[w] = true
	}
	for _, word := range given {
		if strings.HasPrefix(word, "-") {
			return "“" + word + "” is a flag: give subcommands only."
		}
		if !plainWord.MatchString(word) {
			return "“" + word + "” isn’t a plain word."
		}
		lower := strings.ToLower(word)
		if blocked[lower] && lower != "start" && lower != "stop" {
			return "“" + word + "” may change something, so its help isn’t run."
		}
		if !printed[lower] && !strings.Contains(seen, word) {
			return "“" + word + "” isn’t a word the CLI’s help printed."
		}
	}
	return ""
}

// carriesOut is DraftSafety.carriesOut: $, ${…} or an address, which could carry a secret
// out of the machine.
func carriesOut(text string) string {
	if strings.Contains(text, "://") {
		return "an address"
	}
	if strings.Contains(text, "$") {
		return "“$”"
	}
	return ""
}

// Redaction is DraftRedaction (#858, research R4, FR-022): a draft's secrets, taken out of
// every text bound for its writing agent, its steps and the log; each value becomes
// ${NAME}. A value of 6 characters or more is replaced wherever it is; a shorter one only
// as a whole word. Each is also replaced in its URL-encoded and base64 forms.
type Redaction struct{ forms []redactionForm }

type redactionForm struct {
	text      string
	name      string
	wholeWord bool
}

// NewRedaction is DraftRedaction.init.
func NewRedaction(secrets map[string]string) Redaction {
	var forms []redactionForm
	names := make([]string, 0, len(secrets))
	for name := range secrets {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		value := secrets[name]
		if value == "" {
			continue
		}
		short := utf8.RuneCountInString(value) < 6
		seen := map[string]bool{}
		for _, text := range []string{value, percentEncoded(value), base64.StdEncoding.EncodeToString([]byte(value))} {
			if !seen[text] {
				seen[text] = true
				forms = append(forms, redactionForm{text, name, short})
			}
		}
	}
	// The longest first, so a value that holds another is replaced whole.
	sort.SliceStable(forms, func(i, j int) bool {
		return utf8.RuneCountInString(forms[i].text) > utf8.RuneCountInString(forms[j].text)
	})
	return Redaction{forms}
}

// percentEncoded is addingPercentEncoding(withAllowedCharacters:) with letters, digits and
// -._~ left as they are.
func percentEncoded(value string) string {
	var out strings.Builder
	for _, r := range value {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || strings.ContainsRune("-._~", r) {
			out.WriteRune(r)
			continue
		}
		for _, b := range []byte(string(r)) {
			fmt.Fprintf(&out, "%%%02X", b)
		}
	}
	return out.String()
}

// IsEmpty says there is nothing to take out.
func (r Redaction) IsEmpty() bool { return len(r.forms) == 0 }

// Text is the redaction of text.
func (r Redaction) Text(text string) string {
	for _, f := range r.forms {
		if !strings.Contains(text, f.text) {
			continue
		}
		if !f.wholeWord {
			text = strings.ReplaceAll(text, f.text, "${"+f.name+"}")
			continue
		}
		text = replaceWholeWord(text, f.text, "${"+f.name+"}")
	}
	return text
}

func wordByte(b byte) bool {
	return b == '_' || b >= '0' && b <= '9' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z'
}

// replaceWholeWord replaces find where no letter, digit or _ of A-Z touches it, left to
// right, as the regular expression (?<![A-Za-z0-9_])find(?![A-Za-z0-9_]) does.
func replaceWholeWord(text, find, with string) string {
	var out strings.Builder
	i := 0
	for i <= len(text) {
		at := strings.Index(text[i:], find)
		if at < 0 {
			break
		}
		at += i
		end := at + len(find)
		if (at == 0 || !wordByte(text[at-1])) && (end == len(text) || !wordByte(text[end])) {
			out.WriteString(text[i:at])
			out.WriteString(with)
			i = end
			continue
		}
		out.WriteString(text[i : at+1])
		i = at + 1
	}
	out.WriteString(text[min(i, len(text)):])
	return out.String()
}

// Value is the redaction of every string in a JSON value, keys and values.
func (r Redaction) Value(v any) any {
	switch t := v.(type) {
	case string:
		return r.Text(t)
	case []any:
		out := make([]any, len(t))
		for i, x := range t {
			out[i] = r.Value(x)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, x := range t {
			key := r.Text(k)
			if _, taken := out[key]; !taken {
				out[key] = r.Value(x)
			}
		}
		return out
	}
	return v
}
