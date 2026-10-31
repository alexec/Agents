package scim

import (
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"time"
)

// MARK: Users

func (s *Server) users(w http.ResponseWriter, r *http.Request, c Caller, id string, body []byte) {
	ctx := r.Context()
	switch {
	case id == "" && r.Method == http.MethodGet:
		clauses, err := ParseFilter(r.URL.Query().Get("filter"))
		if err == nil {
			err = onlyAttrs(clauses, userFilters)
		}
		if err != nil {
			writeError(w, err)
			return
		}
		start, count, err := page(r)
		if err != nil {
			writeError(w, err)
			return
		}
		matched, e := s.Directory.Users(ctx, c.Provider, func(u User) bool { return userMatches(u, clauses) })
		if e != nil {
			writeError(w, asError(e))
			return
		}
		var resources []any
		for i := start - 1; i < len(matched) && len(resources) < count; i++ {
			resources = append(resources, shape(r, s.userMap(matched[i])))
		}
		writeJSON(w, http.StatusOK, listResponse(resources, len(matched), start))
	case id == "" && r.Method == http.MethodPost:
		m, err := readJSON(body)
		if err != nil {
			writeError(w, err)
			return
		}
		u, err := userFrom(m)
		if err != nil {
			writeError(w, err)
			return
		}
		made, e := s.Directory.CreateUser(ctx, c, u)
		if e != nil {
			s.refused(r, e)
			writeError(w, asError(e))
			return
		}
		w.Header().Set("Location", s.base()+"/Users/"+made.ID)
		writeJSON(w, http.StatusCreated, s.userMap(*made))
	case id == "":
		writeError(w, Errorf(http.StatusMethodNotAllowed, "", "%s is not supported on /Users.", r.Method))
	default:
		u, e := s.Directory.User(ctx, c.Provider, id)
		if e != nil {
			writeError(w, asError(e))
			return
		}
		if u == nil {
			writeError(w, Errorf(http.StatusNotFound, "", "No user %s here.", id))
			return
		}
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, http.StatusOK, shape(r, s.userMap(*u)))
		case http.MethodPut, http.MethodPatch:
			var m map[string]any
			var err *Error
			if r.Method == http.MethodPut {
				m, err = readJSON(body)
			} else {
				m, err = s.patched(s.userMap(*u), body)
			}
			if err != nil {
				writeError(w, err)
				return
			}
			next, err := userFrom(m)
			if err != nil {
				writeError(w, err)
				return
			}
			next.ID, next.Created = u.ID, u.Created
			kept, e := s.Directory.ReplaceUser(ctx, c, next)
			if e != nil {
				s.refused(r, e)
				writeError(w, asError(e))
				return
			}
			writeJSON(w, http.StatusOK, s.userMap(*kept))
		case http.MethodDelete:
			if e := s.Directory.DeleteUser(ctx, c, id); e != nil {
				writeError(w, asError(e))
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeError(w, Errorf(http.StatusMethodNotAllowed, "", "%s is not supported on a user.", r.Method))
		}
	}
}

func (s *Server) refused(r *http.Request, err error) {
	e := asError(err)
	if e.Status >= 500 {
		s.log("scim: " + r.Method + " " + r.URL.Path + " failed: " + err.Error())
	}
}

func meta(kind, location string, created, changed time.Time) map[string]any {
	m := map[string]any{"resourceType": kind, "location": location}
	if !created.IsZero() {
		m["created"] = created.UTC().Format(time.RFC3339)
	}
	if !changed.IsZero() {
		m["lastModified"] = changed.UTC().Format(time.RFC3339)
	}
	return m
}

// userMap is a user as SCIM writes it.
func (s *Server) userMap(u User) map[string]any {
	m := map[string]any{}
	schemas := []string{SchemaUser}
	for k, v := range u.Extra {
		var value any
		if json.Unmarshal(v, &value) == nil {
			m[k] = value
		}
		if strings.EqualFold(k, SchemaEnterprise) {
			schemas = append(schemas, SchemaEnterprise)
		}
	}
	m["schemas"] = schemas
	m["id"] = u.ID
	m["userName"] = u.UserName
	m["active"] = u.Active
	if u.ExternalID != "" {
		m["externalId"] = u.ExternalID
	}
	if u.Name != nil {
		m["name"] = toAny(u.Name)
	}
	if u.DisplayName != "" {
		m["displayName"] = u.DisplayName
	}
	if len(u.Emails) > 0 {
		m["emails"] = toAny(u.Emails)
	}
	m["meta"] = meta("User", s.base()+"/Users/"+u.ID, u.Created, u.Changed)
	return m
}

