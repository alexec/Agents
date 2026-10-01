// What didn't work, said once in a strip across the page until it is dismissed (071 T058).
// A refusal by grant says the grant: never a silent failure.
import type { Store } from "../model/store";

export function Problem({ store }: { store: Store }) {
  const problem = store.problem.value;
  if (!problem) return null;
  return (
    <div class="problem" role="alert">
      <span>{problem}</span>
      <button class="link" onClick={() => (store.problem.value = null)}>OK</button>
    </div>
  );
}
