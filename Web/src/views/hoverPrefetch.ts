// The session under the pointer, fetched once the pointer has stayed on its row for
// `prefetchAfter` (#4795; spec 4777-fast): a pointer that only crosses a row fetches nothing.
// One timer for the page, as there is one pointer.
import { prefetchAfter } from "../model/store";

let pending: ReturnType<typeof setTimeout> | undefined;

/** The row's pointer handlers: `run` after the pointer rests on it, never after it left. */
export function prefetchOnHover(run: () => void): { onMouseEnter: () => void; onMouseLeave: () => void } {
  return {
    onMouseEnter: () => {
      clearTimeout(pending);
      pending = setTimeout(() => { pending = undefined; run(); }, prefetchAfter);
    },
    onMouseLeave: () => {
      clearTimeout(pending);
      pending = undefined;
    },
  };
}
