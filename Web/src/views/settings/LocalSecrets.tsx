// Settings ▸ You ▸ Secrets ▸ On This Machine (#5122): the secrets a machine keeps for itself, which agents
// saved there (ask_secret, capture_secret, generate_secret), each with an Ask before use checkbox (#4016).
// Without it a person could not see them, nor turn the flag off so a script can read one. Left out when
// there are none, and on a host too old to list them. The machine is For One Session's (its picker). As the
// window's LocalSecretsSection.
import { signal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { LocalSecret, LocalSecrets } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { about } from "../../model/userScope";
import { localLine, localSecretWords } from "../../model/localSecrets";
import { askBeforeUseHint, askBeforeUseWords } from "../../model/askBeforeUse";
import { Capability } from "../../protocol/capabilities.generated";
import { SecretInfoLine } from "../SecretInfoLine";
import { useSettingsMachine } from "./SettingsMachine";

const lists = signal<Record<string, LocalSecrets | null>>({});

export function LocalSecretsSection({ store, down }: { store: Store; down: boolean }) {
  const { host } = useSettingsMachine(store);
  const known = !!host && store.has(host, Capability.hostLocalSecrets1);
  useEffect(() => {
    if (!host || !known) return;
    void store.link.call("secrets/localList", {}, host).then(
      (list) => { lists.value = { ...lists.value, [host]: list }; },
      () => { lists.value = { ...lists.value, [host]: null }; },
    );
  }, [store, host, known]);
  const list = host ? lists.value[host] : undefined;
  if (!host || !list || list.secrets.length === 0) return null;
  const offersAsk = store.has(host, Capability.hostSecretApproval1);
  const setAsk = async (secret: LocalSecret, on: boolean) => {
    try {
      await store.link.call("secrets/setNeedsApproval", { name: secret.name, needsApproval: on }, host);
      lists.value = { ...lists.value, [host]: await store.link.call("secrets/localList", {}, host) };
    } catch (error) {
      store.say(describe(error));
    }
  };
  return (
    <section aria-labelledby="settings-local-secrets">
      <h3 class="section-head" id="settings-local-secrets">{localSecretWords.header}</h3>
      {list.secrets.map((s) => (
        <div class="setting" key={s.name}>
          <span>
            <code>{s.name}</code><br />
            <span class="faint small">{about(s.description)}</span><br />
            <SecretInfoLine parts={localLine(s)} class="faint small" /><br />
            <span class="small secret-warning"><span aria-hidden="true">⚠ </span>{localSecretWords.notBackedUp}</span>
          </span>
          {offersAsk && (
            <label title={askBeforeUseHint(s.needsApproval === true)}>
              <input type="checkbox" checked={s.needsApproval === true} disabled={down}
                aria-label={`${askBeforeUseWords.toggle}: ${s.name}`}
                onChange={(e) => void setAsk(s, (e.currentTarget as HTMLInputElement).checked)} />
              {" "}{askBeforeUseWords.toggle}
            </label>
          )}
        </div>
      ))}
      <p class="hint">{localSecretWords.footer}</p>
    </section>
  );
}
