package azureboardsmcp

import (
	"context"
	"embed"
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/internal/forgepages"
	"github.com/agentloops-dev/agent-loops/Go/internal/mcpevents"
	"github.com/agentloops-dev/agent-loops/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The azureboards server's view (#3826): Issues (ui://azureboards/issues), an MCP App page
// (SEP-1865) the Agents host draws on the Mac, the Remote and the web page, in the jira
// server's shape (Go/internal/jiramcp/views.go). It is fed by show_issues, a read-only tool,
// so it can be pinned. It only reads: a work item's state and tags are changed on the Work
// pages (#3815) or in Azure Boards.

// pages/bridge.js, pages/lineage.js and pages/common.css are the github server's, copied: a page has no
// network, so it carries its own.
//
//go:embed pages
var pageFiles embed.FS

const (
	viewMime  = "text/html;profile=mcp-app"
	issuesURI = "ui://azureboards/issues"
)

func page(name string) string {
	read := func(n string) string {
		b, err := pageFiles.ReadFile("pages/" + n)
		if err != nil {
			panic(err)
		}
		return string(b)
	}
	return strings.NewReplacer("/*common.css*/", forgepages.Style+read("common.css"), "/*bridge.js*/", read("bridge.js"), "/*lineage.js*/", read("lineage.js")).Replace(read(name))
}

func uiMeta(uri string, visibility ...string) mcp.Meta {
	return mcp.Meta{"ui": map[string]any{"visibility": visibility, "resourceUri": uri}, "ui/resourceUri": uri}
}

// openCategories are the state categories a page lists, in the order it shows them. Every
// state of every work item type is in one of these, or in Completed or Removed (closed).
var openCategories = []string{"Proposed", "InProgress", "Resolved"}

// The Issues page's sections (#2453, specs/2453-team-lists.md), the jira server's
// (Go/internal/jiramcp/sections.go) in Azure Boards' words. An organization has only its own
// members and its bots, no customers, so with no control-plane people (#2951) every work item
// that is not the viewer's is Team. With control-plane people, Team is the people and bots on
// this control plane, by their Azure DevOps login (#3853), and Others is the rest.
const (
	sectionNeedsYou = "needs_you"
	sectionYours    = "yours"
	sectionTeam     = "team"
	sectionOthers   = "others"
)

// itemSection is a work item's section: Needs you is assigned to the viewer, the token's
// owner; Yours is made by the viewer.
func itemSection(w WorkItem, me string, people teamMeta) string {
	switch {
	case me != "" && w.AssigneeID == me:
		return sectionNeedsYou
	case me != "" && w.Creator != nil && w.Creator.ID == me:
		return sectionYours
	}
	if len(people) > 0 {
		if _, on := people.of(w.Creator); !on {
			return sectionOthers
		}
	}
	return sectionTeam
}

// teamMeta is the control plane's people and bots, by Azure DevOps login lowercased (#2951,
// #3853): read from the call's _meta, which the host fills in, so this server makes no
// control-plane call of its own. Empty with no control plane, or a host that gives no Azure
// DevOps logins.
type teamMeta map[string]teamPerson

// teamPerson is one of teamMeta's people, as the control plane knows them.
type teamPerson struct {
	Name string
	Bot  bool
}

// teamMetaOf reads _meta's people (#2951): each with an Azure DevOps login, lowercased.
func teamMetaOf(meta mcp.Meta) teamMeta {
	list, ok := meta["people"].([]any)
	if !ok {
		return nil
	}
	out := teamMeta{}
	for _, item := range list {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		login, _ := row["azuredevops"].(string)
		if login == "" {
			continue
		}
		name, _ := row["name"].(string)
		bot, _ := row["bot"].(bool)
		out[strings.ToLower(login)] = teamPerson{Name: name, Bot: bot}
	}
	return out
}

// of is the control-plane person who is p (#3853). An Azure DevOps login is the sign-in email
// or the display name (the connection's own is the display name), so either matches, and the
// identity's id too.
func (t teamMeta) of(p *Person) (teamPerson, bool) {
	if p == nil {
		return teamPerson{}, false
	}
	for _, login := range []string{p.Name, p.DisplayName, p.ID} {
		if login == "" {
			continue
		}
		if tp, on := t[strings.ToLower(login)]; on {
			return tp, true
		}
	}
	return teamPerson{}, false
}

// agentOnOf reads _meta's agentOnBoards (#2951): who is on that work item (AB#12), or "".
func agentOnOf(meta mcp.Meta, id int) string {
	m, ok := meta["agentOnBoards"].(map[string]any)
	if !ok {
		return ""
	}
	who, _ := m["AB#"+itoa(id)].(string)
	return who
}

type issuesArgs struct {
	Type     string `json:"type,omitempty" jsonschema:"only work items of this type, as Bug or User Story"`
	Category string `json:"category,omitempty" jsonschema:"only work items in a state of this category: Proposed, InProgress or Resolved"`
	Label    string `json:"label,omitempty" jsonschema:"only work items with this tag"`
}

// AddViews puts the view's tools and page on server.
func AddViews(server *mcp.Server, b *RealBoards) {
	mcp.AddTool(server, &mcp.Tool{Name: "show_issues", Title: "Show Azure Boards work items",
		Description: "The project's open work items (not in a Completed or Removed state), changed last first, at most 50, each with " +
			"its id (AB#12), type, state and its category, area, tags (labels), assignee, author and section for the token's owner: needs_you (assigned to you), yours (made by you), team (the people and bots on this control plane by their Azure DevOps login, or with no control plane everyone else) or others; attention counts needs_you. agentOn says who is " +
			"on one of the viewer's own. It also gives the project's work item types. " +
			"A type, a state category (Proposed, InProgress or Resolved) or a tag narrows it. " +
			"Its view is the Azure Boards page, where a person expands a row for its description or chooses Start Agent.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, req *mcp.CallToolRequest, in issuesArgs) (*mcp.CallToolResult, any, error) {
			if in.Category != "" && !slices.Contains(openCategories, in.Category) {
				return failed(fmt.Errorf("category must be one of %s", strings.Join(openCategories, ", "))), nil, nil
			}
			project, err := b.Project(ctx)
			if err != nil {
				return failed(err), nil, nil
			}
			list, truncated, err := b.List(ctx, Filter{State: "open", Type: strings.TrimSpace(in.Type), Category: in.Category,
				Label: strings.TrimSpace(in.Label)})
			if err != nil {
				return failed(err), nil, nil
			}
			me, err := b.myID(ctx, project)
			if err != nil {
				return failed(err), nil, nil
			}
			types, err := b.typesOf(ctx, project)
			if err != nil {
				return failed(err), nil, nil
			}
			typeNames := make([]string, 0, len(types))
			for name := range types {
				typeNames = append(typeNames, name)
			}
			sort.Strings(typeNames)
			items := make([]any, len(list))
			// The count on the sidebar's row (#2033): the work items that need the viewer (#2453).
			needsYou := 0
			people := teamMetaOf(req.Params.Meta)
			for i, w := range list {
				j := w.json()
				j["key"] = "AB#" + itoa(w.ID)
				j["statusCategory"], j["updatedAt"] = w.Category, mcpevents.Normalized(w.UpdatedAt)
				if w.Creator != nil && w.Creator.Bot {
					j["authorBot"] = true
				}
				if tp, on := people.of(w.Creator); on {
					j["authorName"] = tp.Name
					if tp.Bot {
						j["authorBot"] = true
					}
				}
				section := itemSection(w, me, people)
				j["section"] = section
				if section == sectionNeedsYou {
					needsYou++
				}
				if section == sectionNeedsYou || section == sectionYours {
					if who := agentOnOf(req.Params.Meta, w.ID); who != "" {
						j["agentOn"] = who
					}
				}
				items[i] = j
			}
			return structured(map[string]any{"project": project, "type": in.Type, "category": in.Category, "label": in.Label,
				"types": typeNames, "categories": openCategories, "issues": items, "count": len(items),
				"attention": needsYou, "truncated": truncated}), nil, nil
		})

	tool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show work item details",
		Description: "One work item's description, rendered as rich text for the Azure Boards page.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, in idArgs) (map[string]any, error) {
			if err := itemID(in.ID); err != nil {
				return nil, err
			}
			w, description, _, err := b.Get(ctx, in.ID, 0)
			if err != nil {
				return nil, err
			}
			// Azure DevOps keeps a description as HTML: made safe, never drawn as it is.
			return map[string]any{"id": w.ID, "key": "AB#" + itoa(w.ID), "description": clip(description, descriptionChars),
				"descriptionHTML": richtext.HTML(description)}, nil
		})

	// No network at all: an empty csp, so the host draws it under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	html := page("issues.html")
	server.AddResource(&mcp.Resource{URI: issuesURI, Name: "issues", Title: "Azure Boards work items",
		Description: "The project's open work items, with their type, state, tags and assignee, and Start Agent; " +
			"a type, a state category or a tag narrows the list. A person expands a row to read its description. Fed by show_issues.", MIMEType: viewMime, Meta: meta},
		func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: issuesURI, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
		})
}
