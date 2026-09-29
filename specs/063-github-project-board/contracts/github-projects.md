# Contract: GitHub Projects v2 integration

The daemon calls GitHub GraphQL through the person's existing `gh` authentication for the
project repository's host. It does not store or accept access tokens.

## Read

1. Resolve the repository from its `origin` remote, using the same host/owner/name rules as the
   pull-request integration.
2. Query the repository's linked `projectsV2` connection and select its first returned project.
3. Read that project's ID, title, URL, configured fields/options, and project item connection.
   Follow pagination until all relevant items have been considered.
4. For each item, inspect issue content and its Status field value. Include only issues whose
   status option label is Ready or In Progress. Return issue number, title, body, labels and
   HTML URL, plus the project item and issue node IDs used by assignment.

Conceptual GraphQL selection (the exact query may be split to respect GraphQL connection
limits):

```graphql
repository(owner: $owner, name: $name) {
  projectsV2(first: 1) {
    nodes {
      id title url
      fields(first: 100) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } }
      items(first: 100) {
        nodes {
          id
          content { ... on Issue { id number title body url labels(first: 100) { nodes { name } } } }
          fieldValues(first: 100) { nodes { ... on ProjectV2ItemFieldSingleSelectValue { field { ... on ProjectV2SingleSelectField { id name } } optionId name } } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
```

## Update status

For a confirmed assignment, call `updateProjectV2ItemFieldValue` on the already-linked issue
item using the selected project's Status field ID and In Progress option ID. A repeat mutation
with the same value is safe and is the retry contract. Never add an issue to a project as part
of assignment.

```graphql
mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
  updateProjectV2ItemFieldValue(input: {
    projectId: $project,
    itemId: $item,
    fieldId: $field,
    value: { singleSelectOptionId: $option }
  }) { projectV2Item { id } }
}
```

## Authentication and failure behavior

- Reading Project v2 requires the person's `read:project` scope for classic token
  authentication (or equivalent permission for another token type). Reading linked private
  issue content also requires access to that repository.
- Updating a project field requires `project` scope (or equivalent write permission).
- No Projects permission, no repository access, an inaccessible private project, API limits, or
  a network failure must be reported as unavailable; never infer an empty board from a failed
  response.
- A Projects field or option ID is looked up from the project on each fresh load; IDs must not
  be assumed to match across projects or hosts.
- A missing Status field or missing In Progress option disables assignment because the required
  board transition cannot be made safely.

Official references: [Repositories GraphQL](https://docs.github.com/en/graphql/reference/repos),
[Projects GraphQL](https://docs.github.com/en/graphql/reference/projects),
[Using the API to manage Projects](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects).
