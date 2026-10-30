// A merge request's state as pills: on the Merge requests list and on its page. The github
// server's page shapes (#1341), in GitLab's words: a pipeline, not checks.
const MR_CHECKS = { passing: "Pipeline passed", failing: "Pipeline failed", running: "Pipeline running", none: "No pipeline", skipped: "Skipped" };
const MR_JOBS = { passing: "Passed", failing: "Failed", running: "Running", none: "Not run", skipped: "Skipped" };
const MR_REVIEWS = { approved: "Approved", review_required: "Approval needed" };
const mrPills = (ui, mr) => {
  const pill = (kind, text, title) => ui.el("span", { className: "pill " + kind, textContent: text, title: title || "" });
  const out = [];
  if (mr.state && mr.state !== "open") out.push(pill(mr.state, mr.state === "merged" ? "Merged" : "Closed"));
  if (mr.draft) out.push(pill("none", "Draft"));
  const checks = MR_CHECKS[mr.checks] ? mr.checks : "none";
  out.push(pill(checks, MR_CHECKS[checks], "Its head commit's pipeline"));
  if (mr.conflicts) out.push(pill("conflicts", "Conflicts", "Conflicts with its target branch: rebase it"));
  if (mr.review && MR_REVIEWS[mr.review]) out.push(pill(mr.review, MR_REVIEWS[mr.review], "Approvals"));
  if (mr.autoMerge && (mr.state || "open") === "open") out.push(pill("auto", "Auto-merge on", "Merges once its pipeline succeeds"));
  return out;
};

