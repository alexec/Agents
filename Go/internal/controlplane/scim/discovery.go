package scim

// The three discovery documents (RFC 7644 §4): what this server supports, and what not
// (FR-022).

func (s *Server) config() map[string]any {
	no := map[string]any{"supported": false}
	return map[string]any{
		"schemas":          []string{schemaConfig},
		"documentationUri": "https://github.com/alexec/Agents/blob/main/docs/reference/sign-in.md",
		"patch":            map[string]any{"supported": true},
		"bulk":             map[string]any{"supported": false, "maxOperations": 0, "maxPayloadSize": 0},
		"filter":           map[string]any{"supported": true, "maxResults": MaxResults},
		"changePassword":   no,
		"sort":             no,
		"etag":             no,
		"authenticationSchemes": []any{map[string]any{"type": "oauthbearertoken", "name": "OAuth Bearer Token",
			"description": "A SCIM token an admin makes in Console ▸ Sign-In.", "primary": true}},
		"meta": map[string]any{"resourceType": "ServiceProviderConfig", "location": s.base() + "/ServiceProviderConfig"},
	}
}

func resourceTypes(base string) []map[string]any {
	return []map[string]any{
		{"schemas": []string{schemaType}, "id": "User", "name": "User", "endpoint": "/Users", "schema": SchemaUser,
			"schemaExtensions": []any{map[string]any{"schema": SchemaEnterprise, "required": false}},
			"meta":             map[string]any{"resourceType": "ResourceType", "location": base + "/ResourceTypes/User"}},
		{"schemas": []string{schemaType}, "id": "Group", "name": "Group", "endpoint": "/Groups", "schema": SchemaGroup,
			"meta": map[string]any{"resourceType": "ResourceType", "location": base + "/ResourceTypes/Group"}},
	}
}

func attribute(name, kind string, multi, required bool, sub ...map[string]any) map[string]any {
	a := map[string]any{"name": name, "type": kind, "multiValued": multi, "required": required, "caseExact": false,
		"mutability": "readWrite", "returned": "default", "uniqueness": "none"}
	if len(sub) > 0 {
		a["subAttributes"] = sub
	}
	return a
}

func schemas() []map[string]any {
	userName := attribute("userName", "string", false, true)
	userName["uniqueness"] = "server"
	return []map[string]any{
		{"schemas": []string{schemaSchema}, "id": SchemaUser, "name": "User", "attributes": []any{
			userName,
			attribute("externalId", "string", false, false),
			attribute("name", "complex", false, false, attribute("givenName", "string", false, false),
				attribute("familyName", "string", false, false), attribute("formatted", "string", false, false)),
			attribute("displayName", "string", false, false),
			attribute("emails", "complex", true, false, attribute("value", "string", false, false),
				attribute("type", "string", false, false), attribute("primary", "boolean", false, false)),
			attribute("active", "boolean", false, false),
		}},
		{"schemas": []string{schemaSchema}, "id": SchemaGroup, "name": "Group", "attributes": []any{
			attribute("displayName", "string", false, true),
			attribute("externalId", "string", false, false),
			attribute("members", "complex", true, false, attribute("value", "string", false, false),
				attribute("display", "string", false, false)),
		}},
		{"schemas": []string{schemaSchema}, "id": SchemaEnterprise, "name": "EnterpriseUser",
			"description": "Kept as it comes, and not read.", "attributes": []any{}},
	}
}
