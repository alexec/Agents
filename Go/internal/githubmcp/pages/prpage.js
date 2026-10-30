// A pull request's state as pills: on the Pull requests list and on its page.
const PR_CHECKS = { passing: "Passing", failing: "Failing", running: "Running", none: "No checks", skipped: "Skipped" };
const PR_REVIEWS = { approved: "Approved", changes_requested: "Changes requested", review_required: "Review required", commented: "Commented" };
// CodeRabbit's status (#1344): on the list a word, on a page its block's status.
const PR_RABBIT = { reviewing: ["running", "CodeRabbit reviewing"], reviewed: ["passing", "CodeRabbit reviewed"], failed: ["failing", "CodeRabbit failed"] };
const rabbitStatus = (pr) => typeof pr.codeRabbit === "string" ? pr.codeRabbit : (pr.codeRabbit && pr.codeRabbit.status) || "";
const prPills = (ui, pr) => {
  const pill = (kind, text, title) => ui.el("span", { className: "pill " + kind, textContent: text, title: title || "" });
  const out = [];
  if (pr.state && pr.state !== "open") out.push(pill(pr.state, pr.state === "merged" ? "Merged" : "Closed"));
  if (pr.draft) out.push(pill("none", "Draft"));
  const checks = PR_CHECKS[pr.checks] ? pr.checks : "none";
  out.push(pill(checks, PR_CHECKS[checks], "Checks"));
  if (pr.conflicts) out.push(pill("conflicts", "Conflicts", "Conflicts with its base: rebase it"));
  if (pr.review && PR_REVIEWS[pr.review]) out.push(pill(pr.review, PR_REVIEWS[pr.review], "Review"));
  const rabbit = PR_RABBIT[rabbitStatus(pr)];
  if (rabbit) out.push(pill(rabbit[0], rabbit[1], "CodeRabbit's review of the last commit"));
  if (pr.autoMerge && (pr.state || "open") === "open") out.push(pill("auto", "Auto-merge on", "Merges once its checks pass"));
  return out;
};