// A merge request's page: mrPage(ui, project, back) gives { show(number), draw(result) }. ui
// is the bridge; project() the project; with back, a ‹ Merge requests button calls it.
const mrPage = (ui, project, back) => {
  const { el, link, button, request, log } = ui;
  const root = document.getElementById("page");
  let mr = null, lineage = null, tab = "conversation", confirming = null, line = { text: "", error: false };
  // Kept across redraws, so a tab or a refresh doesn't lose what was typed, or a log shown.
  const text = el("textarea", { placeholder: "A comment, or what the agent is to do…", rows: 3 });
  const logs = new Map();

  const say = (words, error) => {
    line = { text: words, error: !!error };
    const s = root.querySelector(".status");
    if (s) { s.textContent = words; s.className = "status " + (error ? "error" : "muted"); }
    ui.size();
  };
  const call = (tool, args) => ui.call(tool, Object.assign({ project: project() || mr.project, number: mr.number }, args || {}));
  const fetchMR = (number) => ui.call("show_merge_request", { project: project(), number });
  const who = (c) => {
    const out = [el("span", { textContent: `${c.author || "someone"} · ${ui.ago(c.at)}` })];
    if (c.bot) out.push(el("span", { className: "pill", textContent: "bot", title: c.author + " is a bot" }));
    if (c.url) out.push(link("↗", c.url, { title: "Open it on GitLab" }));
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
      who({ author: mr.author, at: mr.createdAt }),
      body(mr.body, "description") || el("p", { className: "body muted", textContent: "No description." }),
    ])];
    (mr.comments || []).forEach((c, i) => notes.push(el("div", { className: "note" }, [who(c), body(c.body, "c" + i)])));
    return notes;
  };

  // Discussions on lines of code, a thread each, by file and line.
  const threads = () => {
    const list = (mr.threads || []).map((t, n) => {
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
    const rows = (mr.files || []).map((f) => {
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
  // page's (#1472). A host without it gets GitLab's.
  const showDiff = async (path) => {
    say("Loading the diff…");
    let diff;
    try { diff = await ui.call("show_merge_request_diff", { project: project() || mr.project, number: mr.number }); }
    catch (e) { say("Couldn't load the diff: " + e.message, true); return; }
    try {
      await request("agents/open-diff", { title: `!${mr.number} ${mr.title}`, url: diff.url, files: diff.files, cut: !!diff.cut,
        ...(path ? { path } : {}) });
      say("");
    } catch (e) {
      if (e.code === -32601) { say("This app shows no diff: it opens on GitLab."); ui.openLink(diff.url); return; }
      say("Couldn't show the diff: " + e.message, true);
    }
  };

  const pipeline = () => {
    const rows = (mr.checkRuns || []).map((c) => {
      const kind = MR_JOBS[c.state] ? c.state : "none";
      const key = c.pipelineId + "/" + c.job;
      const shown = logs.get(key);
      const action = c.state === "failing"
        ? button(shown ? "Hide Log" : "Show Log", () => toggleLog(c, key), { title: "The end of the job's log" }) : el("span");
      return el("li", {}, [
        el("span", { className: "pill " + kind, textContent: MR_JOBS[kind] }),
        c.url ? link(c.name, c.url) : el("span", { textContent: c.name }),
        action,
        shown ? el("pre", { className: "log", textContent: shown }) : null,
      ]);
    });
    const out = [el("ul", { className: "checks" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No pipeline." })])];
    if (mr.checks === "failing" && mr.failedPipelineId && mr.state === "open") {
      out.push(el("div", { className: "actions" }, [button("Retry Failed Jobs", async (event) => {
        event.target.disabled = true;
        try { await call("retry_pipeline", { pipelineId: mr.failedPipelineId }); say("The failed jobs run again."); refresh(); }
        catch (e) { event.target.disabled = false; say("Couldn't retry: " + e.message, true); }
      })]));
    }
    return out;
  };
  const toggleLog = async (c, key) => {
    if (logs.has(key)) { logs.delete(key); draw(); return; }
    logs.set(key, "Loading the log…"); draw();
    try {
      const result = await ui.request("tools/call", { name: "failed_log",
        arguments: { project: project() || mr.project, pipelineId: c.pipelineId, job: c.job } });
      logs.set(key, result && !result.isError ? ui.errorText(result) : "Couldn't read the log: " + ui.errorText(result));
    } catch (e) { logs.set(key, "Couldn't read the log: " + e.message); }
    if (tab === "pipeline") draw();
  };

  const actions = () => {
    if (mr.state !== "open") return [];
    const comment = button("Comment", async () => {
      if (!text.value.trim()) { say("Write a comment first.", true); return; }
      comment.disabled = true;
      try { await call("comment_on_merge_request", { body: text.value }); text.value = ""; say("Commented."); refresh(); }
      catch (e) { say("Couldn't comment: " + e.message, true); }
      finally { comment.disabled = false; }
    });
    const agent = button("Ask an Agent", () => askAgent(text.value),
      { title: `Send it to the agent working on ${mr.branch}, or start one there; you say Send or Start first` });
    // Someone else's merge request only: an author's own approval seldom counts.
    const others = mr.viewer && mr.author && mr.viewer.toLowerCase() !== mr.author.toLowerCase();
    const approve = others ? button("Approve", async (event) => {
      event.target.disabled = true;
      try { await call("approve_merge_request", { sha: mr.headSha }); say(`Approved !${mr.number}.`); log(`approve !${mr.number}`); refresh(); }
      catch (e) { event.target.disabled = false; say("Couldn't approve: " + e.message, true); }
    }) : null;
    const blocked = mr.conflicts ? "It conflicts with its target branch: rebase it first" : mr.draft ? "A draft can't be merged" : "";
    const merge = button("Merge", () => { confirming = "merge"; draw(); }, { className: "primary", disabled: !!blocked, title: blocked });
    const auto = mr.autoMerge || mr.checks !== "running" ? null
      : button("Auto-merge", () => { confirming = "auto"; draw(); }, { disabled: !!blocked, title: blocked || "Merge it once its pipeline succeeds" });
    const out = [text, el("div", { className: "actions" }, [comment, agent, approve, el("span", { className: "grow" }), auto, merge])];
    if (confirming) {
      const isAuto = confirming === "auto";
      const how = mr.squash ? "Squash and merge" : "Merge";
      const words = isAuto ? `Turn on auto-merge for !${mr.number}? GitLab merges it into ${mr.base} once its pipeline succeeds, then deletes ${mr.branch}.`
        : `${how} !${mr.number} into ${mr.base} and delete ${mr.branch}?` + (mr.checks === "failing" ? " Its pipeline failed." : "");
      const yes = button(isAuto ? "Turn On Auto-merge" : "Merge", async () => {
        yes.disabled = true;
        try {
          const r = await call("merge_merge_request", { auto: isAuto, squash: !!mr.squash, sha: mr.headSha });
          confirming = null;
          say(r.auto ? "Auto-merge is on: it merges once its pipeline succeeds." : `Merged !${mr.number}.`);
          log(`merge !${mr.number}${isAuto ? " (auto)" : ""}`);
          refresh();
        } catch (e) { yes.disabled = false; say("Couldn't merge: " + e.message, true); }
      }, { className: "primary" });
      out.push(el("div", { className: "confirm" }, [el("span", { className: "grow", textContent: words }), yes,
        button("Cancel", () => { confirming = null; draw(); })]));
    }
    return out;
  };

  // To the session working on the merge request's branch, as the person's own message: the
  // host asks them first (agents/message-agent). With no such session, the new-agent form on
  // the branch.
  const askAgent = async (note) => {
    const n = mr.number, where = project() || mr.project, failing = mr.checks === "failing";
    const what = [failing ? "its failed pipeline" + (mr.failedPipelineId ? ` (failed_log pipelineId ${mr.failedPipelineId})` : "") : "",
      mr.conflicts ? `its conflict with ${mr.base}` : "", (mr.threads || []).some((t) => !t.resolved) ? "its open discussions" : ""].filter(Boolean);
    const words = `Work on GitLab merge request !${n} in ${where} (get_merge_request with project ${where} and number ${n}) on ${mr.branch}`
      + (what.length ? ": " + what.join(", ") : "") + "."
      + (note.trim() ? "\n\n" + note.trim() : "") + "\n\nPush to the same branch.";
    say("Say Send under the view…");
    try { await request("agents/message-agent", { branch: mr.branch, text: words }); say("Sent to the agent."); return; }
    catch (e) { if (e.code !== -32001) { say(e.message, true); return; } }
    try {
      await request("agents/start-agent", { prompt: words, labels: ["!" + n], branch: mr.branch });
      say(`No agent works on ${mr.branch}: a new one is ready to start.`);
    } catch (e) { say("Couldn't open a new agent on " + mr.branch + ": " + e.message, true); log("start-agent refused: " + e.message, "warning"); }
  };

  const draw = () => {
    if (!mr) return;
    const head = [];
    if (back) head.push(button("‹ Merge requests", back));
    head.push(el("span", { className: "grow" }), link("GitLab ↗", mr.url), button("Refresh", refresh));
    const open = (mr.threads || []).filter((t) => !t.resolved).length;
    const tabs = [["conversation", "Conversation", (mr.comments || []).length], ["review", "Discussions on lines", open],
      ["files", "Files", mr.filesTotal || (mr.files || []).length], ["pipeline", "Pipeline", (mr.checkRuns || []).length], ["lineage", "Lineage", 0]]
      .map(([id, words, count]) => button(count ? `${words} ${count}` : words, () => { tab = id; draw(); }, { className: tab === id ? "chosen" : "" }));
    const panel = tab === "lineage" ? [lineage || (lineage = lineageSection(ui, mr.url))] : tab === "files" ? files() : tab === "pipeline" ? pipeline() : tab === "review" ? threads() : conversation();
    root.replaceChildren(
      el("div", { className: "bar" }, head),
      el("div", { className: "bar" }, [link(`!${mr.number}`, mr.url), el("h2", { className: "grow", textContent: mr.title })]),
      el("div", { className: "pills" }, mrPills(ui, mr)),
      el("div", { className: "branch", textContent: `${mr.branch} → ${mr.base} · ${mr.author || "someone"} · ${ui.ago(mr.createdAt)} · +${mr.additions} −${mr.deletions}` }),
      el("div", { className: "tabs" }, tabs),
      ...panel.filter(Boolean),
      ...actions(),
      el("div", { className: "status " + (line.error ? "error" : "muted"), textContent: line.text }),
    );
    ui.size();
  };
  const refresh = async () => {
    if (!mr) return;
    try { mr = await fetchMR(mr.number); lineage = null; draw(); }
    catch (e) { say("Couldn't refresh: " + e.message, true); }
  };
  return {
    show: async (number) => {
      mr = null; lineage = null; tab = "conversation"; confirming = null; line = { text: "", error: false }; text.value = ""; logs.clear(); opened.clear();
      root.replaceChildren(el("div", { className: "muted", textContent: `Loading !${number}…` }));
      ui.size();
      try { mr = await fetchMR(number); draw(); }
      catch (e) {
        root.replaceChildren(...(back ? [button("‹ Merge requests", back)] : []), el("div", { className: "error", textContent: `Couldn't show !${number}: ` + e.message }));
        ui.size();
      }
    },
    draw: (result) => {
      const detail = ui.data(result);
      if (!detail || !detail.number) {
        root.replaceChildren(el("div", { className: "error", textContent: "Couldn't show the merge request: " + ui.errorText(result) }));
        ui.size();
        return;
      }
      mr = detail; lineage = null; draw();
    },
  };
};
