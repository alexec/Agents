// The manifest page for the agents' bot (#3858, spec 3856 §4). It holds nothing and keeps
// nothing: it reads the action and the manifest from the fragment, takes them out of the address
// bar, and posts the manifest to GitHub's "new App" page. It posts only to github.com's page for
// a new App, so it cannot be used to post anything anywhere else.
(function () {
  "use strict";
  var words = document.getElementById("words");
  var form = document.getElementById("form");
  var query = new URLSearchParams(location.hash.slice(1));
  history.replaceState(null, "", location.pathname);
  var action = query.get("action") || "";
  var manifest = query.get("manifest") || "";

  var ok = false;
  try {
    var u = new URL(action);
    ok = u.origin === "https://github.com" && /^\/(settings|organizations\/[A-Za-z0-9-]+\/settings)\/apps\/new$/.test(u.pathname) &&
      !!u.searchParams.get("state") && typeof JSON.parse(manifest) === "object";
  } catch (e) {
    ok = false;
  }
  if (!ok) {
    words.textContent = "This page is for making your agents' bot from Agent Loops. Start again from Agent Loops.";
    return;
  }
  form.action = action;
  document.getElementById("manifest").value = manifest;
  form.submit();
})();
