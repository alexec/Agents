import Foundation
import AgentsKitCore

enum GitHubProjectQuery {
    static let text = #"""
        query($owner: String!, $name: String!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            projectsV2(first: 1) {
              nodes {
                id title url
                fields(first: 100) {
                  nodes {
                    __typename
                    ... on ProjectV2SingleSelectField { id name options { id name } }
                  }
                }
                items(first: 100, after: $cursor) {
                  nodes {
                    id
                    content {
                      __typename
                      ... on Issue {
                        id number title body url labels(first: 100) { nodes { name } }
                      }
                    }
                    fieldValues(first: 100) {
                      nodes {
                        __typename
                        ... on ProjectV2ItemFieldSingleSelectValue {
                          field { ... on ProjectV2SingleSelectField { id name } }
                          optionId name
                        }
                      }
                    }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
          }
        }
        """#

    enum Failure: Error {
        case malformed
    }

    static let updateStatusText = #"""
        mutation($project: ID!, $item: ID!, $field: ID!, $option: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $project, itemId: $item, fieldId: $field,
            value: { singleSelectOptionId: $option }
          }) { projectV2Item { id } }
        }
        """#

    static func updateStatus(projectID: String, itemID: String, fieldID: String,
                             optionID: String, host: String, using cli: GitHubCLI) async throws {
        let data = try await cli.graphql(updateStatusText,
                                         variables: ["project": projectID, "item": itemID,
                                                     "field": fieldID, "option": optionID],
                                         host: host)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let updated = payload["updateProjectV2ItemFieldValue"] as? [String: Any],
              let item = updated["projectV2Item"] as? [String: Any],
              item["id"] as? String == itemID else { throw Failure.malformed }
    }

    struct Result: Sendable {
        var projectID: String
        var title: String
        var url: URL
        var statusFieldID: String?
        var readyOptionID: String?
        var inProgressOptionID: String?
        var issues: [GitHubProjectIssue]
    }

    static func fetch(repository: GitHubRepository, folder: URL, using cli: GitHubCLI,
                      now: Date = Date()) async throws -> GitHubProjectBoard? {
        var cursor: String?
        var first: Page?
        var issues: [GitHubProjectIssue] = []
        repeat {
            var variables = ["owner": repository.owner, "name": repository.name]
            if let cursor { variables["cursor"] = cursor }
            let data = try await cli.graphql(text, variables: variables, host: repository.host)
            let page = try decode(data)
            guard let page else { return nil }
            if first == nil { first = page }
            issues.append(contentsOf: page.issues)
            cursor = page.hasNextPage ? page.endCursor : nil
        } while cursor != nil

        guard let first else { return nil }
        return GitHubProjectBoard(folder: folder, repository: repository,
                                  projectID: first.projectID, projectTitle: first.title,
                                  projectURL: first.url, statusFieldID: first.statusFieldID,
                                  readyOptionID: first.readyOptionID,
                                  inProgressOptionID: first.inProgressOptionID,
                                  issues: issues, fetchedAt: now,
                                  problem: configurationProblem(first))
    }

    private struct Page {
        var projectID: String
        var title: String
        var url: URL
        var statusFieldID: String?
        var readyOptionID: String?
        var inProgressOptionID: String?
        var issues: [GitHubProjectIssue]
        var hasNextPage: Bool
        var endCursor: String?
    }

    private static func decode(_ data: Data) throws -> Page? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let repository = payload["repository"] as? [String: Any],
              let projects = repository["projectsV2"] as? [String: Any],
              let project = (projects["nodes"] as? [[String: Any]])?.first else { return nil }
        guard let projectID = project["id"] as? String,
              let title = project["title"] as? String,
              let urlString = project["url"] as? String,
              let projectURL = URL(string: urlString),
              let items = project["items"] as? [String: Any] else { throw Failure.malformed }

        let statusField = (project["fields"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let status = statusField.first {
            ($0["__typename"] as? String) == "ProjectV2SingleSelectField"
                && ($0["name"] as? String)?.caseInsensitiveCompare("Status") == .orderedSame
        }
        let statusFieldID = status?["id"] as? String
        let options = status?["options"] as? [[String: Any]] ?? []
        let readyID = options.first {
            ($0["name"] as? String)?.caseInsensitiveCompare("Ready") == .orderedSame
        }?["id"] as? String
        let progressID = options.first {
            ($0["name"] as? String)?.caseInsensitiveCompare("In Progress") == .orderedSame
        }?["id"] as? String

        let nodes = items["nodes"] as? [[String: Any]] ?? []
        var decoded: [GitHubProjectIssue] = []
        for item in nodes {
            guard let content = item["content"] as? [String: Any],
                  content["__typename"] as? String == "Issue",
                  let issueID = content["id"] as? String,
                  let number = content["number"] as? Int,
                  let issueTitle = content["title"] as? String,
                  let issueURLString = content["url"] as? String,
                  let issueURL = URL(string: issueURLString),
                  let itemID = item["id"] as? String else { continue }
            let statusValues = (item["fieldValues"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            let statusValue = statusValues.first { value in
                let field = value["field"] as? [String: Any]
                return field?["id"] as? String == statusFieldID
            }
            let optionID = statusValue?["optionId"] as? String
            let issueStatus: GitHubProjectIssueStatus
            if optionID == readyID {
                issueStatus = .ready
            } else if optionID == progressID {
                issueStatus = .inProgress
            } else {
                continue
            }
            let labels = ((content["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            decoded.append(GitHubProjectIssue(nodeID: issueID, number: number,
                                              title: issueTitle, body: content["body"] as? String ?? "",
                                              labels: labels, url: issueURL, itemID: itemID,
                                              status: issueStatus))
        }
        let pageInfo = items["pageInfo"] as? [String: Any] ?? [:]
        return Page(projectID: projectID, title: title, url: projectURL,
                    statusFieldID: statusFieldID, readyOptionID: readyID,
                    inProgressOptionID: progressID, issues: decoded,
                    hasNextPage: pageInfo["hasNextPage"] as? Bool ?? false,
                    endCursor: pageInfo["endCursor"] as? String)
    }

    private static func configurationProblem(_ page: Page) -> GitHubProjectProblem? {
        guard page.statusFieldID != nil else {
            return GitHubProjectProblem(message: "This project has no single-select Status field.")
        }
        guard page.readyOptionID != nil else {
            return GitHubProjectProblem(message: "This project has no Ready status option.")
        }
        guard page.inProgressOptionID != nil else {
            return GitHubProjectProblem(message: "This project has no In Progress status option.")
        }
        return nil
    }
}
