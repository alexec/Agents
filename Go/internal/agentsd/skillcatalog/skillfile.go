package skillcatalog

import (
	"regexp"
	"strings"
)

// SkillFile is what a SKILL.md says about itself: the name and description in its front
// matter. Enough YAML for those two: a plain or quoted value on the line, or a block
// (>, |, >-, |-) on the indented lines under it.
type SkillFile struct {
	Name, Description string
}

func ParseSkillFile(text string) SkillFile {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return SkillFile{}
	}
	end := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			end = i
			break
		}
	}
	if end < 0 {
		return SkillFile{}
	}
	front := lines[1:end]
	return SkillFile{Name: frontValue("name", front), Description: frontValue("description", front)}
}

func frontValue(key string, lines []string) string {
	at := -1
	for i, l := range lines {
		if strings.HasPrefix(l, key+":") {
			at = i
			break
		}
	}
	if at < 0 {
		return ""
	}
	raw := strings.Trim(lines[at][len(key)+1:], " \t")
	switch raw {
	case ">", "|", ">-", "|-", ">+", "|+":
		var parts []string
		for _, l := range lines[at+1:] {
			if !(strings.HasPrefix(l, " ") || strings.HasPrefix(l, "\t") || l == "") {
				break
			}
			parts = append(parts, strings.Trim(l, " \t"))
		}
		sep := "\n"
		if strings.HasPrefix(raw, ">") {
			sep = " "
		}
		return strings.TrimSpace(strings.Join(parts, sep))
	}
	if len(raw) >= 2 && (raw[0] == '"' || raw[0] == '\'') && raw[len(raw)-1] == raw[0] {
		raw = raw[1 : len(raw)-1]
	}
	return raw
}

var (
	notFolderChars = regexp.MustCompile(`[^a-z0-9._]+`)
	folderEnds     = regexp.MustCompile(`^[.\-]+|[.\-]+$`)
	slugSpaces     = regexp.MustCompile(`[\s_]+`)
	notSlugChars   = regexp.MustCompile(`[^a-z0-9-]`)
	dashes         = regexp.MustCompile(`-+`)
)

// FolderName is the `skills` CLI's sanitizeName: the folder a skill of this name is put in.
func FolderName(name string) string {
	s := notFolderChars.ReplaceAllString(strings.ToLower(name), "-")
	s = folderEnds.ReplaceAllString(s, "")
	if r := []rune(s); len(r) > 255 {
		s = string(r[:255])
	}
	if s == "" {
		return "unnamed-skill"
	}
	return s
}

// Slug is the CLI's toSkillSlug, how it matches a catalogue's skillId to a folder.
func Slug(name string) string {
	s := slugSpaces.ReplaceAllString(strings.ToLower(name), "-")
	s = notSlugChars.ReplaceAllString(s, "")
	s = dashes.ReplaceAllString(s, "-")
	return strings.Trim(s, "-")
}
