// What didn't work, said once in a strip across the page until it is dismissed (071 T058).
// A refusal says so: never a silent failure.
import type { Store } from "../model/store";

export function Problem({ store }: { store: Store }) {
  const problem = store.problem.value;
  // A New Machine the provider refused (#3979), with Try Again on the same provider.
  const failed = store.makeFailed.value;
  if (failed) {
    return (
      <div class="problem" role="alert">
        <span>Could not make the machine: {failed.reason}</span>
        <button class="link" onClick={() => void store.makeMachine(failed.provider)}>Try Again</button>
        <button class="link" onClick={() => { store.makeFailed.value = null; }}>OK</button>
      </div>
    );
  }
  if (!problem) return null;
  return (
    <div class="problem" role="alert">
      <span>{problem}</span>
      <button class="link" onClick={() => store.dismissProblem()}>OK</button>
    </div>
  );
}
