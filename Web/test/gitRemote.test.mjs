// Clone Git URL… (#115): the same spellings taken and refused as GitRemoteTests in Swift (027).
import { test } from "node:test";
import assert from "node:assert/strict";
import { load } from "./load.mjs";

const g = await load("src/model/gitRemote.ts");

const accepted = [
  ["https://github.com/octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"],
  ["https://github.com/octocat/Hello-World", "github.com", "octocat/Hello-World", "Hello-World"],
  ["https://github.com/octocat/Hello-World/", "github.com", "octocat/Hello-World", "Hello-World"],
  ["  https://GitHub.com/octocat/Hello-World.git\n", "github.com", "octocat/Hello-World.git", "Hello-World"],
  ["git@github.com:octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"],
  ["github.com:octocat/Hello-World", "github.com", "octocat/Hello-World", "Hello-World"],
  ["ssh://git@github.com/octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"],
  ["ssh://git@git.example.com:2222/team/sub/api.git", "git.example.com", "team/sub/api.git", "api"],
  ["https://user@gitlab.com/group/project.git", "gitlab.com", "group/project.git", "project"],
];
for (const [text, host, path, folder] of accepted) {
  test(`git remote: ${JSON.stringify(text)} is cloned into ${folder}`, () => {
    const remote = g.gitRemote(text);
    assert.ok(remote);
    assert.deepEqual(remote, { url: text.trim(), host, path, folderName: folder });
  });
}

const refused = ["", "   ", "hello world", "/Users/alex/Code/api", "~/Code/api", "./a:b", "file:///Users/alex/api.git",
  "http://github.com/octocat/Hello-World.git", "git://github.com/octocat/Hello-World.git", "https://github.com",
  "https://github.com/", "git@github.com:", "-uhttps://evil", "--upload-pack=touch /tmp/x",
  "https://github.com/octocat/.git", "https://github.com/octocat/..", "https://github.com/a b/c"];
for (const text of refused) {
  test(`git remote: ${JSON.stringify(text)} is not cloned`, () => assert.equal(g.gitRemote(text), null));
}
