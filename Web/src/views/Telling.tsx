// What something sent looks like while it is on its way (#86, #87; Shared/UI/Telling.swift): a
// small spinner and "telling your Mac", on the control that sent it or in its row's place.
import { tellingWords } from "../model/store";

export function Telling({ recipient, doing = null }: { recipient: string; doing?: string | null }) {
  return <span class="telling" role="status"><span class="spinner" aria-hidden="true" />{tellingWords(doing, recipient)}</span>;
}
