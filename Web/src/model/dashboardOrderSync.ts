// One page's Dashboard order kept in step with its host while tiles are dragged (#176, #193), as
// AgentsKitCore's DashboardOrderSync does it for the window.
//
// A drop is shown at once and sent as the whole order. Two quick drops each sent their own order
// and refetched, and a refresh for a `dashboard/changed` could be on its way at the same time, so
// the replies landed in any order: a tile jumped back to where it was, or the host kept the first
// drop and not the second. So:
// - Writes are serial and the last one wins. One send at a time per Dashboard; drops made while
//   it is out wait, and only the newest of them is sent next.
// - A fetch is kept only if nothing newer is. A reply to a fetch begun before another that has
//   already been kept is dropped; while an order of this page's is not yet known to be on the
//   host, a fetched snapshot is shown in that order.
//
// Holds no snapshots, only what was arranged here, by `host|folder`: the caller stores what
// `accept` says.
import type { DashboardOrder, DashboardSnapshot } from "../protocol/generated";

export class DashboardOrderSync {
  /** The newest order arranged here and not yet seen back from the host. */
  private arranged = new Map<string, DashboardOrder>();
  /** The newest order waiting to be sent, while a send is out. */
  private unsent = new Map<string, DashboardOrder>();
  /** Dashboards with a send out. */
  private sending = new Set<string>();
  /** Fetches begun, and the newest of them kept. */
  private begun = new Map<string, number>();
  private kept = new Map<string, number>();
  /** The first fetch that began after every order arranged here had been sent. */
  private settledFrom = new Map<string, number>();

  /**
   * A drop or a Move item arranged `order`. True when the caller is to send it, and then to go on
   * sending `takeUnsent` until it says there is nothing left; false when a send is already out,
   * which takes this order next.
   */
  arrange(key: string, order: DashboardOrder): boolean {
    this.arranged.set(key, order);
    this.unsent.set(key, order);
    if (this.sending.has(key)) return false;
    this.sending.add(key);
    return true;
  }

  /** The order to send next, or null when everything arranged here has been sent. */
  takeUnsent(key: string): DashboardOrder | null {
    const next = this.unsent.get(key);
    if (next) {
      this.unsent.delete(key);
      return next;
    }
    this.sending.delete(key);
    this.settledFrom.set(key, (this.begun.get(key) ?? 0) + 1);
    return null;
  }

  /** A fetch is about to be asked for. Hand its ticket to `accept` with the reply. */
  beginFetch(key: string): number {
    const ticket = (this.begun.get(key) ?? 0) + 1;
    this.begun.set(key, ticket);
    return ticket;
  }

  /** What to show for a fetched snapshot, or null to keep what is shown: a newer fetch has been kept. */
  accept(key: string, snapshot: DashboardSnapshot, ticket: number): DashboardSnapshot | null {
    if (ticket <= (this.kept.get(key) ?? 0)) return null;
    this.kept.set(key, ticket);
    const order = this.arranged.get(key);
    if (!order) return snapshot;
    // Asked for after the last send finished: the host's order includes it.
    if (!this.sending.has(key) && ticket >= (this.settledFrom.get(key) ?? Infinity)) {
      this.arranged.delete(key);
      return snapshot;
    }
    return { ...snapshot, order };
  }
}
