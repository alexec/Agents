---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: The persona file format, where personas live, and what picking one does.
---

# Personas

A persona is a kind of session you pick when you start an agent. It sets the new session's
runtime, model, effort, permission mode and labels in one go, and gives the agent a prompt
of its own.

## Where they live

A persona is one Markdown file in a `.agents/personas` folder:

- in the folder, for that folder's sessions;
- in `~/.agents`, for every folder on that computer.

The file name, without `.md`, is the persona's id. When the folder and `~/.agents` both have
one with the same id, the folder's is used.

No runtime reads these folders as skills, so an agent cannot pick a persona up half way
through a session.

## The file

```markdown
---
name: Reviewer
description: Reads a change and says what is wrong with it.
runtime: codex
model: gpt-5.5
effort: high
permission-mode: read-only
labels: [review]
keywords: ["review", "check this"]
---

You review changes. Use the code-review skill, and say what you would change before
changing anything.
```

| Key | What it sets |
|---|---|
| `name` | The name on the choice. The id when left out. |
| `description` | The line shown under the choice once it is picked. |
| `keywords` | The words in a first prompt that make **Auto** pick this persona (#4559). `"#<n>"` stands for any issue number, such as `#123`. When left out, the words of five letters or more in `name` and `description` are used. |
| `runtime`, `model`, `effort`, `permission-mode`, `options`, `labels` | The same settings, with the same values, as in a [workflow](workflows.md). |

Every key is optional, and so is the front matter: a file with none is all prompt.

The body is the persona's prompt. It can name the skills the persona relies on.

## Manage them in Agents

Manage your own persona files in **Settings ▸ Agent Configuration ▸ Personas**, on the Mac, the iPhone, the iPad and the web. On the Mac, manage a folder's persona files in **Project Settings ▸ Agent Configuration ▸ Personas**. You choose a persona on the new-session form on every client.
Choose the folder or personal scope, then open a file, create one, edit its Markdown or
delete it. The editor keeps the whole Markdown file, including front matter fields the app
does not know, so a saved persona is available to future session starts in that scope.

## Picking one

The choice is a menu under the folder's name at the top of the new-session form, on the
Mac, the Remote and the web page (#918). It shows **Auto**, the persona picked, or **No persona**, and
**Auto** is first, then **No persona**. It is not shown when the folder has no personas. A file that cannot be read is listed under it with what is wrong.

Picking a persona:

- sets every setting it names, as far as the runtime offers it; a model the runtime does not
  offer leaves the model as it was;
- leaves every setting it does not name as the form had it;
- adds its labels beside any already there.

You can still change anything before you start.

### Auto

When the folder has personas, the first segment is **Auto**, and a new draft starts on it
(#4559). As you type the first prompt, Auto picks the persona whose `keywords` the prompt
names, as if you picked it:

- a keyword counts when it is a whole word, followed by a space or punctuation, so a
  half-typed word does not match; case does not matter;
- the persona with the most matches wins, and the earliest match breaks a tie;
- when no keyword matches, the session has no persona;
- a grey line under the control names the pick and the word, for example
  `Auto picked Product Owner: "what about"`.

When you pick a segment yourself, the pick stays for that draft and typing does not move it.
Pick **Auto** again to turn the live pick back on.

When a runtime advertises ACP's session system-prompt capability, the persona prompt is appended after the app's briefing on session creation and when the app loads, resumes or forks the session. Otherwise the app uses a runtime compatibility adapter where available, or sends the persona prompt before your words in the first user prompt. It is read from the file each time, and is not shown in the transcript.

## From a marketplace

A GitHub marketplace (a repository; see [Choose marketplaces](../how-to/choose-marketplaces.md))
can hold personas as well as skills. They are the files in its `personas/` folder, next to
`skills/`, one `<id>.md` each, in the format above. Only the top of `personas/` counts: a file
in a folder inside it is not a persona. skills.sh lists skills only, so it has no personas.

In **Settings ▸ Agent Configuration ▸ Personas** (and Project Settings, for a folder),
**Add persona…** searches the marketplace you choose. Choosing one shows the whole file,
front matter included, and the `runtime`, `model`, `effort` and `permission-mode` it sets.
**Add** writes it at the repository's current commit to `~/.agents/personas/<id>.md` or the
folder's `.agents/personas/<id>.md`.

The app records each one in the same lock file as skills, `~/.agents/.skill-lock.json` or the
folder's `skills-lock.json`, under a `personas` key of its own, with the repository, the path,
the commit and the file's blob SHA. Personas are kept out of `skills` so that the `skills`
tool never takes one for a skill. That tool does not know the key, so when it writes a
folder's lock again, the key goes, and those personas become ones you made: the app leaves
them alone.

- **Update:** when the source changes, the persona shows **update**. The app asks GitHub at
  most once an hour for each repository. **Update…** shows a diff of the file, and nothing
  changes until you choose **Update**. The old copy goes to the Trash.
- **A warning:** when an update changes `runtime` or `permission-mode`, the update sheet says
  so above the diff, with the old and the new value.
- **No automatic update.** A persona sets the permission mode and the runtime, so a silent
  change at the source could give new sessions more permissions, or a runtime that costs more.
- **Personas you made:** the app does not update or remove a persona that the lock does not
  name, and does not add one over it. If you edit one that you added, the page marks it
  **edited**, and an update asks again before your edits go to the Trash.
- **Remove…** moves the file to the Trash and takes it out of the lock.

This is on the Mac, and on the web page in **Settings ▸ Agent Configuration ▸ Personas**
for the machine you choose (#3678). The web page chooses from the marketplaces that are on;
add or turn one on in the Mac app. The Remote does not add personas from a marketplace; it
still picks them.
