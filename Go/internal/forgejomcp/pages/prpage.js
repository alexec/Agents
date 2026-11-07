// A pull request's state as pills: on the Pull requests list and on its page. The gitlab
// server's page shapes (#1631), in Forgejo's words: its head's commit statuses are its checks.
const PR_CHECKS = { passing: "Checks passed", failing: "Checks failed", running: "Checks running", none: "No checks" };
const PR_RUNS = { passing: "Passed", failing: "Failed", running: "Running", none: "Not run" };
const PR_REVIEWS = { approved: "Approved", changes_requested: "Changes requested", review_required: "Review required" };
const prPills = (ui, pr) => {
  const pill = (kind, text, title) => ui.el("span", { className: "pill " + kind, textContent: text, title: title || "" });
  const out = [];
  if (pr.state && pr.state !== "open") out.push(pill(pr.state, pr.state === "merged" ? "Merged" : "Closed"));
  if (pr.draft) out.push(pill("none", "Draft"));
  const checks = PR_CHECKS[pr.checks] ? pr.checks : "none";
  out.push(pill(checks, PR_CHECKS[checks], "Its head commit's checks"));
  if (pr.conflicts) out.push(pill("conflicts", "Conflicts", "Conflicts with its target branch: rebase it"));
  if (pr.review && PR_REVIEWS[pr.review]) out.push(pill(pr.review, PR_REVIEWS[pr.review], "Reviews"));
  return out;
};

