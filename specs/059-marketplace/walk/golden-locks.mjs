// Golden lock files for 059 (tasks T008): the `skills` CLI 1.7.0's own write logic
// (addSkillToLock / writeSkillLock, addSkillToLocalLock / writeLocalLock), copied, with the
// clock fixed, run over a "before" file. Usage: node golden-locks.mjs <fixtures/locks>
import { readFileSync, writeFileSync } from "node:fs";
const dir = process.argv[2];
const NOW = "2026-09-26T15:10:00.000Z";

// Personal: a lock with keys the app does not own, a skill added, one replaced.
const before = readFileSync(`${dir}/personal-before.json`, "utf8");
const lock = JSON.parse(before);
function addSkillToLock(skillName, entry) {           // cli.mjs, with `now` fixed
	const existingEntry = lock.skills[skillName];
	lock.skills[skillName] = { ...entry, installedAt: existingEntry?.installedAt ?? NOW, updatedAt: NOW };
}
addSkillToLock("nested", { source: "fixture-owner/fixture-skills", sourceType: "github",
	sourceUrl: "https://github.com/fixture-owner/fixture-skills.git", ref: undefined,
	skillPath: "skills/nested/SKILL.md", skillFolderHash: "b4146b99df32f406302cf36ff69949f3b394ea01", pluginName: undefined });
addSkillToLock("find-skills", { source: "vercel-labs/skills", sourceType: "github",
	sourceUrl: "https://github.com/vercel-labs/skills.git", ref: undefined,
	skillPath: "skills/find-skills/SKILL.md", skillFolderHash: "1111111111111111111111111111111111111111", pluginName: undefined });
writeFileSync(`${dir}/personal-after.json`, JSON.stringify(lock, null, 2));   // writeSkillLock: no newline

// Project: writeLocalLock sorts the skills and keeps only version and skills.
const plock = JSON.parse(readFileSync(`${dir}/project-before.json`, "utf8"));
plock.skills["nested"] = { source: "fixture-owner/fixture-skills", ref: undefined, sourceType: "github",
	skillPath: "skills/nested/SKILL.md", computedHash: "43d79cc2b2a7065d4f3f4cc5ae35447d31c5b22469dcee4c35395c2c09d0ac0e" };
const sorted = {};
for (const key of Object.keys(plock.skills).sort()) sorted[key] = plock.skills[key];
writeFileSync(`${dir}/project-after.json`, JSON.stringify({ version: plock.version, skills: sorted }, null, 2) + "\n");
