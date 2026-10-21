// Settings ▸ You ▸ Git access (#1122). Listed in ./sections.ts.
import type { Store } from "../../model/store";
import { gitLendWords, lends } from "../../model/gitLending";

/** Git access (#1122): each host using a Mac's git access for a git server, with Stop Lending. */
export function GitAccessSection({ store }: { store: Store }) {
  const lent = lends(store.hosts.value);
  if (lent.length === 0) return null;
  return (
    <section aria-labelledby="settings-git">
      <h3 class="section-head" id="settings-git">Git access</h3>
      <p class="hint">{gitLendWords.footer}</p>
      {lent.map((lend) => (
        <div class="setting" key={`${lend.host} ${lend.server}`}>
          <span>{lend.hostName} · {lend.server} <span class="faint small">Uses {lend.lenderName}’s git access</span></span>
          <button type="button" onClick={() => void store.lendGit(lend.host, lend.from, lend.server, false)}>Stop Lending</button>
        </div>
      ))}
    </section>
  );
}
