package azureboardsmcp

import (
	"context"
	"net/http"
	"net/url"
	"strings"
)

// A board in a project's Tasks slot (#3816, after #3282): an Azure Boards board is a team's
// backlog, and a team's work items are the ones under its area paths (its team field's values).
// A list narrowed to the board reads the team's area paths, then the work items in them.

// Area is an area path a team owns: Under is whether the paths below it are the team's too.
type Area struct {
	Path  string
	Under bool
}

// TeamAreas is the area paths of team in project (organization/project): its team field's
// values. A team whose field is not the area path (a process with a custom team field) is
// refused: its board is not one this reads.
func (f *RealBoards) TeamAreas(ctx context.Context, project, team string) ([]Area, error) {
	org, name, _ := strings.Cut(project, "/")
	var answer struct {
		Field struct {
			ReferenceName string `json:"referenceName"`
		} `json:"field"`
		Values []struct {
			Value           string `json:"value"`
			IncludeChildren bool   `json:"includeChildren"`
		} `json:"values"`
	}
	path := url.PathEscape(org) + "/" + url.PathEscape(name) + "/" + url.PathEscape(team) + "/_apis/work/teamsettings/teamfieldvalues"
	if err := f.call(ctx, http.MethodGet, api(path, nil, apiVersion), nil, true, &answer); err != nil {
		return nil, err
	}
	if field := answer.Field.ReferenceName; field != "" && field != fieldArea {
		return nil, &BoardsError{Kind: Failed, Message: "Azure Boards: the team " + team + " is by " + field + ", not its area path, so its board is not read"}
	}
	out := make([]Area, 0, len(answer.Values))
	for _, v := range answer.Values {
		if v.Value != "" {
			out = append(out, Area{Path: v.Value, Under: v.IncludeChildren})
		}
	}
	if len(out) == 0 {
		return nil, &BoardsError{Kind: NotFound, Message: "Azure Boards: the team " + team + " has no area path"}
	}
	return out, nil
}

// areasWhere is the WIQL condition for areas: in one of them, or under one that takes its
// children.
func areasWhere(areas []Area) string {
	parts := make([]string, len(areas))
	for i, a := range areas {
		op := " = "
		if a.Under {
			op = " UNDER "
		}
		parts[i] = "[" + fieldArea + "]" + op + wiqlQuoted(a.Path)
	}
	return "(" + strings.Join(parts, " OR ") + ")"
}
