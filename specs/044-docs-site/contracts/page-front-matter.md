# Contract: A Docs Page

Every `.md` file under `docs/` starts with front matter, then one `# ` title.

```markdown
---
diataxis: how-to              # tutorial | how-to | reference | explanation | index
devices: [mac, iphone, ipad]  # optional; mac | iphone | ipad | server
description: Add an SSH server so agents can work on a Linux box.   # optional
---

# Add a Linux server
```

## Shape by section

**tutorial**

```markdown
# Your first agent
What you'll have at the end: one sentence and a picture.
## Before you start
## 1. <step>          … each step ends with "You should see …" (and usually a picture)
## Where next         ← required (checked)
```

**how-to**

```markdown
# <the task, as a verb phrase>
## Before you start   ← links to what it assumes
## Steps              ← one numbered list; device differences inline ("On iPhone, …")
## If it doesn't work ← optional
```

**reference**

```markdown
# <the thing>
One sentence on what this page lists.
<one table or definition list; every entry has the same columns>
## See also
```

**explanation**

```markdown
# <the idea>
<prose under ## headings; no ordered lists (checked)>
## Related
```

**index**

Allowed only in `docs/index.md` and `docs/<section>/index.md`. An index says in a sentence what the section is
for and lists its pages in order.