func toAny(v any) any {
	data, _ := json.Marshal(v)
	var out any
	_ = json.Unmarshal(data, &out)
	return out
}

// readOnly are the attributes a client may send and that are never kept: the server's
// own, and a password, which is never kept anywhere.
var readOnly = map[string]bool{"schemas": true, "id": true, "meta": true, "password": true, "groups": true}

// userFrom reads a user from what a client sent. Attribute names are not case
// sensitive. active is a boolean, or the strings "True" and "False" that Entra sends.
func userFrom(m map[string]any) (User, *Error) {
	var u User
	u.Active = true
	u.Extra = map[string]json.RawMessage{}
	for k, v := range m {
		switch strings.ToLower(k) {
		case "username":
			u.UserName, _ = v.(string)
		case "externalid":
			u.ExternalID, _ = v.(string)
		case "displayname":
			u.DisplayName, _ = v.(string)
		case "active":
			a, ok := boolOf(v)
			if !ok {
				return u, InvalidValue("active is true or false.")
			}
			u.Active = a
		case "name":
			if v == nil {
				continue
			}
			var n Name
			if !fromAny(v, &n) {
				return u, InvalidValue("name is an object.")
			}
			if n != (Name{}) {
				u.Name = &n
			}
		case "emails":
			if v == nil {
				continue
			}
			if !fromAny(v, &u.Emails) {
				return u, InvalidValue("emails is a list of {value, type, primary}.")
			}
			u.Emails = slices.DeleteFunc(u.Emails, func(e Email) bool { return e.Value == "" })
		default:
			if readOnly[strings.ToLower(k)] {
				continue
			}
			data, err := json.Marshal(v)
			if err == nil {
				u.Extra[k] = data
			}
		}
	}
	u.UserName = strings.TrimSpace(u.UserName)
	if u.UserName == "" || len(u.UserName) > 256 {
		return u, InvalidValue("userName is required, at most 256 characters.")
	}
	if len(u.ExternalID) > 256 || len(u.DisplayName) > 256 || len(u.Emails) > 20 {
		return u, InvalidValue("A value is too long.")
	}
	if len(u.Extra) == 0 {
		u.Extra = nil
	}
	return u, nil
}

func boolOf(v any) (bool, bool) {
	switch b := v.(type) {
	case bool:
		return b, true
	case string:
		switch strings.ToLower(b) {
		case "true":
			return true, true
		case "false":
			return false, true
		}
	}
	return false, false
}

func fromAny(v, into any) bool {
	data, err := json.Marshal(v)
	if err != nil {
		return false
	}
	return json.Unmarshal(data, into) == nil
}

// MARK: Groups