// A pull request's page: prPage(ui, repo, back) gives { show(number), draw(result) }. ui is
// the bridge; repo() the repository; with back, a ‹ Pull requests button calls it.
const prPage = (ui, repo, back) => {
  const { el, link, button, request, log } = ui;
  const root = document.getElementById("page");
  let pr = null, lineage = null, tab = "conversation", confirming = null, line = { text: "", error: false };
  // Kept across redraws, so a tab or a refresh doesn't lose what was typed, or a log shown.
  const text = el("textarea", { placeholder: "A comment, or what the agent is to do…", rows: 3 });
  const logs = new Map();

  const say = (words, error) => {
    line = { text: words, error: !!error };
    const s = root.querySelector(".status");
    if (s) { s.textContent = words; s.className = "status " + (error ? "error" : "muted"); }
    ui.size();
  };
  const call = (tool, args) => ui.call(tool, Object.assign({ repo: repo() || pr.repo, number: pr.number }, args || {}));
  const fetchPR = (number) => ui.call("show_pull_request", { repo: repo(), number });
  const who = (c) => {
    const out = [el("span", { textContent: `${c.author || "someone"} · ${ui.ago(c.at)}` })];
    if (c.bot) out.push(el("span", { className: "pill", textContent: "bot", title: c.author + " is a bot" }));
    if (c.url) out.push(link("↗", c.url, { title: "Open it on Forgejo" }));
    return el("div", { className: "who" }, out);
  };

  // A body as words: Markdown as written, without HTML comments and tags. A long one is
  // clipped, with Show All.
  const opened = new Set();
  const words = (text) => (text || "").replace(/<!--[\s\S]*?-->/g, "").replace(/<\/?[a-zA-Z][^>]*>/g, "")
    .replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/\n[ \t]*\n(\s*\n)+/g, "\n\n").trim();
  const body = (text, key) => {
    const all = words(text);
    if (!all) return null;
    const lines = all.split("\n");
    if (lines.length <= 14 || opened.has(key)) return el("p", { className: "body", textContent: all });
    const more = button(`Show All (${lines.length} lines)`, () => { opened.add(key); draw(); }, { className: "plain" });
    return el("div", {}, [el("p", { className: "body", textContent: lines.slice(0, 12).join("\n") + "\n…" }), more]);
  };
  const conversation = () => {
    const notes = [el("div", { className: "note" }, [
      who({ author: pr.author, at: pr.createdAt }),
      body(pr.body, "description") || el("p", { className: "body muted", textContent: "No description." }),
    ])];
    (pr.comments || []).forEach((c, i) => notes.push(el("div", { className: "note" }, [who(c), body(c.body, "c" + i)])));
    return notes;
  };

  // Comments on lines of code, a thread each, by file and line.
  const threads = () => {
    const list = (pr.threads || []).map((t, n) => {
      const [first, ...replies] = t.comments || [];
      const where = t.path + (t.line ? ":" + t.line : "") + (t.resolved ? " · resolved" : "");
      return el("div", { className: "note" + (t.resolved ? " resolved" : "") }, [
        el("div", { className: "path", textContent: where }),
        first ? who(first) : null,
        first ? body(first.body, "t" + n) : null,
        ...replies.map((r, i) => el("div", { className: "reply" }, [who(r), body(r.body, "r" + n + "." + i)])),
      ]);
    });
    return list.length ? list : [el("div", { className: "muted", textContent: "No comments on lines of code." })];
  };

  const files = () => {
    const rows = (pr.files || []).map((f) => {
      const name = el("a", { className: "path", textContent: f.path + (f.change && f.change !== "modified" ? ` (${f.change})` : ""),
        href: "#", title: "Show this file's diff" });
      name.onclick = (event) => { event.preventDefault(); showDiff(f.path); };
      return el("li", {}, [name,
        el("span", { className: "add", textContent: "+" + f.additions }),
        el("span", { className: "del", textContent: "−" + f.deletions })]);
    });
    const show = rows.length ? el("div", { className: "actions" }, [button("Show Diff", () => showDiff(null), { title: "Every file's changed lines, in the app" })]) : null;
    return [show, el("ul", { className: "files" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No files changed." })])];
  };
  // The diff is drawn by the app, not here (agents/open-diff): its own diff, as the Review
  // page's (#1472). A host without it gets Forgejo's.
  const showDiff = async (path) => {
    say("Loading the diff…");
    let diff;
    try { diff = await ui.call("show_pull_request_diff", { repo: repo() || pr.repo, number: pr.number }); }
    catch (e) { say("Couldn't load the diff: " + e.message, true); return; }
    try {
      await request("agents/open-diff", { title: `#${pr.number} ${pr.title}`, url: diff.url, files: diff.files, cut: !!diff.cut,
        ...(path ? { path } : {}) });
      say("");
    } catch (e) {
      if (e.code === -32601) { say("This app shows no diff: it opens on Forgejo."); ui.openLink(diff.url); return; }
      say("Couldn't show the diff: " + e.message, true);
    }
  };

  // The head's commit statuses; a failed Forgejo Actions run's log is failed_log's.
  const checks = () => {
    const rows = (pr.checkRuns || []).map((c) => {
      const kind = PR_RUNS[c.state] ? c.state : "none";
      const key = c.runId + "/" + c.name;
      const shown = logs.get(key);
      const action = c.state === "failing" && c.runId
        ? button(shown ? "Hide Log" : "Show Log", () => toggleLog(c, key), { title: "The end of the run's failed jobs' logs" }) : el("span");
      return el("li", {}, [
        el("span", { className: "pill " + kind, textContent: PR_RUNS[kind] }),
        c.url ? link(c.name, c.url) : el("span", { textContent: c.name, title: c.description || "" }),
        action,
        shown ? el("pre", { className: "log", textContent: shown }) : null,
      ]);
    });
    const out = [el("ul", { className: "checks" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No checks." })])];
    if (pr.checks === "failing" && pr.failedRunId && pr.state === "open") {
      out.push(el("div", { className: "actions" }, [button("Retry Failed Jobs", async (event) => {
        event.target.disabled = true;
        try { await ui.call("retry_pipeline", { repo: repo() || pr.repo, runId: pr.failedRunId }); say("The failed jobs run again."); refresh(); }
        catch (e) { event.target.disabled = false; say("Couldn't retry: " + e.message, true); }
      })]));
    }
    return out;
  };
  const toggleLog = async (c, key) => {
    if (logs.has(key)) { logs.delete(key); draw(); return; }
    logs.set(key, "Loading the log…"); draw();
    try {
      const result = await ui.request("tools/call", { name: "failed_log", arguments: { repo: repo() || pr.repo, runId: c.runId } });
      logs.set(key, result && !result.isError ? ui.errorText(result) : "Couldn't read the log: " + ui.errorText(result));
    } catch (e) { logs.set(key, "Couldn't read the log: " + e.message); }
    if (tab === "checks") draw();
  };

  const actions = () => {
    if (pr.state !== "open") return [];
    const comment = button("Comment", async () => {
      if (!text.value.trim()) { say("Write a comment first.", true); return; }
      comment.disabled = true;
      try { await call("comment_on_pull_request", { body: text.value }); text.value = ""; say("Commented."); refresh(); }
      catch (e) { say("Couldn't comment: " + e.message, true); }
      finally { comment.disabled = false; }
    });
    const agent = button("Ask an Agent", () => askAgent(text.value),
      { title: `Send it to the agent working on ${pr.branch}, or start one there; you say Send or Start first` });
    // Someone else's pull request only: Forgejo refuses an author's own approval.
    const others = pr.viewer && pr.author && pr.viewer.toLowerCase() !== pr.author.toLowerCase();
    const approve = others ? button("Approve", async (event) => {
      event.target.disabled = true;
      try { await call("approve_pull_request", { sha: pr.headSha }); say(`Approved #${pr.number}.`); log(`approve #${pr.number}`); refresh(); }
      catch (e) { event.target.disabled = false; say("Couldn't approve: " + e.message, true); }
    }) : null;
    const blocked = pr.conflicts ? "It conflicts with its target branch: rebase it first" : pr.draft ? "A draft can't be merged" : "";
    const merge = button("Merge", () => { confirming = "merge"; draw(); }, { className: "primary", disabled: !!blocked, title: blocked });
    const auto = pr.checks !== "running" ? null
      : button("Auto-merge", () => { confirming = "auto"; draw(); }, { disabled: !!blocked, title: blocked || "Merge it once its checks succeed" });
    const out = [text, el("div", { className: "actions" }, [comment, agent, approve, el("span", { className: "grow" }), auto, merge])];
    if (confirming) {
      const isAuto = confirming === "auto";
      const how = pr.squash ? "Squash and merge" : "Merge";
      const words = isAuto ? `Turn on auto-merge for #${pr.number}? Forgejo merges it into ${pr.base} once its checks succeed, then deletes ${pr.branch}.`
        : `${how} #${pr.number} into ${pr.base} and delete ${pr.branch}?` + (pr.checks === "failing" ? " Its checks failed." : "");
      const yes = button(isAuto ? "Turn On Auto-merge" : "Merge", async () => {
        yes.disabled = true;
        try {
          const r = await call("merge_pull_request", { auto: isAuto, squash: !!pr.squash, sha: pr.headSha });
          confirming = null;
          say(r.auto ? "Auto-merge is on: it merges once its checks succeed." : `Merged #${pr.number}.`);
          log(`merge #${pr.number}${isAuto ? " (auto)" : ""}`);
          refresh();
        } catch (e) { yes.disabled = false; say("Couldn't merge: " + e.message, true); }
      }, { className: "primary" });
      out.push(el("div", { className: "confirm" }, [el("span", { className: "grow", textContent: words }), yes,
        button("Cancel", () => { confirming = null; draw(); })]));
    }
    return out;
  };

  // To the session working on the pull request's branch, as the person's own message: the
  // host asks them first (agents/message-agent). With no such session, the new-agent form on
  // the branch.
  const askAgent = async (note) => {
    const n = pr.number, where = repo() || pr.repo, failing = pr.checks === "failing";
    const what = [failing ? "its failed checks" + (pr.failedRunId ? ` (failed_log runId ${pr.failedRunId})` : "") : "",
      pr.conflicts ? `its conflict with ${pr.base}` : "", (pr.threads || []).some((t) => !t.resolved) ? "its open line comments" : ""].filter(Boolean);
    const words = `Work on Forgejo pull request #${n} in ${where} (get_pull_request with repo ${where} and number ${n}) on ${pr.branch}`
      + (what.length ? ": " + what.join(", ") : "") + "."
      + (note.trim() ? "\n\n" + note.trim() : "") + "\n\nPush to the same branch.";
    say("Say Send under the view…");
    try { await request("agents/message-agent", { branch: pr.branch, text: words }); say("Sent to the agent."); return; }
    catch (e) { if (e.code !== -32001) { say(e.message, true); return; } }
    try {
      await request("agents/start-agent", { prompt: words, labels: ["#" + n], branch: pr.branch });
      say(`No agent works on ${pr.branch}: a new one is ready to start.`);
    } catch (e) { say("Couldn't open a new agent on " + pr.branch + ": " + e.message, true); log("start-agent refused: " + e.message, "warning"); }
  };

  const draw = () => {
    if (!pr) return;
    const head = [];
    if (back) head.push(button("‹ Pull requests", back));
    head.push(el("span", { className: "grow" }), link("Forgejo ↗", pr.url), button("Refresh", refresh));
    const open = (pr.threads || []).filter((t) => !t.resolved).length;
    const tabs = [["conversation", "Conversation", (pr.comments || []).length], ["review", "Line comments", open],
      ["files", "Files", pr.filesTotal || (pr.files || []).length], ["checks", "Checks", (pr.checkRuns || []).length], ["lineage", "Lineage", 0]]
      .map(([id, words, count]) => button(count ? `${words} ${count}` : words, () => { tab = id; draw(); }, { className: tab === id ? "chosen" : "" }));
    const panel = tab === "lineage" ? [lineage || (lineage = lineageSection(ui, pr.url))] : tab === "files" ? files() : tab === "checks" ? checks() : tab === "review" ? threads() : conversation();
    root.replaceChildren(
      el("div", { className: "bar" }, head),
      el("div", { className: "bar" }, [link(`#${pr.number}`, pr.url), el("h2", { className: "grow", textContent: pr.title })]),
      el("div", { className: "pills" }, prPills(ui, pr)),
      el("div", { className: "branch", textContent: `${pr.branch} → ${pr.base} · ${pr.author || "someone"} · ${ui.ago(pr.createdAt)} · +${pr.additions} −${pr.deletions}` }),
      el("div", { className: "tabs" }, tabs),
      ...panel.filter(Boolean),
      ...actions(),
      el("div", { className: "status " + (line.error ? "error" : "muted"), textContent: line.text }),
    );
    ui.size();
  };
  const refresh = async () => {
    if (!pr) return;
    try { pr = await fetchPR(pr.number); lineage = null; draw(); }
    catch (e) { say("Couldn't refresh: " + e.message, true); }
  };
  return {
    show: async (number) => {
      pr = null; lineage = null; tab = "conversation"; confirming = null; line = { text: "", error: false }; text.value = ""; logs.clear(); opened.clear();
      root.replaceChildren(el("div", { className: "muted", textContent: `Loading #${number}…` }));
      ui.size();
      try { pr = await fetchPR(number); draw(); }
      catch (e) {
        root.replaceChildren(...(back ? [button("‹ Pull requests", back)] : []), el("div", { className: "error", textContent: `Couldn't show #${number}: ` + e.message }));
        ui.size();
      }
    },
    draw: (result) => {
      const detail = ui.data(result);
      if (!detail || !detail.number) {
        root.replaceChildren(el("div", { className: "error", textContent: "Couldn't show the pull request: " + ui.errorText(result) }));
        ui.size();
        return;
      }
      pr = detail; lineage = null; draw();
    },
  };
};
