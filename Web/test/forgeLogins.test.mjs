// Settings ▸ GitHub, GitLab, Linear, Jira, Forgejo, Bitbucket and Azure DevOps on the web (#3160, #3313, #3836, #3853), as the window's Settings ▸ Account has them (#2951).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const f = await load("src/model/forgeLogins.ts");

test("the fields are filled from the caller's own entry, blank when not given", () => {
  const list = { people: [
    { id: "a", name: "Sam", kind: "person", githubLogin: "sam", jiraLogin: "sam@example.com" },
    { id: "b", name: "Me", kind: "person", you: true, githubLogin: "me-gh", linearLogin: "me", jiraLogin: "Me Too", forgejoLogin: "me-fj",
      bitbucketLogin: "me-bb", azureDevOpsLogin: "me@example.com" },
  ] };
  assert.deepEqual(f.myLogins(list), { github: "me-gh", gitlab: "", linear: "me", jira: "Me Too", forgejo: "me-fj", bitbucket: "me-bb",
    azureDevOps: "me@example.com" });
  assert.deepEqual(f.myLogins({ people: [] }), { github: "", gitlab: "", linear: "", jira: "", forgejo: "", bitbucket: "", azureDevOps: "" });
});

test("a save sends each trimmed, blank to clear, and only when something changed", () => {
  assert.deepEqual(f.loginsToSave({ github: "  me ", gitlab: "", linear: undefined, jira: " Me ", forgejo: " fj ", bitbucket: " bb ",
    azureDevOps: undefined }), { github: "me", gitlab: "", linear: "", jira: "Me", forgejo: "fj", bitbucket: "bb", azureDevOps: "" });
  const kept = { github: "me", gitlab: "", linear: "", jira: "" };
  assert.equal(f.loginsChanged(kept, { github: " me ", gitlab: "", linear: "", jira: "" }), false);
  assert.equal(f.loginsChanged(kept, { github: "", gitlab: "", linear: "", jira: "" }), true);
  assert.equal(f.loginsChanged(kept, { github: "me", gitlab: "", linear: "", jira: "me@example.com" }), true);
  assert.equal(f.loginsChanged(kept, { github: "me", gitlab: "", linear: "", jira: "", forgejo: "me-fj" }), true);
  assert.equal(f.loginsChanged(kept, { github: "me", gitlab: "", linear: "", jira: "", bitbucket: "me-bb" }), true);
  assert.equal(f.loginsChanged(kept, { github: "me", gitlab: "", linear: "", jira: "", azureDevOps: "Me" }), true);
});

test("its words are the window's", () => {
  assert.equal(f.forgeLoginsTitle, "GitHub, GitLab, Linear, Jira, Forgejo, Bitbucket and Azure DevOps");
  assert.deepEqual(f.forgeLoginFields.map((x) => x.label), ["GitHub login", "GitLab login", "Linear login", "Jira login", "Forgejo login",
    "Bitbucket login", "Azure DevOps login"]);
  assert.match(f.forgeLoginsFooter, /A Forgejo login is your user name on the connected Forgejo\./);
  assert.match(f.forgeLoginsFooter, /An Azure DevOps login is your sign-in email or display name in the organization\./);
});
