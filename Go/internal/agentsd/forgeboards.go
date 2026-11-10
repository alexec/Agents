package agentsd

import (
	"context"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Boards (#3282, specs/3273-project-unit "Boards"): a project's Tasks slot holds one or more
// boards (a GitHub Projects board, a Jira board, a Linear team, a GitLab group board, an Azure
// Boards board), which
// the control plane sends with the project's slots (machine/projects). forge/boards lists the
// boards of this machine's folders' projects, for Work's Board filter; forge/issues' board
// narrows a list to one board, read on the board's own forge:
//
//   - GitHub: the search's project:<owner>/<number>, in the project's folders' repos.
//   - GitLab: the board's scope (its labels and milestone), in the project's folders' projects
//     under the board's group, on the connected GitLab.
//   - Linear: the team.
//   - Jira: the board's filter.
//   - Azure Boards (#3816): the work items under the team's area paths, in its project, on the
//     connected Azure DevOps.
//
// Forgejo has project boards, but its API (11) cannot read them, so a list narrowed to a board
// lists no Forgejo items (#3835).
//
// A board this machine has not heard of lists nothing: it is no board of its folders.

func (d *Daemon) registerForgeBoards() {
	On(d, wire.CallForgeBoards, func(_ context.Context, _ *Client, r wire.ForgeBoardsRequest) (wire.ForgeBoards, error) {
		return d.forgeBoards(r)
	})
}

// forgeBoards is the boards of r.folder's project, or of every folder's, each once.
func (d *Daemon) forgeBoards(r wire.ForgeBoardsRequest) (wire.ForgeBoards, error) {
	folders := d.folderPaths()
	if f := deref(r.Folder); f != "" {
		if !slices.Contains(folders, f) {
			return wire.ForgeBoards{}, Invalid("forge/boards: %s is not a folder on this machine", f)
		}
		folders = []string{f}
	}
	out := wire.ForgeBoards{Boards: []wire.ProjectBoard{}}
	seen := map[string]bool{}
	for _, f := range folders {
		for _, b := range d.folderBoards(f) {
			if !seen[b.URL] {
				seen[b.URL] = true
				out.Boards = append(out.Boards, b)
			}
		}
	}
	return out, nil
}

// folderBoards is the boards of the folder's project, as the control plane last said them.
func (d *Daemon) folderBoards(folder string) []wire.ProjectBoard {
	_, tools, _ := d.folderProject(folder)
	return tools.Boards
}

// boardIn is the board url names, and the folders of those whose project has it.
func (d *Daemon) boardIn(folders []string, url string) (wire.ProjectBoard, []string, bool) {
	var board wire.ProjectBoard
	var in []string
	for _, f := range folders {
		for _, b := range d.folderBoards(f) {
			if b.URL == url && b.Forge != nil && deref(b.Key) != "" {
				board = b
				in = append(in, f)
			}
		}
	}
	return board, in, len(in) > 0
}

// forgeBoard is what a list narrowed to a board reads, beside its sources.
type forgeBoard struct {
	// forge is the board's forge, as the forge interface names it (#4329): github, …
	forge string
	// home is the folder an item acts from when no folder names its team or project.
	home string
	// project is a GitHub board's <owner>/<number>.
	project string
	// group and id are a GitLab group board's, and site the GitLab it is on.
	group, site string
	id          int
	// jira is a Jira board's id.
	jira string
	// azureProject and azureTeam are an Azure Boards board's: organization/project in lower
	// case, and the team's name. azureSite is the Azure DevOps it is on.
	azureProject, azureTeam, azureSite string
}

func (b *forgeBoard) key() []any {
	if b == nil {
		return nil
	}
	return []any{b.project, b.group, b.site, b.id, b.jira, b.azureProject, b.azureTeam, b.azureSite}
}

// narrowToBoard keeps of s only what is on the board's forge, and says what to read there.
func narrowToBoard(s *forgeSources, b wire.ProjectBoard, in []string, prs bool) *forgeBoard {
	board := &forgeBoard{forge: string(*b.Forge), home: in[0]}
	key := deref(b.Key)
	s.teams, s.projects, s.workspace = nil, nil, false
	boards := s.boards
	s.boards = nil
	switch *b.Forge {
	case wire.ConnectionProviderGithub:
		// GitHub is on the forge interface: forgeList keeps only its scope.
		board.project = key
	case wire.ConnectionProviderGitlab:
		group, number, _ := strings.Cut(key, "#")
		// GitLab is on the forge interface: gitlabForge.List reads the board's projects.
		board.group, board.site = group, deref(b.Site)
		board.id, _ = strconv.Atoi(number)
	case wire.ConnectionProviderLinear:
		if !prs {
			s.teams = []string{key}
			if _, named := s.teamFolder[key]; !named {
				s.linearHome = board.home
			}
		}
	case wire.ConnectionProviderAtlassian:
		if !prs {
			board.jira = key
		}
	case wire.ConnectionProviderAzuredevops:
		at := strings.LastIndex(key, "/")
		if at < 0 {
			break
		}
		project := strings.ToLower(key[:at])
		board.azureProject, board.azureTeam, board.azureSite = project, key[at+1:], deref(b.Site)
		if prs {
			// Azure Repos is on the forge interface: azureDevOpsForge.List reads the pull requests
			// of the project's repositories, on the Azure DevOps the board is on (#4055).
			break
		}
		s.boards = []string{project}
		if !slices.Contains(boards, project) {
			// No folder names the project: its work items act from the board's first folder.
			s.boardsFolder[project] = board.home
		}
	}
	return board
}