func (s *Server) groups(w http.ResponseWriter, r *http.Request, c Caller, id string, body []byte) {
	ctx := r.Context()
	switch {
	case id == "" && r.Method == http.MethodGet:
		clauses, err := ParseFilter(r.URL.Query().Get("filter"))
		if err == nil {
			err = onlyAttrs(clauses, groupFilters)
		}
		if err != nil {
			writeError(w, err)
			return
		}
		start, count, err := page(r)
		if err != nil {
			writeError(w, err)
			return
		}
		matched, e := s.Directory.Groups(ctx, c.Provider, func(g Group) bool { return groupMatches(g, clauses) })
		if e != nil {
			writeError(w, asError(e))
			return
		}
		var resources []any
		for i := start - 1; i < len(matched) && len(resources) < count; i++ {
			resources = append(resources, shape(r, s.groupMap(matched[i])))
		}
		writeJSON(w, http.StatusOK, listResponse(resources, len(matched), start))
	case id == "" && r.Method == http.MethodPost:
		m, err := readJSON(body)
		if err != nil {
			writeError(w, err)
			return
		}
		g, err := groupFrom(m)
		if err != nil {
			writeError(w, err)
			return
		}
		made, e := s.Directory.CreateGroup(ctx, c, g)
		if e != nil {
			s.refused(r, e)
			writeError(w, asError(e))
			return
		}
		w.Header().Set("Location", s.base()+"/Groups/"+made.ID)
		writeJSON(w, http.StatusCreated, s.groupMap(*made))
	case id == "":
		writeError(w, Errorf(http.StatusMethodNotAllowed, "", "%s is not supported on /Groups.", r.Method))
	default:
		g, e := s.Directory.Group(ctx, c.Provider, id)
		if e != nil {
			writeError(w, asError(e))
			return
		}
		if g == nil {
			writeError(w, Errorf(http.StatusNotFound, "", "No group %s here.", id))
			return
		}
		switch r.Method {
		case http.MethodGet:
			writeJSON(w, http.StatusOK, shape(r, s.groupMap(*g)))
		case http.MethodPut, http.MethodPatch:
			var m map[string]any
			var err *Error
			if r.Method == http.MethodPut {
				m, err = readJSON(body)
			} else {
				m, err = s.patched(s.groupMap(*g), body)
			}
			if err != nil {
				writeError(w, err)
				return
			}
			next, err := groupFrom(m)
			if err != nil {
				writeError(w, err)
				return
			}
			next.ID, next.Created = g.ID, g.Created
			kept, e := s.Directory.ReplaceGroup(ctx, c, next)
			if e != nil {
				s.refused(r, e)
				writeError(w, asError(e))
				return
			}
			// Entra reads nothing back from a PATCH: 204 would do, but 200 with the group
			// is what Okta wants, and both take it.
			writeJSON(w, http.StatusOK, shape(r, s.groupMap(*kept)))
		case http.MethodDelete:
			if e := s.Directory.DeleteGroup(ctx, c, id); e != nil {
				writeError(w, asError(e))
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			writeError(w, Errorf(http.StatusMethodNotAllowed, "", "%s is not supported on a group.", r.Method))
		}
	}
}

func (s *Server) groupMap(g Group) map[string]any {
	members := make([]any, 0, len(g.Members))
	for _, m := range g.Members {
		one := map[string]any{"value": m.Value, "$ref": s.base() + "/Users/" + m.Value, "type": "User"}
		if m.Display != "" {
			one["display"] = m.Display
		}
		members = append(members, one)
	}
	m := map[string]any{"schemas": []string{SchemaGroup}, "id": g.ID, "displayName": g.DisplayName, "members": members,
		"meta": meta("Group", s.base()+"/Groups/"+g.ID, g.Created, g.Changed)}
	if g.ExternalID != "" {
		m["externalId"] = g.ExternalID
	}
	return m
}

// mostMembers bounds one group: the most people a control plane provisions (FR-023).
const mostMembers = 10000

func groupFrom(m map[string]any) (Group, *Error) {
	var g Group
	for k, v := range m {
		switch strings.ToLower(k) {
		case "displayname":
			g.DisplayName, _ = v.(string)
		case "externalid":
			g.ExternalID, _ = v.(string)
		case "members":
			if v == nil {
				continue
			}
			var members []struct {
				Value   string `json:"value"`
				Display string `json:"display"`
				Type    string `json:"type"`
			}
			if !fromAny(v, &members) {
				return g, InvalidValue("members is a list of {value}.")
			}
			seen := map[string]bool{}
			for _, member := range members {
				if strings.EqualFold(member.Type, "Group") {
					return g, InvalidValue("A group's members are users: groups in groups are not supported.")
				}
				if member.Value == "" || seen[member.Value] {
					continue
				}
				seen[member.Value] = true
				g.Members = append(g.Members, Member{Value: member.Value, Display: member.Display})
			}
		}
	}
	g.DisplayName = strings.TrimSpace(g.DisplayName)
	if g.DisplayName == "" || len(g.DisplayName) > 256 {
		return g, InvalidValue("displayName is required, at most 256 characters.")
	}
	if len(g.Members) > mostMembers {
		return g, InvalidValue("A group has at most %d members.", mostMembers)
	}
	return g, nil
}
