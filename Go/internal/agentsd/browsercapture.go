package agentsd

import (
	"context"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
)

// capture_secret (#4028): agentsd reads a value the page shows once (an app password, an
// API token), saves it in Settings ▸ Secrets, and puts it in the filter, as fill_secret
// does (#3530). The agent is told "<NAME> saved (N characters)", never the value, and
// never what the element said when nothing matched.

const captureSecretName = "capture_secret"

// captureSecretTool is capture_secret as tools/list sends it, with the browser tools.
var captureSecretTool = json.RawMessage(`{"name":"capture_secret","title":"Save a value the page shows as a secret",` +
	`"description":"Save a value that the browser's page shows once, such as an app password or an API token, as one of the person's secrets (Settings ▸ Secrets), without you seeing it. ` +
	`Name the element that shows it as browser_click does (target: a reference from browser_snapshot, or a selector); its text, or a field's value, is read. ` +
	`Give pattern to take only the first match, e.g. glpat-[A-Za-z0-9_-]{20,}. You get \"<NAME> saved (N characters)\", never the value; from then on page reads show <secret NAME>. ` +
	`Never read a token with browser_snapshot before you capture it.",` +
	`"inputSchema":{"type":"object","properties":{` +
	`"secret":{"type":"string","description":"The name to save it as in Settings ▸ Secrets, e.g. GITLAB_TOKEN. Refused when it exists, unless replace is true."},` +
	`"target":{"type":"string","description":"Exact target element reference from the page snapshot, or a unique element selector"},` +
	`"element":{"type":"string","description":"The element, in words, for the person: e.g. \"New token\"."},` +
	`"pattern":{"type":"string","description":"A regular expression (Go syntax); the first match is saved. Without it, the whole text, trimmed."},` +
	`"replace":{"type":"boolean","description":"True for a new value of a secret that exists. The old value is kept as <NAME>_PREVIOUS."}},` +
	`"required":["secret","target"],"additionalProperties":false},` +
	`"annotations":{"title":"Save a shown value","readOnlyHint":false,"destructiveHint":true,"openWorldHint":true}}`)

// elementText reads an input's value, or the element's text.
const elementText = `(el) => ('value' in el && typeof el.value === 'string' && el.value !== '') ? el.value : (el.innerText || el.textContent || '')`

// captureSecretCheck is the refusal for a call that cannot save, before the lease: a bad
// name, target or pattern, or a name that exists.
func (d *Daemon) captureSecretCheck(args map[string]json.RawMessage) string {
	name := strings.TrimSpace(argString(args, "secret"))
	if !secretAskName.MatchString(name) {
		return "Nothing was saved: `secret` is the name to save it as, letters, digits and underscores, e.g. GITLAB_TOKEN."
	}
	if strings.TrimSpace(argString(args, "target")) == "" {
		return "Nothing was saved: `target` is the element that shows the value, a reference from browser_snapshot or a selector."
	}
	home := d.personalHome()
	if home == "" {
		return "Nothing was saved: this machine has no personal home to keep secrets in."
	}
	if string(args["replace"]) != "true" && (skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home)).IsSet(name) || isSealedSecret(home, name)) {
		return "Nothing was saved: " + name + " exists. Set replace to true to save a new value."
	}
	if _, err := regexp.Compile(argString(args, "pattern")); err != nil {
		return "Nothing was saved: `pattern` is not a regular expression: " + err.Error() + "."
	}
	return ""
}

// captureSecret reads the element, saves the match, and hides it from page reads.
func (d *Daemon) captureSecret(ctx context.Context, drive *browserDrive, args map[string]json.RawMessage) ([]any, bool, string) {
	name := strings.TrimSpace(argString(args, "secret"))
	call := map[string]json.RawMessage{"function": rawString(elementText), "target": args["target"]}
	if e, ok := args["element"]; ok {
		call["element"] = e
	}
	// The result has the value: none of it goes in the words, not even an error's.
	res, err := drive.call(ctx, "browser_evaluate", call)
	if err != nil || res.IsError {
		return fillWords("Nothing was saved: the element could not be read. Check target with browser_snapshot.")
	}
	var text string
	_, after, ok := strings.Cut(resultText(res), "### Result\n")
	line, _, _ := strings.Cut(after, "\n")
	if !ok || json.Unmarshal([]byte(line), &text) != nil {
		return fillWords("Nothing was saved: the element could not be read. Check target with browser_snapshot.")
	}
	value := strings.TrimSpace(text)
	if p := argString(args, "pattern"); p != "" {
		value = regexp.MustCompile(p).FindString(text)
	}
	if value == "" {
		return fillWords("Nothing was saved: nothing in the element matched.")
	}
	// The filter does not hide a value this short: it would take half the page out.
	if len(value) < 4 {
		return fillWords("Nothing was saved: the match is shorter than four characters, too short to keep out of page reads.")
	}
	d.browser.Filter.Hide(name, value)
	// An agent's write: Ask before use is on, the old value's too (#4014).
	if string(args["replace"]) == "true" {
		if old, ok, _ := d.localSecret("", name); ok && old != "" {
			if err := d.saveSecret(name+"_PREVIOUS", old, true); err != nil {
				return fillWords("Nothing was saved: " + err.Error() + ".")
			}
		}
	}
	if err := d.saveSecret(name, value, true); err != nil {
		return fillWords("Nothing was saved: " + d.browser.Filter.Text(err.Error()) + ".")
	}
	note := name + " saved (" + strconv.Itoa(len([]rune(value))) + " characters)."
	return []any{map[string]any{"type": "text", "text": note}}, false, note
}
