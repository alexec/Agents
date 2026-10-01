// Until the three columns (Phase 5): who this browser is, the hosts and their projects as
// plain text, and Forget This Browser… (071 T031).
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { Session } from "../session";

interface HostProjects {
  id: string;
  name: string;
  state: string;
  projects: string[];
}

export function Paired({ session }: { session: Session }) {
  const hosts = useSignal<HostProjects[]>([]);
  const confirming = useSignal(false);
  const state = session.state.value;
  const name = state.kind === "open" ? state.name : "";
  const grant = state.kind === "open" ? state.grant : "device";

  useEffect(() => {
    let live = true;
    void (async () => {
      const list = await session.link.call("hosts/list", {});
      const out: HostProjects[] = [];
      for (const host of list) {
        let projects: string[] = [];
        if (host.state === "online") {
          const summaries = await session.link.call("projects/list", { includeArchived: false }, host.id).catch(() => []);
          projects = summaries.map((summary) => summary.name);
        }
        out.push({ id: host.id, name: host.name, state: host.state, projects });
      }
      if (live) hosts.value = out;
    })().catch(() => {});
    return () => {
      live = false;
    };
  }, []);

  return (
    <main class="paired">
      <h1>{name || "Agents"}</h1>
      {hosts.value.map((host) => (
        <section key={host.id} aria-label={host.name}>
          <h2>{host.name}{host.state !== "online" && ` · ${host.state}`}</h2>
          <ul>
            {host.projects.map((project) => <li key={project}>{project}</li>)}
          </ul>
        </section>
      ))}
      <footer class="identity">
        <span>This browser · {grant === "operator" ? "Operator" : "Device"}</span>
        {confirming.value ? (
          <span class="confirm">
            Forget this browser? It will need a new code.{" "}
            <button onClick={() => void session.forgetThisBrowser()}>Forget</button>{" "}
            <button onClick={() => (confirming.value = false)}>Cancel</button>
          </span>
        ) : (
          <button onClick={() => (confirming.value = true)}>Forget This Browser…</button>
        )}
      </footer>
    </main>
  );
}
