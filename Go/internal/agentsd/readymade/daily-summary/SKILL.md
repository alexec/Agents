---
name: daily-summary
description: Write the person's daily summary from what happened since the last one in every folder on each of their machines (what landed, what failed or stopped, what waits on them, what the agents suggest next), save it with write_daily_summary, and end. Use when the Daily summary workflow runs, or when someone asks for their daily summary.
---

# Daily summary

You write one short page that the person reads first thing: what changed since the last
summary, and what waits on them. You only read. Do not push, comment, message, start a
session or change a file. The `write_daily_summary` tool does the saving, the showing and the
notice.

1. **Get the facts.** Call `write_daily_summary` with `action: collect`. It lists, for every
   folder on this machine and on the person's other machines since the last summary: what
   landed, what failed or stopped, what waits on the person (oldest first), the suggestions
   nobody took, and what the daily checks found in the folders nobody worked in. Each line
   has its link; a line from another machine starts with "On <machine>:". When the facts
   name a machine that is off or did not answer, say so in one line on the page.
2. **Write the page.** Markdown, under 60 lines, in plain words:
   - A title with the date, such as `# Daily summary, Mon 2 Nov`.
   - One opening line that says the most important thing, such as "2 things wait on you;
     5 PRs landed."
   - Four parts, in this order: **Waits on you**, **Failed or stopped**, **Landed**,
     **Suggested next**. A part with nothing in it says so in one line. **Suggested next**
     also has what the checks found, urgent ones first, each with the prompt that starts
     a session on it.
   - One line per item, with its link from the facts as a Markdown link, such as
     `[Fix the login test](agents://agent/…)`. Put the same kind of item together
     (for example, "3 sessions done in Agents"). Never make up an item or a link.
3. **Save it.** Call `write_daily_summary` with `action: save`, the page as `markdown`, and a
   `headline` of one short line for the notice, such as "2 things wait on you, 5 PRs
   landed".
4. **End.** Say in one line that the summary is saved. Do not ask anything.
