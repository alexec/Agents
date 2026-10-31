---
diataxis: how-to
devices: [mac]
description: Search skills.sh from the app, look at a skill before it goes in, and add it for yourself or to a folder; then keep it up to date or take it out.
---

# Add a skill from a catalogue

You can find a skill on [skills.sh](https://skills.sh), in Anthropic's skills repository, or in
a marketplace you added (see [Choose marketplaces](choose-marketplaces.md)), and add it
without leaving the app,
either for yourself, so every agent you start has it, or to one folder, so every agent
working in that folder has it. The app shows you everything in the skill before anything is
written, and it takes the skill at a fixed commit.

## Before you start

- Skills.sh lists skills that live on GitHub. The app reads them from GitHub directly; if you
  are signed in to GitHub with `gh`, it uses that sign-in, which raises GitHub's hourly limit.
  Nothing else is needed.

## Add a skill for yourself

1. Open **Settings ▸ Agent Configuration ▸ Skills** and choose **Add skill…**.
2. Type what you are looking for. Results come from the marketplace chosen in the
   **Marketplace** menu: skills.sh lists the most installed first; a repository lists every
   skill before you type. Each shows
   who wrote it (`owner/repo`) and how many installs it has. **known** marks an owner on the
   app's short list (Anthropic, OpenAI, Google, GitHub, Microsoft, Vercel, Apple and a few
   more). Other owners are not flagged; most good skills come from people. **added** marks one
   already added where you are adding to.
3. Choose one. The app fetches it at the repository's current commit and shows the commit,
   every file, the skill's `SKILL.md` as the agent reads it, and which runtimes will get it.
   If the skill brings a script, it says so, because an agent may run it with the agent's own
   permissions.
4. Choose **Add to ~/.agents**. The skill goes into `~/.agents/skills/<name>`, and the next
   agent you start, on any runtime, has it.

## Add a skill to a folder

1. Open the folder, then choose **Folder Settings** in its toolbar, and **Instructions &
   skills** in the sheet. The **Skills** section lists the skills in the folder's `.agents/skills`.
2. Choose **Add skill…** there, and search and choose as above. **Add to** starts on the
   folder; the button reads **Add to** and the folder's name.
3. The skill goes into `<folder>/.agents/skills/<name>`, and is recorded in
   `skills-lock.json` at the top of the folder.

The app writes the files and commits nothing. They show in the folder's changes like
anything else an agent writes, and once you commit them, everyone who clones the folder gets
the skill. A worktree's page adds to that worktree's own `.agents`, not the main checkout's.

You can switch **Add to** between you and the folder in the sheet at any point; nothing is
fetched again.

## Keep a skill up to date

When a skill's source has changed since it was added, it is marked **update** in
**Settings ▸ Agent Configuration ▸ Skills** or in Folder Settings. The app asks GitHub at most once an hour
for each repository.

1. Choose **Update…**. The sheet lists what changes, file by file, and shows the new
   `SKILL.md`.
2. Choose **Update**. The copy that was there goes to the Trash.

If you have edited the skill since it was added, the sheet says so and asks again before
your edits go.

## Take a skill out

Choose **Remove…** in the skill's detail, or **Remove** in Folder Settings, and confirm. The
folder goes to the Trash and its record is dropped. No agent started after that has it.

## What the app will not touch

- **Skills you made.** Update and Remove are offered only for skills the app, or the `skills`
  tool, added: those a lock file names. If a skill of yours has the same name as one you want
  to add, the app says so and leaves yours alone. It offers the other place, you or the
  folder, when that one is free.
- **The `skills` tool's own installs outside `~/.agents`.** `npx skills add … --agent
  claude-code` puts a skill in `~/.claude/skills`; the app leaves that folder to Claude and to
  the tool.

## Working with `npx skills`

The app keeps the same records as the [`skills`](https://github.com/vercel-labs/skills)
command-line tool: `~/.agents/.skill-lock.json` for yours and `skills-lock.json` for a
folder's. A skill added one way shows up the other: `npx skills list` lists what the app
added, the app lists what `npx skills add` put in `~/.agents/skills`, and
`npx skills experimental_install` in a fresh clone restores a folder's skills.

## If something goes wrong

- **Can't reach skills.sh:** the sheet says so and keeps what you typed; choose
  **Try again** once you are online. Nothing you have is affected.
- **GitHub is limiting requests:** the app falls back to downloading the whole commit once.
  If that fails too, try again in a few minutes, or sign in with `gh auth login`.
- **An add is interrupted,** for example if the Mac restarts part way: the next time the app
  starts, it undoes the unfinished add, so you never end up with half a skill.

## Related

- [Share skills, instructions and connectors with every agent](share-skills-across-agents.md)
- [Folders, hosts and worktrees](../explanation/folders-machines-worktrees.md)
