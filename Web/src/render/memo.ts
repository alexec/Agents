// A component drawn again only when its props change (#170): preact/compat's memo, without the
// rest of compat, which would change how every event handler is named.
import { type FunctionComponent, h } from "preact";

/** Whether two sets of props are the same, each value compared by identity. */
export function sameProps(a: object, b: object): boolean {
  const before = a as Record<string, unknown>;
  const after = b as Record<string, unknown>;
  for (const key in before) if (!(key in after)) return false;
  for (const key in after) if (before[key] !== after[key]) return false;
  return true;
}

/**
 * `render`, skipped when its parent redraws with props `same` calls equal. What it reads from
 * signals still redraws it by itself.
 */
export function memo<P extends object>(render: FunctionComponent<P>, same: (a: P, b: P) => boolean = sameProps): FunctionComponent<P> {
  function Memo(this: { shouldComponentUpdate?: (next: P) => boolean; props: P }, props: P) {
    this.shouldComponentUpdate = (next: P) => !same(this.props, next);
    return h(render, props);
  }
  Memo.displayName = `Memo(${render.displayName ?? render.name})`;
  return Memo as unknown as FunctionComponent<P>;
}
