// Report a Problem's words for the page itself (#3718): which client it is, and the browser and its
// OS in a few words, not the whole user agent.

/** The client line a report gives, with the version of the host that serves the page. */
export function webClient(version: string | undefined): string {
  return version ? `Web page (served by Agent Loops ${version})` : "Web page";
}

/** "Chrome 156 on macOS" from a user agent; the user agent itself when nothing in it is known. */
export function browserWords(userAgent: string): string {
  const named = (name: string, pattern: RegExp) => {
    const m = pattern.exec(userAgent);
    return m ? `${name} ${m[1]}` : null;
  };
  const browser = named("Edge", /Edg\/(\d+)/) ?? named("Firefox", /Firefox\/(\d+)/)
    ?? named("Chrome", /(?:Headless)?Chrome\/(\d+)/) ?? named("Safari", /Version\/(\d+(?:\.\d+)?).*Safari\//);
  const os = /iPhone|iPad/.test(userAgent) ? "iOS" : /Android/.test(userAgent) ? "Android"
    : /Mac OS X|Macintosh/.test(userAgent) ? "macOS" : /Windows/.test(userAgent) ? "Windows"
    : /Linux|CrOS/.test(userAgent) ? "Linux" : null;
  if (!browser) return userAgent;
  return os ? `${browser} on ${os}` : browser;
}
