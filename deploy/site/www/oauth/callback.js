// The hand-back page (#1343, #1335 S1 Q1c option 4). It holds nothing and keeps nothing: it
// gives the code and the state (or the provider's error) back to the client that opened the
// browser, then takes them out of the address bar.
//
// - The state has no dot (the Mac and the Remote): go to agents://oauth/callback, which their
//   authentication session catches.
// - The state ends in "." and a base64url origin (the web page): postMessage to window.opener,
//   to that origin only. A page at another origin is never sent the code.
//
// The code alone is of no use: the host that started the sign-in holds the PKCE verifier.
(function () {
  "use strict";
  var words = document.getElementById("words");
  var back = document.getElementById("back");
  var query = new URLSearchParams(location.search);
  var answer = {};
  ["code", "state", "error"].forEach(function (k) {
    var v = query.get(k);
    if (v) answer[k] = v;
  });
  history.replaceState(null, "", location.pathname);

  function say(text) { words.textContent = text; }

  if (!answer.state) {
    say("This page is for signing in from Agents. Start again from Agents.");
    return;
  }
  var dot = answer.state.indexOf(".");
  if (dot < 0) {
    var target = "agents://oauth/callback?" + new URLSearchParams(answer).toString();
    back.href = target;
    back.hidden = false;
    say(answer.error ? "The sign-in did not finish. Going back to Agents…" : "Going back to Agents…");
    location.replace(target);
    return;
  }
  var origin = "";
  try {
    var b64 = answer.state.slice(dot + 1).replace(/-/g, "+").replace(/_/g, "/");
    origin = new URL(atob(b64)).origin;
  } catch (e) {
    origin = "";
  }
  if (!/^https?:\/\//.test(origin) || !window.opener) {
    say("The Agents page that asked is not open any more. Start the sign-in again from Agents.");
    return;
  }
  window.opener.postMessage({ type: "agents-oauth-callback", code: answer.code || null,
    state: answer.state, error: answer.error || null }, origin);
  say("Signed in. You can close this window.");
  setTimeout(function () { window.close(); }, 400);
})();
