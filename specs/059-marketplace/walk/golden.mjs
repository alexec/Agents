// Golden computedHash values for 059's fixtures (tasks T003).
// computeSkillFolderHash and collectFiles are copied verbatim from the `skills` CLI 1.7.0
// (vercel-labs/skills, dist/cli.mjs), so the Swift port is checked against the real thing.
// Usage: node golden.mjs <fixture folder>...   → prints {"<name>": "<hash>", ...}
import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join, relative, basename } from "node:path";

async function computeSkillFolderHash(skillDir) {
	const files = [];
	await collectFiles(skillDir, skillDir, files);
	files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
	const hash = createHash("sha256");
	for (const file of files) {
		hash.update(file.relativePath);
		hash.update(file.content);
	}
	return hash.digest("hex");
}
async function collectFiles(baseDir, currentDir, results) {
	const entries = await readdir(currentDir, { withFileTypes: true });
	await Promise.all(entries.map(async (entry) => {
		const fullPath = join(currentDir, entry.name);
		if (entry.isDirectory()) {
			if (entry.name === ".git" || entry.name === "node_modules") return;
			await collectFiles(baseDir, fullPath, results);
		} else if (entry.isFile()) {
			const content = await readFile(fullPath);
			const relativePath = relative(baseDir, fullPath).split("\\").join("/");
			results.push({
				relativePath,
				content
			});
		}
	}));
}

const out = {};
for (const dir of process.argv.slice(2)) {
	const files = [];
	await collectFiles(dir, dir, files);
	files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
	out[basename(dir)] = { computedHash: await computeSkillFolderHash(dir), order: files.map((f) => f.relativePath) };
}
console.log(JSON.stringify(out, null, 2));
