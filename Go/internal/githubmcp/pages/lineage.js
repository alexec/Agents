// The Lineage section (#2941): the sessions that worked on an issue or a pull request, and on
// its pull requests, with what each cost, from the Agents host's own record. The host answers
// agents_lineage itself (docs/explanation/views.md); a host that doesn't, or an older one,
// refuses it, and the section says so. lineageSection(ui, url) is the section, filled in once
// the host answers. The gitlab and linear servers' pages carry a copy, word for word.
const lineageSection = (ui, url) => {
  const { el, link } = ui;
  const box = el("div", { className: "lineage" }, [el("span", { className: "muted", textContent: "Lineage: loading…" })]);
  const OUTCOME = { open: "Open", merged: "Merged", closed: "Closed", reverted: "Reverted" };
  // A pull request with its end; an issue, on a pull request's page, is one it fixes.
  const node = (n) => el("div", { className: "lineage-row" }, [
    n.outcome ? null : el("span", { className: "muted", textContent: "Fixes" }),
    n.url ? link(n.name, n.url) : el("span", { textContent: n.name }),
    n.outcome ? el("span", { className: "pill " + (n.outcome === "reverted" ? "closed" : n.outcome), textContent: OUTCOME[n.outcome] || n.outcome,
      title: n.waste ? "Waste: it ended without a merge, or was reverted" : "" }) : null,
    n.words ? el("span", { className: "muted", textContent: n.words }) : null,
  ]);
  const session = (s) => el("div", { className: "lineage-row" }, [
    el("span", { className: "pill", textContent: "Session" }),
    el("span", { className: "lineage-title", textContent: s.title }),
    el("span", { className: "muted", textContent: [s.how, s.words].filter(Boolean).join(" · ") }),
  ]);
  const draw = (l) => {
    const rows = [el("div", { className: "lineage-row" }, [el("strong", { textContent: "Lineage" }),
      el("span", { className: "muted", textContent: l.summary || "" })])];
    if (l.total) rows.push(el("span", { className: "muted", textContent: "Cost: " + l.total }));
    if (l.waste) rows.push(el("span", { className: "waste", textContent: l.waste }));
    for (const s of l.sessions || []) rows.push(session(s));
    for (const n of [...(l.prs || []), ...(l.issues || [])]) rows.push(node(n));
    if (l.limited) rows.push(el("span", { className: "muted", textContent: "There is more than this shows." }));
    box.replaceChildren(...rows);
    ui.size();
  };
  ui.call("agents_lineage", { url }).then(draw, (e) => {
    box.replaceChildren(el("span", { className: "muted", textContent: "Lineage: this app keeps none here (" + e.message + ")" }));
    ui.size();
  });
  return box;
};
