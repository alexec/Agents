# Contract: `show_file` keeps its schema; its description changes

The MCP tool the app serves every agent, as `AppService.showFileTool`. The schema is not
touched: `path`, optional `line`, and nothing else. The test that asserts the schema is
extended to say so, so a later hand does not add an argument without noticing this contract.

## Schema (unchanged)

```json
{
  "name": "show_file",
  "title": "Show the person a file",
  "inputSchema": {
    "type": "object",
    "properties": {
      "path": { "type": "string",  "description": "The absolute path of the file to open." },
      "line": { "type": "integer", "minimum": 1,
                "description": "The line to put them on, counted from one. Leave it out for the top of the file." }
    },
    "required": ["path"]
  }
}
```

## Description (after)

> Open a file in the app's files pane, beside the conversation, at the line you name. Use it
> when the person needs to be looking at something to follow what you are saying: the
> function you are about to change, the config that explains the failure, the test that is
> wrong.
>
> A Markdown file opens as a page the person reads and can type on, and the page follows
> your edits: each time you change the file, the page shows what changed and goes there. So
> when you begin writing a document, show it once, at the start, and then just write. A line
> you name on a Markdown file takes them to the part of the page that holds it. For a
> diagram or a graph, write an SVG file beside the document and reference it as an image.
>
> It does not edit, select or run anything. The file has to be inside the folders this agent
> was given, and has to exist.
>
> Not for every file you touch. Files you changed are already marked in that pane, and every
> edit you make is already in the conversation, so calling this on each one takes the
> person's window away from them for nothing. One file, when there is one worth looking at.

The second paragraph is the whole of the change. The first, third and fourth are today's.

## Result text

Unchanged: `notes.md is open at line 40 in the files pane beside this conversation. Say
what they are looking at; do not paste the file back.` The daemon does not read the file to
find a passage; the page does that, so a line past the end is the page's last passage and
the agent is not told otherwise.

## Refusals

Unchanged: not absolute → not shown; outside the agent's folders → the scope's refusal
sentence; not there → "There is no file at …"; a folder → "… is a folder"; no window →
"No window is open, so there was nowhere to show it."

## Briefing (conditional on Slice B's measurement)

If no runtime calls `show_file` when it starts a document, this sentence is added to
`Briefing`, after the suggestions sentence:

> When you start writing a Markdown document for me, call `show_file` on it once, first, so
> I can watch it take shape.

That is a sentence in a prompt, not a tool, and the measurement decides whether it is
spent.
