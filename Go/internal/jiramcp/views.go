package jiramcp

import (
	"context"
	"embed"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/forgepages"
	"github.com/alexec/agents/Go/internal/richtext"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The jira server's view (#3247): Issues (ui://jira/issues), an MCP App page (SEP-1865) the
// Agents host draws on the Mac, the Remote and the web page, in the linear server's shape
// (Go/internal/linearmcp/views.go). It is fed by show_issues, a read-only tool, so it can be
// pinned. It only reads: Atlassian's own MCP server changes issues.

// pages/bridge.js, pages/lineage.js and pages/common.css are the github server's, copied: a page has no
// network, so it carries its own.
//
//go:embed pages
var pageFiles embed.FS

const (
	viewMime  = "text/html;profile=mcp-app"
	issuesURI = "ui://jira/issues"
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

// Views is what the view asks of Jira.
type Views interface {
	// OpenIssues is the site's issues not in a Done status, newest updated first, at most
	// 100, narrowed to a project key, a status category and a label when they are not empty,
	// and the viewer, the user of the token, for the page's sections (#2453).
	OpenIssues(ctx context.Context, project, category, label string) ([]ListedIssue, *Person, error)
	// IssueDetails reads one issue's description.
	IssueDetails(ctx context.Context, key string) (map[string]any, error)
	// Projects is the site's projects, for the page's project choice.
	Projects(ctx context.Context) ([]Project, error)
}

// ListedIssue is an issue on the page.
type ListedIssue struct {
	Issue
	Priority  string // its name, as High, or "" for none
	UpdatedAt string
}

func (l ListedIssue) json() map[string]any {
	d := l.Issue.json()
	d["statusCategory"], d["priority"], d["updatedAt"] = l.StatusCategory, l.Priority, normalized(l.UpdatedAt)
	if l.Creator != nil && l.Creator.App {
		d["authorBot"] = true
	}
	return d
}

// Project is a Jira project: its key (PROJ) and its name.
type Project struct {
	Key, Name string
}

// openCategories are the status categories a page lists, in the order it shows them: To Do
// and In Progress. Every Jira status is in one of these or in Done.
var openCategories = []string{"new", "indeterminate"}

// categoryIDs are the status categories' ids, the same on every site, for JQL: a category's
// name can be in the site's own language.
var categoryIDs = map[string]string{"new": "2", "indeterminate": "4", "done": "3"}

var projectKey = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]{0,9}$`)

type issuesArgs struct {
	Project  string `json:"project,omitempty" jsonschema:"a project's key, such as PROJ; every project when left out"`
	Category string `json:"category,omitempty" jsonschema:"only issues in this status category: new (To Do) or indeterminate (In Progress)"`
	Label    string `json:"label,omitempty" jsonschema:"only issues with this label"`
}

type issueDetailsArgs struct {
	Key string `json:"key" jsonschema:"the issue key, such as PROJ-12"`
}

func structured(data map[string]any) *mcp.CallToolResult {
	text, _ := json.Marshal(data)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(text)}}, StructuredContent: data}
}

func failed(err error) *mcp.CallToolResult {
	msg := err.Error()
	if e, ok := err.(*JiraError); ok && e.Kind == RateLimited {
		msg = fmt.Sprintf("%s; try again in %ds", e.Message, (e.RetryAfterMs+999)/1000)
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: msg}}, IsError: true}
}

// AddViews puts the view's tools and page on server.
func AddViews(server *mcp.Server, jira Views) {
	mcp.AddTool(server, &mcp.Tool{Name: "show_issues", Title: "Show Jira issues",
		Description: "The Jira site's open issues (not in a Done status), newest updated first, at most 100, each with " +
			"its key (PROJ-12), project, status, priority, labels, assignee and section for the token's user (viewer): " +
			"needs_you (assigned to you), yours, team (the people and bots on this control plane, or the site's users and " +
			"apps, with no control plane) or others (customers); attention counts needs_you. A row the control plane knows has " +
			"authorName; agentOn says who is on one of the viewer's own. " +
			"It also gives the site's projects. " +
			"A project key, a status category (new for To Do, indeterminate for In Progress) or a label narrows it. " +
			"Its view is the Jira issues page, where a person expands a row for its description or chooses Start Agent.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta(issuesURI, "model", "app")},
		func(ctx context.Context, req *mcp.CallToolRequest, in issuesArgs) (*mcp.CallToolResult, any, error) {
			if in.Category != "" && !slices.Contains(openCategories, in.Category) {
				return failed(fmt.Errorf("category must be one of %s", strings.Join(openCategories, ", "))), nil, nil
			}
			if in.Project != "" && !projectKey.MatchString(in.Project) {
				return failed(fmt.Errorf("project must be a project key, as PROJ")), nil, nil
			}
			list, viewer, err := jira.OpenIssues(ctx, strings.ToUpper(in.Project), in.Category, in.Label)
			if err != nil {
				return failed(err), nil, nil
			}
			projects, err := jira.Projects(ctx)
			if err != nil {
				return failed(err), nil, nil
			}
			// The control plane's people (#2951): names a row, tells Team from Others.
			people := teamMetaOf(req.Params.Meta, "jira")
			issues := make([]any, len(list))
			// The count on the sidebar's row (#2033): the issues that need the viewer (#2453).
			needsYou := 0
			for i, l := range list {
				j := l.json()
				section := issueSection(l.Issue, viewer, people)
				j["section"] = section
				if tp, on := people.of(l.Creator); on {
					j["authorName"] = tp.Name
					if tp.Bot {
						j["authorBot"] = true
					}
				}
				if section == sectionNeedsYou {
					needsYou++
				}
				if section == sectionNeedsYou || section == sectionYours {
					if who := agentOnOf(req.Params.Meta, l.Key); who != "" {
						j["agentOn"] = who
					}
				}
				issues[i] = j
			}
			names := make([]any, len(projects))
			for i, p := range projects {
				names[i] = map[string]any{"key": p.Key, "name": p.Name}
			}
			return structured(map[string]any{"project": in.Project, "category": in.Category, "label": in.Label, "viewer": viewer.name(),
				"projects": names, "categories": openCategories, "issues": issues, "count": len(issues), "attention": needsYou}), nil, nil
		})

	mcp.AddTool(server, &mcp.Tool{Name: "show_issue_details", Title: "Show issue details",
		Description: "One issue's description, rendered as rich text for the Issues page.",
		Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}, Meta: uiMeta("", "model", "app")},
		func(ctx context.Context, _ *mcp.CallToolRequest, in issueDetailsArgs) (*mcp.CallToolResult, any, error) {
			if strings.TrimSpace(in.Key) == "" {
				return failed(fmt.Errorf("issue key is required")), nil, nil
			}
			details, err := jira.IssueDetails(ctx, strings.TrimSpace(in.Key))
			if err != nil {
				return failed(err), nil, nil
			}
			return structured(details), nil, nil
		})

	// No network at all: an empty csp, so the host draws it under its strictest policy.
	meta := mcp.Meta{"ui": map[string]any{"csp": map[string]any{}, "prefersBorder": true}}
	html := page("issues.html")
	server.AddResource(&mcp.Resource{URI: issuesURI, Name: "issues", Title: "Jira issues",
		Description: "The site's open Jira issues, with their project, status, priority, labels and assignee, and Start Agent; " +
			"a project, a status category or a label narrows the list. A person expands a row to read its description. Fed by show_issues.", MIMEType: viewMime, Meta: meta},
		func(context.Context, *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
			return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: issuesURI, MIMEType: viewMime, Text: html, Meta: meta}}}, nil
		})
}

// MARK: Read from Jira

// IssueDetails reads one issue's description, as Jira renders it to HTML, made safe.
func (j *RealJira) IssueDetails(ctx context.Context, key string) (map[string]any, error) {
	var out struct {
		Key    string `json:"key"`
		Fields struct {
			Description string `json:"description"`
		} `json:"fields"`
		Rendered struct {
			Description string `json:"description"`
		} `json:"renderedFields"`
	}
	if err := j.call(ctx, http.MethodGet, "/issue/"+url.PathEscape(key)+"?fields=description&expand=renderedFields", nil, &out); err != nil {
		return nil, err
	}
	return map[string]any{"key": out.Key, "description": out.Fields.Description,
		"descriptionHTML": richtext.HTML(out.Rendered.Description)}, nil
}

// OpenIssues reads the open issues, newest updated first, and the viewer.
func (j *RealJira) OpenIssues(ctx context.Context, project, category, label string) ([]ListedIssue, *Person, error) {
	viewer, err := j.Myself(ctx)
	if err != nil {
		return nil, nil, err
	}
	jql := "statusCategory != " + categoryIDs["done"]
	if category != "" {
		jql = "statusCategory = " + categoryIDs[category]
	}
	jql += projectClause(project)
	if label != "" {
		jql += " AND labels = " + quoted(label)
	}
	list, _, err := j.search(ctx, jql+" ORDER BY updated DESC", fields, "", perPage)
	if err != nil {
		return nil, nil, err
	}
	site := j.Auth().Site
	out := make([]ListedIssue, 0, len(list))
	for _, r := range list {
		l := ListedIssue{Issue: r.issue(site), UpdatedAt: r.Fields.Updated}
		if r.Fields.Priority != nil {
			l.Priority = r.Fields.Priority.Name
		}
		out = append(out, l)
	}
	// ORDER BY updated DESC is newest first; sort anyway, so a page never jumps.
	sort.SliceStable(out, func(a, b int) bool { return normalized(out[a].UpdatedAt) > normalized(out[b].UpdatedAt) })
	return out, viewer, nil
}

// Projects reads the site's projects, by key: Jira Cloud's /project/search, a page of 100,
// or Data Center's /project, every one.
func (j *RealJira) Projects(ctx context.Context) ([]Project, error) {
	type row struct {
		Key  string `json:"key"`
		Name string `json:"name"`
	}
	var rows []row
	if j.Auth().Cloud {
		var out struct {
			Values []row `json:"values"`
		}
		if err := j.call(ctx, http.MethodGet, "/project/search?maxResults=100&orderBy=key", nil, &out); err != nil {
			return nil, err
		}
		rows = out.Values
	} else if err := j.call(ctx, http.MethodGet, "/project", nil, &rows); err != nil {
		return nil, err
	}
	projects := make([]Project, 0, len(rows))
	for _, p := range rows {
		projects = append(projects, Project(p))
	}
	sort.Slice(projects, func(a, b int) bool { return projects[a].Key < projects[b].Key })
	return projects, nil
}
