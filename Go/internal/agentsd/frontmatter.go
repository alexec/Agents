package agentsd

import (
	"strings"
	"unicode"
)

// FrontMatterEdit: one key of a file's front matter changed and nothing else, so a diff
// of the file is the change that was asked for. Line by line, column zero only, the
// author's spacing and comments kept; what it cannot change surely it refuses.

type frontMatterRefusal struct{ why string }

func (r *frontMatterRefusal) Error() string { return r.why }

func refuse(why string) error { return &frontMatterRefusal{why} }

func splitSource(source string) ([]string, string, int, error) {
	nl := "\n"
	if strings.Contains(source, "\r\n") {
		nl = "\r\n"
	}
	lines := strings.Split(source, nl)
	if strings.TrimSpace(lines[0]) != "---" {
		return nil, nl, 0, refuse("This file does not start with a metadata block, and one cannot be invented for it")
	}
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			return lines, nl, i, nil
		}
	}
	return nil, nl, 0, refuse("The metadata block is never closed")
}

func isKeyLine(line, key string) bool {
	return strings.HasPrefix(line, key) && len(line) > len(key) && line[len(key)] == ':'
}

func isContinuation(line string) bool {
	if strings.HasPrefix(line, "-") {
		return true
	}
	if line == "" {
		return false
	}
	return unicode.IsSpace(rune(line[0])) && strings.TrimSpace(line) != ""
}

// splitKeyLine is the spacing after the colon, the value, and what follows it.
func splitKeyLine(line, key string) (spacing, value, trailing string) {
	rest := line[len(key)+1:]
	i := 0
	for i < len(rest) && (rest[i] == ' ' || rest[i] == '\t') {
		i++
	}
	spacing, after := rest[:i], rest[i:]
	var quote rune
	comment := -1
	var previous rune
	for j, c := range after {
		if quote != 0 {
			if c == quote {
				quote = 0
			}
		} else if c == '"' || c == '\'' {
			quote = c
		} else if c == '#' && (previous == 0 || unicode.IsSpace(previous)) {
			comment = j
			break
		}
		previous = c
	}
	part, rem := after, ""
	if comment >= 0 {
		part, rem = after[:comment], after[comment:]
	}
	value = strings.TrimRight(part, " \t")
	return spacing, value, part[len(value):] + rem
}

func quotedYAML(v string) string {
	needs := v == ""
	if !needs {
		first, last := rune(v[0]), rune(v[len(v)-1])
		needs = unicode.IsSpace(first) || unicode.IsSpace(last) || strings.ContainsRune("-?:,[]{}#&*!|>'\"%@`", first) ||
			strings.Contains(v, ": ") || strings.Contains(v, " #") || strings.ContainsAny(v, "\n\r")
	}
	if !needs {
		return v
	}
	return doubleQuoted(v)
}

func flowQuoted(v string) string {
	q := quotedYAML(v)
	if q != v || !strings.ContainsAny(v, ",[]{}") {
		return q
	}
	return doubleQuoted(v)
}

func doubleQuoted(v string) string {
	return "\"" + strings.ReplaceAll(strings.ReplaceAll(v, "\\", "\\\\"), "\"", "\\\"") + "\""
}

func insertLines(lines []string, at int, add ...string) []string {
	out := append([]string{}, lines[:at]...)
	out = append(out, add...)
	return append(out, lines[at:]...)
}

func removeLine(lines []string, at int) []string {
	return append(append([]string{}, lines[:at]...), lines[at+1:]...)
}

// setFrontMatter sets a key to a scalar, or with nil removes it; a new key goes just
// before the closing ---.
func setFrontMatter(key string, value *string, source string) (string, error) {
	lines, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	var matches []int
	for i := 1; i < closing; i++ {
		if isKeyLine(lines[i], key) {
			matches = append(matches, i)
		}
	}
	if len(matches) > 1 {
		return "", refuse("`" + key + ":` appears more than once in the metadata — which one is meant is not something to pick between silently")
	}
	if len(matches) == 0 {
		if value == nil {
			return source, nil
		}
		return strings.Join(insertLines(lines, closing, key+": "+quotedYAML(*value)), nl), nil
	}
	i := matches[0]
	spacing, v, trailing := splitKeyLine(lines[i], key)
	if v == "" && i+1 < closing && isContinuation(lines[i+1]) {
		return "", refuse("`" + key + ":` has a list or a block under it, which this cannot change")
	}
	if strings.HasPrefix(v, "[") || strings.HasPrefix(v, "{") {
		return "", refuse("`" + key + ":` is a list, which this cannot change")
	}
	if value == nil {
		return strings.Join(removeLine(lines, i), nl), nil
	}
	lines[i] = key + ":" + spacing + quotedYAML(*value) + trailing
	return strings.Join(lines, nl), nil
}

