package controlplane

import (
	"context"
	"net/url"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/agentloops-dev/agents/Go/internal/controlplane/records"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A project's boards (#3282, specs/3273-project-unit "Boards"): the Tasks slot holds one or
// more boards, so several teams that work on one repository each have their own: a GitHub
// Projects board, a Jira board, a Linear team, a GitLab group board or an Azure Boards board (a
// team's, #3816), each with a name (the team's). The person gives a board's address; the control plane reads from it which forge
// it is on and which board, and keeps the address in one form, which names the board in
// forge/issues' board. Work's Issues and Features lists narrow to one board on the machines.

const (
	// mostBoards bounds a project's boards.
	mostBoards = 20
	// mostBoardName bounds a board's name.
	mostBoardName = 100
)

var (
	githubBoardPath = regexp.MustCompile(`^/(orgs|users)/([A-Za-z0-9][A-Za-z0-9-]*)/projects/([0-9]+)(/.*)?$`)
	jiraBoardPath   = regexp.MustCompile(`/boards/([0-9]+)(/.*)?$`)
	linearTeamPath  = regexp.MustCompile(`^/([A-Za-z0-9_-]+)/team/([A-Za-z][A-Za-z0-9]*)(/.*)?$`)
	gitlabBoardPath = regexp.MustCompile(`^/groups/([A-Za-z0-9_.][A-Za-z0-9_./-]*)/-/boards/([0-9]+)(/.*)?$`)
	// azureBoardPath is a team's board or backlog on Azure Boards: <org>/<project>/_boards/board/t/<team>
	// or <org>/<project>/_backlogs/backlog/<team>, each maybe with its level after it. On
	// <org>.visualstudio.com the organization is the host's.
	azureBoardPath   = regexp.MustCompile(`^/([^/]+)/([^/]+)/(?:_boards/board/t|_backlogs/backlog)/([^/]+)(/.*)?$`)
	azureVSBoardPath = regexp.MustCompile(`^/([^/]+)/(?:_boards/board/t|_backlogs/backlog)/([^/]+)(/.*)?$`)
)

// boardFromAddress is the board an address names, in the one form the project keeps; ok is
// false for an address that names no board this knows.
func boardFromAddress(address string) (board wire.ProjectBoard, ok bool) {
	u, err := url.Parse(strings.TrimSpace(address))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || u.User != nil {
		return board, false
	}
	host := strings.ToLower(u.Host)
	path := strings.TrimRight(u.EscapedPath(), "/")
	at := func(forge wire.ConnectionProvider, key, site, canonical string) (wire.ProjectBoard, bool) {
		return wire.ProjectBoard{URL: canonical, Forge: &forge, Key: &key, Site: &site}, true
	}
	switch {
	case host == "github.com" || host == "www.github.com":
		if m := githubBoardPath.FindStringSubmatch(path); m != nil {
			return at(wire.ConnectionProviderGithub, m[2]+"/"+m[3], "github.com",
				"https://github.com/"+m[1]+"/"+m[2]+"/projects/"+m[3])
		}
	case host == "linear.app":
		if m := linearTeamPath.FindStringSubmatch(path); m != nil {
			key := strings.ToUpper(m[2])
			return at(wire.ConnectionProviderLinear, key, "linear.app", "https://linear.app/"+m[1]+"/team/"+key)
		}
	case strings.HasSuffix(host, ".visualstudio.com"):
		if m := azureVSBoardPath.FindStringSubmatch(path); m != nil {
			return azureBoard(strings.TrimSuffix(host, ".visualstudio.com"), m[1], m[2], "https://dev.azure.com")
		}
	default:
		// An Azure Boards board: on dev.azure.com, or an Azure DevOps Server's collection.
		if m := azureBoardPath.FindStringSubmatch(path); m != nil {
			site := "https://dev.azure.com"
			if host != "dev.azure.com" {
				site = u.Scheme + "://" + host
			}
			return azureBoard(m[1], m[2], m[3], site)
		}
		if m := gitlabBoardPath.FindStringSubmatch(path); m != nil {
			group := strings.Trim(m[1], "/")
			return at(wire.ConnectionProviderGitlab, group+"#"+m[2], host, u.Scheme+"://"+host+"/groups/"+group+"/-/boards/"+m[2])
		}
		// A Jira board: …/boards/<id> on Jira Cloud and Data Center, or the old RapidBoard page.
		if m := jiraBoardPath.FindStringSubmatch(path); m != nil && (strings.Contains(path, "/jira/") || strings.HasSuffix(host, ".atlassian.net")) {
			return at(wire.ConnectionProviderAtlassian, m[1], host, u.Scheme+"://"+host+strings.TrimSuffix(path, m[2]))
		}
		if strings.HasSuffix(path, "/secure/RapidBoard.jspa") {
			if id := u.Query().Get("rapidView"); id != "" && strings.Trim(id, "0123456789") == "" {
				return at(wire.ConnectionProviderAtlassian, id, host, u.Scheme+"://"+host+path+"?rapidView="+id)
			}
		}
	}
	return board, false
}

// azureBoard is the board of team in org/project on the Azure DevOps at root, from an
// address's escaped names. Its key is org/project/team: a project's and a team's names hold
// no slash. A *.visualstudio.com board is kept as dev.azure.com's, which is the same one.
func azureBoard(org, project, team, root string) (wire.ProjectBoard, bool) {
	names := []string{org, project, team}
	for i, n := range names {
		plain, err := url.PathUnescape(n)
		if err != nil || strings.TrimSpace(plain) == "" || strings.ContainsAny(plain, "/\\#") {
			return wire.ProjectBoard{}, false
		}
		names[i] = plain
	}
	forge := wire.ConnectionProviderAzuredevops
	key := strings.Join(names, "/")
	site := strings.TrimPrefix(strings.TrimPrefix(root, "https://"), "http://")
	canonical := root + "/" + url.PathEscape(names[0]) + "/" + url.PathEscape(names[1]) + "/_boards/board/t/" + url.PathEscape(names[2])
	return wire.ProjectBoard{URL: canonical, Forge: &forge, Key: &key, Site: &site}, true
}

// cleanProjectBoards is the boards as the project keeps them, or why they are not taken.
func cleanProjectBoards(boards []wire.ProjectBoard) ([]wire.ProjectBoard, error) {
	if len(boards) > mostBoards {
		return nil, fail(invalidParams, "A project has at most %d boards.", mostBoards)
	}
	out := make([]wire.ProjectBoard, 0, len(boards))
	seen := map[string]bool{}
	for _, b := range boards {
		name := strings.TrimSpace(b.Name)
		if name == "" || utf8.RuneCountInString(name) > mostBoardName || strings.ContainsAny(name, "\n\r\t") {
			return nil, fail(invalidParams, "Give each board a name of 1 to %d characters.", mostBoardName)
		}
		kept, ok := boardFromAddress(b.URL)
		if !ok {
			return nil, fail(invalidParams, "%s is not the address of a GitHub Projects board, a Jira board, a Linear team, a GitLab group board or an Azure Boards board.", strings.TrimSpace(b.URL))
		}
		if seen[kept.URL] {
			return nil, fail(invalidParams, "The board %s is in the list twice.", kept.URL)
		}
		seen[kept.URL] = true
		kept.Name = name
		out = append(out, kept)
	}
	return out, nil
}

// setProjectBoards is projects/setBoards: only the owner or an admin.
func (m *Methods) setProjectBoards(ctx context.Context, request wire.ProjectBoardsSet, user string, admin bool) (wire.Project, error) {
	boards, err := cleanProjectBoards(request.Boards)
	if err != nil {
		return wire.Project{}, err
	}
	kept, err := m.records.ChangeProject(ctx, request.ID, func(p *records.Project) (*records.Project, error) {
		if p == nil || p.IsRemoved() {
			return nil, fail(invalidParams, "There is no such project.")
		}
		if !admin && p.Owner != user {
			return nil, fail(notPermitted, "Only the project's owner or an admin can change it.")
		}
		next := *p
		next.Boards = nil
		if len(boards) > 0 {
			next.Boards = boards
		}
		return &next, nil
	})
	if err != nil {
		return wire.Project{}, err
	}
	m.s.projectsChanged(request.ID, false)
	return projectOnWire(*kept, nil, true), nil
}