// A pull request's page: prPage(ui, repo, back) gives { show(number), draw(result) }. ui is
// the bridge; repo() the repo; with back, a ‹ Pull requests button calls it.
const prPage = (ui, repo, back) => {
  const { el, link, button, request, log } = ui;
  const root = document.getElementById("page");
  let pr = null, lineage = null, tab = "conversation", confirming = null, line = { text: "", error: false };
  // Kept across redraws, so a tab or a refresh doesn't lose what was typed, or a log shown.
  const text = el("textarea", { placeholder: "A comment, a review's words, or what the agent is to do…", rows: 3 });
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
    // An app's words are marked: CodeRabbit's by its name (#1344), another's as a bot.
    if (c.app) out.push(el("span", { className: "pill app", textContent: c.app, title: `${c.app}'s GitHub App wrote it` }));
    else if (c.bot) out.push(el("span", { className: "pill", textContent: "bot", title: c.author + " is an app" }));
    if (c.review && PR_REVIEWS[c.review]) out.push(el("span", { className: "pill " + c.review, textContent: PR_REVIEWS[c.review] }));
    if (c.url) out.push(link("↗", c.url, { title: "Open it on GitHub" }));
    return el("div", { className: "who" }, out);
  };

  // A body as words: Markdown as written, without the HTML comments and tags apps such as
  // CodeRabbit put in. A long one is clipped, with Show All.
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
  // CodeRabbit's block (#1344): its status and review, its summary (edited after each review),
  // and the commands it takes, posted as the person.
  const rabbitOpen = () => (pr.threads || []).filter((t) => !t.resolved && t.comments && t.comments[0] && t.comments[0].app === "CodeRabbit").length;
  const command = (tool, words, done, args) => {
    const b = button(words, async () => {
      b.disabled = true;
      try { await call(tool, args); say(done); log(`${tool} #${pr.number}`); refresh(); }
      catch (e) { b.disabled = false; say("Couldn't ask CodeRabbit: " + e.message, true); }
    });
    return b;
  };
  const codeRabbit = () => {
    const r = pr.codeRabbit;
    if (!r) return null;
    const status = PR_RABBIT[r.status];
    const head = [el("span", { className: "pill app", textContent: "CodeRabbit" }),
      status ? el("span", { className: "pill " + status[0], textContent: status[1].replace("CodeRabbit ", "") }) : null,
      r.review && PR_REVIEWS[r.review] ? el("span", { className: "pill " + r.review, textContent: PR_REVIEWS[r.review] }) : null,
      r.reviewedAt ? el("span", { textContent: ui.ago(r.reviewedAt) }) : null,
      el("span", { className: "grow" }),
      r.reviewUrl ? link("Review ↗", r.reviewUrl, { title: "Its last review, on GitHub" }) : null,
      r.summaryUrl ? link("Summary ↗", r.summaryUrl, { title: "Its summary, on GitHub" }) : null];
    const open = rabbitOpen();
    const actions = pr.state === "open" ? el("div", { className: "actions" }, [
      // On a commit it has reviewed, CodeRabbit does only a full review again.
      r.status === "reviewed" ? null : command("coderabbit_review", "Ask CodeRabbit Again", "Asked CodeRabbit to review the new changes."),
      command("coderabbit_review", "Full Review", "Asked CodeRabbit to review every file.", { full: true }),
      open ? command("coderabbit_resolve", `Resolve Its Comments (${open})`, "Asked CodeRabbit to resolve its comments.") : null,
    ]) : null;
    return el("div", { className: "note rabbit" }, [el("div", { className: "who" }, head),
      body(r.summary, "summary") || el("p", { className: "body muted", textContent: "No summary yet." }), actions]);
  };
  const conversation = () => {
    const notes = [el("div", { className: "note" }, [
      who({ author: pr.author, at: pr.createdAt }),
      body(pr.body, "description") || el("p", { className: "body muted", textContent: "No description." }),
    ]), codeRabbit()];
    (pr.comments || []).forEach((c, i) => {
      notes.push(el("div", { className: "note" }, [who(c), body(c.body, "c" + i)]));
    });
    return notes;
  };

  // Comments on lines of code, a thread each, by file and line.
  const threads = () => {
    const list = (pr.threads || []).map((t) => {
      const [first, ...replies] = t.comments || [];
      const where = t.path + (t.line ? ":" + t.line : "") + (t.outdated ? " · outdated" : "") + (t.resolved ? " · resolved" : "");
      return el("div", { className: "note" + (t.resolved ? " resolved" : "") }, [
        el("div", { className: "path", textContent: where }),
        first ? who(first) : null,
        first ? body(first.body, "t" + t.path + t.line) : null,
        ...replies.map((r, i) => el("div", { className: "reply" }, [who(r), body(r.body, "r" + t.path + t.line + i)])),
        // CodeRabbit's thread is answered in place, with the box's words (#1344).
        first && first.app === "CodeRabbit" && first.id && pr.state === "open" && !t.resolved
          ? el("div", { className: "actions" }, [button("Reply to CodeRabbit", async (event) => {
            if (!text.value.trim()) { say("Write the answer in the box first.", true); return; }
            event.target.disabled = true;
            try { await call("coderabbit_reply", { commentId: first.id, body: text.value }); text.value = ""; say("Answered CodeRabbit."); refresh(); }
            catch (e) { event.target.disabled = false; say("Couldn't answer: " + e.message, true); }
          }, { title: "Answer it in its thread, with the box's words; @coderabbitai is put first" })]) : null,
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
    const more = pr.filesTotal > (pr.files || []).length
      ? el("div", { className: "muted", textContent: `And ${pr.filesTotal - pr.files.length} more, in the diff.` }) : null;
    const show = rows.length ? el("div", { className: "actions" }, [button("Show Diff", () => showDiff(null), { title: "Every file's changed lines, in the app" })]) : null;
    return [show, el("ul", { className: "files" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No files changed." })]), more];
  };
  // The diff is drawn by the app, not here (agents/open-diff, #1341): its own diff, as the
  // Review page's (#1472). A host without it gets GitHub's.
  const showDiff = async (path) => {
    say("Loading the diff…");
    let diff;
    try { diff = await ui.call("show_pull_request_diff", { repo: repo() || pr.repo, number: pr.number, sha: pr.headSha }); }
    catch (e) { say("Couldn't load the diff: " + e.message, true); return; }
    try {
      await request("agents/open-diff", { title: `#${pr.number} ${pr.title}`, url: diff.url, files: diff.files, cut: !!diff.cut,
        ...(path ? { path } : {}) });
      say("");
    } catch (e) {
      if (e.code === -32601) { say("This app shows no diff: it opens on GitHub."); ui.openLink(diff.url); return; }
      say("Couldn't show the diff: " + e.message, true);
    }
  };

  const checks = () => {
    const rows = (pr.checkRuns || []).map((c) => {
      const kind = PR_CHECKS[c.state] ? c.state : "none";
      const shown = logs.get(c.runId);
      const action = c.state === "failing" && c.runId
        ? button(shown ? "Hide Log" : "Show Log", () => toggleLog(c.runId), { title: "The end of the failed jobs' logs" }) : el("span");
      return el("li", {}, [
        el("span", { className: "pill " + kind, textContent: PR_CHECKS[kind] }),
        c.url ? link(c.name, c.url) : el("span", { textContent: c.name }),
        action,
        shown ? el("pre", { className: "log", textContent: shown }) : null,
      ]);
    });
    const out = [el("ul", { className: "checks" }, rows.length ? rows : [el("li", { className: "muted", textContent: "No checks." })])];
    if (pr.checks === "failing" && pr.failedRunId && pr.state === "open") {
      out.push(el("div", { className: "actions" }, [button("Rerun Failed Jobs", async (event) => {
        event.target.disabled = true;
        try { await call("rerun_failed", { runId: pr.failedRunId }); say("The failed jobs run again."); refresh(); }
        catch (e) { event.target.disabled = false; say("Couldn't rerun: " + e.message, true); }
      })]));
    }
    return out;
  };
  const toggleLog = async (runId) => {
    if (logs.has(runId)) { logs.delete(runId); draw(); return; }
    logs.set(runId, "Loading the log…"); draw();
    try {
      const result = await ui.request("tools/call", { name: "failed_log", arguments: { repo: repo() || pr.repo, runId } });
      logs.set(runId, result && !result.isError ? ui.errorText(result) : "Couldn't read the log: " + ui.errorText(result));
    } catch (e) { logs.set(runId, "Couldn't read the log: " + e.message); }
    if (tab === "checks") draw();
  };

  const actions = () => {
    if (pr.state !== "open") return [];
    const comment = button("Comment", async () => {
      if (!text.value.trim()) { say("Write a comment first.", true); return; }
      comment.disabled = true;
      try { await call("comment_on_pr", { body: text.value }); text.value = ""; say("Commented."); refresh(); }
      catch (e) { say("Couldn't comment: " + e.message, true); }
      finally { comment.disabled = false; }
    });
    const agent = button("Ask an Agent", () => askAgent(text.value),
      { title: `Send it to the agent working on ${pr.branch}, or start one there; you say Send or Start first` });
    // Someone else's PR only: GitHub refuses a review of one's own (#837).
    const others = pr.viewer && pr.author && pr.viewer.toLowerCase() !== pr.author.toLowerCase();
    const review = (event, words) => {
      const b = button(words, async () => {
        if (event === "request_changes" && !text.value.trim()) { say("Write what is to change first.", true); return; }
        b.disabled = true;
        try {
          await call("review_pr", { event, body: text.value, sha: pr.headSha });
          text.value = "";
          say(event === "approve" ? `Approved #${pr.number}.` : `Asked for changes on #${pr.number}.`);
          log(`review #${pr.number} ${event}`);
          refresh();
        } catch (e) { say("Couldn't review: " + e.message, true); }
        finally { b.disabled = false; }
      }, { title: event === "approve" ? "Approve it, with the box's words if any" : "Ask for changes: the box says what" });
      return b;
    };
    const blocked = pr.conflicts ? "It conflicts with its base: rebase it first" : pr.draft ? "A draft can't be merged" : "";
    const merge = button("Merge", () => { confirming = "merge"; draw(); }, { className: "primary", disabled: !!blocked, title: blocked });
    const auto = pr.autoMerge ? null
      : button("Auto-merge", () => { confirming = "auto"; draw(); }, { disabled: !!blocked, title: blocked || "Merge it once its checks pass" });
    const out = [text, el("div", { className: "actions" }, [comment, agent,
      ...(others ? [review("approve", "Approve"), review("request_changes", "Request Changes")] : []),
      el("span", { className: "grow" }), auto, merge])];
    if (confirming) {
      const isAuto = confirming === "auto";
      const words = isAuto ? `Turn on auto-merge for #${pr.number}? GitHub squashes it into ${pr.base} once its checks pass, then deletes ${pr.branch}.`
        : `Squash and merge #${pr.number} into ${pr.base} and delete ${pr.branch}?` + (pr.checks === "failing" ? " Its checks fail." : pr.checks === "running" ? " Its checks are still running." : "");
      const yes = button(isAuto ? "Turn On Auto-merge" : "Merge", async () => {
        yes.disabled = true;
        try {
          const r = await call("merge_pr", { auto: isAuto, sha: pr.headSha });
          confirming = null;
          say(r.auto ? "Auto-merge is on: it merges once its checks pass." : `Merged #${pr.number}.`);
          log(`merge #${pr.number}${isAuto ? " (auto)" : ""}`);
          refresh();
        } catch (e) { yes.disabled = false; say("Couldn't merge: " + e.message, true); }
      }, { className: "primary" });
      out.push(el("div", { className: "confirm" }, [el("span", { className: "grow", textContent: words }), yes,
        button("Cancel", () => { confirming = null; draw(); })]));
    }
    return out;
  };

  // To the session working on the PR's branch, as the person's own message: the host asks them
  // first (agents/message-agent, #837). With no such session, the new-agent form on the branch.
  const askAgent = async (note) => {
    const n = pr.number, failing = pr.checks === "failing";
    const what = [failing ? "its failing checks" + (pr.failedRunId ? ` (failed_log runId ${pr.failedRunId})` : "") : "",
      pr.review === "changes_requested" ? "the changes asked for in its reviews" : "", pr.conflicts ? `its conflict with ${pr.base}` : "",
      (pr.threads || []).some((t) => !t.resolved) ? "its open review comments" : ""].filter(Boolean);
    const words = `Work on pull request #${n} (\`gh pr view ${n} --comments\`) on ${pr.branch}`
      + (what.length ? ": " + what.join(", ") : "") + "."
      + (note.trim() ? "\n\n" + note.trim() : "") + "\n\nPush to the same branch.";
    say("Say Send under the view…");
    try { await request("agents/message-agent", { branch: pr.branch, text: words }); say("Sent to the agent."); return; }
    catch (e) { if (e.code !== -32001) { say(e.message, true); return; } }
    try {
      await request("agents/start-agent", { prompt: words, labels: ["P#" + n], branch: pr.branch });
      say(`No agent works on ${pr.branch}: a new one is ready to start.`);
    } catch (e) { say("Couldn't open a new agent on " + pr.branch + ": " + e.message, true); log("start-agent refused: " + e.message, "warning"); }
  };

  const draw = () => {
    if (!pr) return;
    const head = [];
    if (back) head.push(button("‹ Pull requests", back));
    head.push(el("span", { className: "grow" }), link("GitHub ↗", pr.url), button("Refresh", refresh));
    const open = (pr.threads || []).filter((t) => !t.resolved).length;
    const tabs = [["conversation", "Conversation", (pr.comments || []).length], ["review", "Review comments", open],
      ["files", "Files", pr.filesTotal || (pr.files || []).length], ["checks", "Checks", (pr.checkRuns || []).length], ["lineage", "Lineage", 0]]
      .map(([id, words, count]) => button(count ? `${words} ${count}` : words, () => { tab = id; draw(); }, { className: tab === id ? "chosen" : "" }));
    const panel = tab === "lineage" ? [lineage || (lineage = lineageSection(ui, pr.url))] : tab === "files" ? files() : tab === "checks" ? checks() : tab === "review" ? threads() : conversation();
    root.replaceChildren(
      el("div", { className: "bar" }, head),
      el("div", { className: "bar" }, [link(`#${pr.number}`, pr.url), el("h2", { className: "grow", textContent: pr.title })]),
      el("div", { className: "pills" }, [...prPills(ui, pr), ...prLabels(ui, pr, pr.labelColors)]),
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