// setFrontMatterUnder sets a key in a block, like options:, making the block when it is
// not there and taking it away with its last key unless a comment is left in it.
func setFrontMatterUnder(key, block string, value *string, source string) (string, error) {
	lines, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	var heads []int
	for i := 1; i < closing; i++ {
		if isKeyLine(lines[i], block) {
			heads = append(heads, i)
		}
	}
	if len(heads) > 1 {
		return "", refuse("`" + block + ":` appears more than once in the metadata — which one is meant is not something to pick between silently")
	}
	if len(heads) == 0 {
		if value == nil {
			return source, nil
		}
		return strings.Join(insertLines(lines, closing, block+":", "  "+key+": "+quotedYAML(*value)), nl), nil
	}
	head := heads[0]
	if _, v, _ := splitKeyLine(lines[head], block); v != "" {
		return "", refuse("`" + block + ":` is written on one line, which this cannot change")
	}
	end := head + 1
	for end < closing && (isContinuation(lines[end]) || strings.TrimSpace(lines[end]) == "") {
		end++
	}
	indent := -1
	for i := head + 1; i < end; i++ {
		t := strings.TrimSpace(lines[i])
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		n := len(lines[i]) - len(strings.TrimLeft(lines[i], " "))
		if indent < 0 || n < indent {
			indent = n
		}
	}
	if indent < 0 {
		indent = 2
	}
	if indent == 0 {
		return "", refuse("`" + block + ":` has a list under it, which this cannot change")
	}
	pad := strings.Repeat(" ", indent)
	var matches []int
	for i := head + 1; i < end; i++ {
		if strings.HasPrefix(lines[i], pad) && isKeyLine(lines[i][indent:], key) {
			matches = append(matches, i)
		}
	}
	if len(matches) > 1 {
		return "", refuse("`" + key + ":` appears more than once under `" + block + ":` — which one is meant is not something to pick between silently")
	}
	if len(matches) == 0 {
		if value == nil {
			return source, nil
		}
		last := head
		for i := head + 1; i < end; i++ {
			if strings.TrimSpace(lines[i]) != "" {
				last = i
			}
		}
		return strings.Join(insertLines(lines, last+1, pad+key+": "+quotedYAML(*value)), nl), nil
	}
	i := matches[0]
	spacing, v, trailing := splitKeyLine(lines[i][indent:], key)
	if v == "" && i+1 < end && len(lines[i+1])-len(strings.TrimLeft(lines[i+1], " ")) > indent {
		return "", refuse("`" + key + ":` under `" + block + ":` has a block under it, which this cannot change")
	}
	if strings.HasPrefix(v, "[") || strings.HasPrefix(v, "{") {
		return "", refuse("`" + key + ":` under `" + block + ":` is a list, which this cannot change")
	}
	if value == nil {
		lines = removeLine(lines, i)
		empty := true
		for j := head + 1; j < end-1; j++ {
			empty = empty && strings.TrimSpace(lines[j]) == ""
		}
		if empty {
			lines = removeLine(lines, head)
		}
		return strings.Join(lines, nl), nil
	}
	lines[i] = pad + key + ":" + spacing + quotedYAML(*value) + trailing
	return strings.Join(lines, nl), nil
}

// setFrontMatterList sets a key to a list: written in flow form when new or when it is
// one already, a block list kept as a block, an item left where it was keeping its line.
func setFrontMatterList(key string, values []string, source string) (string, error) {
	lines, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	var matches []int
	for i := 1; i < closing; i++ {
		if isKeyLine(lines[i], key) {
			matches = append(matches, i)
		}
	}
	if len(matches) > 1 {
		return "", refuse("`" + key + ":` appears more than once in the metadata — which one is meant is not something to pick between silently")
	}
	var each []string
	for _, v := range values {
		each = append(each, flowQuoted(v))
	}
	flow := "[" + strings.Join(each, ", ") + "]"
	if len(matches) == 0 {
		if len(values) == 0 {
			return source, nil
		}
		return strings.Join(insertLines(lines, closing, key+": "+flow), nl), nil
	}
	i := matches[0]
	spacing, v, trailing := splitKeyLine(lines[i], key)
	if strings.HasPrefix(v, "[") {
		if !strings.HasSuffix(v, "]") {
			return "", refuse("`" + key + ":` is a list over several lines, which this cannot change")
		}
		if len(values) == 0 {
			return strings.Join(removeLine(lines, i), nl), nil
		}
		lines[i] = key + ":" + spacing + flow + trailing
		return strings.Join(lines, nl), nil
	}
	if v != "" {
		return "", refuse("`" + key + ":` is not written as a list, which this cannot change")
	}
	end := i + 1
	for end < closing && (isContinuation(lines[end]) || strings.TrimSpace(lines[end]) == "") {
		end++
	}
	var items []int
	pad := ""
	havePad := false
	for j := i + 1; j < end; j++ {
		t := strings.TrimSpace(lines[j])
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		indent := lines[j][:len(lines[j])-len(strings.TrimLeft(lines[j], " "))]
		if !strings.HasPrefix(t, "-") || havePad && indent != pad {
			return "", refuse("`" + key + ":` has a block under it that is not a plain list, which this cannot change")
		}
		pad, havePad = indent, true
		items = append(items, j)
	}
	var written []string
	for p, v := range values {
		if p < len(items) && havePad {
			if _, was, _ := splitKeyLine(lines[items[p]][len(pad):], "-"); was == quotedYAML(v) {
				written = append(written, lines[items[p]])
				continue
			}
		}
		lead := "  "
		if havePad {
			lead = pad
		}
		written = append(written, lead+"- "+quotedYAML(v))
	}
	at := i + 1
	if len(items) > 0 {
		at = items[0]
	}
	for k := len(items) - 1; k >= 0; k-- {
		lines = removeLine(lines, items[k])
	}
	if len(values) == 0 {
		lines = removeLine(lines, i)
	} else {
		lines = insertLines(lines, at, written...)
	}
	return strings.Join(lines, nl), nil
}
