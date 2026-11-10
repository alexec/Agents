#!/usr/bin/env python3
"""Dump every issue of a repo (dates, labels, milestone, parent, blocked-by,
the PRs that closed it) to a JSON file, for backtest.py (#4523).

    python3 specs/4533-forecasting/fetch.py alexec/Agents /tmp/issues.json

The dump holds titles of no issue and stays out of the repo.
"""
import json
import subprocess
import sys

QUERY = """
query($owner:String!,$name:String!,$after:String){
  repository(owner:$owner,name:$name){
    issues(first:100,after:$after,orderBy:{field:CREATED_AT,direction:ASC}){
      pageInfo{hasNextPage endCursor}
      nodes{
        number createdAt closedAt state stateReason
        labels(first:30){nodes{name}}
        milestone{number}
        parent{number}
        blockedBy(first:20){nodes{number}}
        closedByPullRequestsReferences(first:5,includeClosedPrs:false){nodes{number mergedAt}}
      }
    }
  }
}"""


def main():
    owner, name = sys.argv[1].split("/")
    out, after = [], None
    while True:
        args = ["gh", "api", "graphql", "-f", f"query={QUERY}",
                "-F", f"owner={owner}", "-F", f"name={name}"]
        if after:
            args += ["-F", f"after={after}"]
        page = json.loads(subprocess.check_output(args))["data"]["repository"]["issues"]
        for n in page["nodes"]:
            prs = [p for p in n["closedByPullRequestsReferences"]["nodes"] if p["mergedAt"]]
            out.append({
                "number": n["number"],
                "createdAt": n["createdAt"],
                "closedAt": n["closedAt"],
                "completed": n["stateReason"] == "COMPLETED",
                "labels": [l["name"] for l in n["labels"]["nodes"]],
                "milestone": (n["milestone"] or {}).get("number"),
                "parent": (n["parent"] or {}).get("number"),
                "blockedBy": [b["number"] for b in n["blockedBy"]["nodes"]],
                "mergedAt": min((p["mergedAt"] for p in prs), default=None),
            })
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    json.dump(out, open(sys.argv[2], "w"))
    print(len(out), "issues")


if __name__ == "__main__":
    main()
