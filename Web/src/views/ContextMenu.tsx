// A row's context menu in the sidebar (#151), as the window's rows have them: opened by a right
// click where it was clicked, by the keyboard's menu key or Shift-F10 at the row, or by a finger
// held on the row (#663), which is how a phone asks, as Safari there sends no contextmenu. Escape
// or a click elsewhere closes it, and the keys move through its items.
import { signal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";

export interface MenuItem {
  label: string;
  help?: string;
  disabled?: boolean;
  run: () => void;
}

interface Open {
  x: number;
  y: number;
  items: MenuItem[];
  /** Where focus goes back to once it closes. */
  from: HTMLElement | null;
}

const open = signal<Open | null>(null);

/** Opens `items` for the row the event came from: at the pointer, or under the row for a key. */
export function openContextMenu(event: MouseEvent | KeyboardEvent, items: MenuItem[]): void {
  if (items.length === 0) return;
  event.preventDefault();
  const from = event.currentTarget instanceof HTMLElement ? event.currentTarget : null;
  if (event instanceof MouseEvent && event.clientX + event.clientY > 0) {
    open.value = { x: event.clientX, y: event.clientY, items, from };
    return;
  }
  const box = from?.getBoundingClientRect();
  open.value = { x: (box?.left ?? 0) + 24, y: box?.bottom ?? 0, items, from };
}

/** How long a finger stays on a row, and how far it may wander, before its menu opens (#663). */
export const holdMilliseconds = 500;
const holdSlop = 10;

/**
 * A finger held still on a row: `start` when it lands, `move` as it goes, `end` when it lifts or the
 * page takes it for a scroll. `fire` runs once it has stayed `holdMilliseconds` within `holdSlop`.
 */
export class Hold {
  private timer: ReturnType<typeof setTimeout> | undefined;
  private x = 0;
  private y = 0;

  start(x: number, y: number, fire: () => void): void {
    this.end();
    this.x = x;
    this.y = y;
    this.timer = setTimeout(() => { this.timer = undefined; fire(); }, holdMilliseconds);
  }

  move(x: number, y: number): void {
    if (Math.hypot(x - this.x, y - this.y) > holdSlop) this.end();
  }

  end(): void {
    if (this.timer !== undefined) clearTimeout(this.timer);
    this.timer = undefined;
  }
}

/**
 * The pointer handlers that open `items` when a finger (or pen) is held on the row, spread beside
 * its onContextMenu. A mouse is left to its right click. The click that lifting the finger makes is
 * swallowed, so the hold does not also pick the row.
 */
export function holdForMenu(items: () => MenuItem[]) {
  return {
    onPointerDown: (e: PointerEvent) => {
      if (e.pointerType === "mouse" || !e.isPrimary) return;
      const from = e.currentTarget instanceof HTMLElement ? e.currentTarget : null;
      const { clientX: x, clientY: y } = e;
      hold.start(x, y, () => {
        const shown = items();
        if (shown.length === 0) return;
        swallowNextClick();
        open.value = { x, y, items: shown, from };
      });
    },
    onPointerMove: (e: PointerEvent) => hold.move(e.clientX, e.clientY),
    onPointerUp: () => hold.end(),
    onPointerCancel: () => hold.end(),
  };
}

/** One finger at a time: kept outside the rows, so a row drawn again mid-hold still ends it. */
const hold = new Hold();

/** Drops the click a lifted finger makes, until the next touch lands (Android may send none). */
function swallowNextClick(): void {
  const swallow = (e: Event) => { e.preventDefault(); e.stopPropagation(); done(); };
  const done = () => {
    removeEventListener("click", swallow, true);
    removeEventListener("pointerdown", done, true);
  };
  addEventListener("click", swallow, true);
  addEventListener("pointerdown", done, true);
}

/** The keys that open a row's menu without a pointer. */
export function isMenuKey(event: KeyboardEvent): boolean {
  return event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey);
}

export function ContextMenu() {
  const menu = useRef<HTMLDivElement>(null);
  const shown = open.value;
  const close = (refocus = true) => {
    const from = open.peek()?.from;
    open.value = null;
    if (refocus) from?.focus();
  };
  useEffect(() => {
    if (!shown) return;
    menu.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
    const outside = (e: Event) => { if (!menu.current?.contains(e.target as Node)) close(false); };
    addEventListener("pointerdown", outside);
    addEventListener("blur", outside);
    addEventListener("resize", outside);
    return () => {
      removeEventListener("pointerdown", outside);
      removeEventListener("blur", outside);
      removeEventListener("resize", outside);
    };
  }, [shown]);
  if (!shown) return null;
  // Kept inside the window: a menu opened near the right or bottom edge opens back towards it.
  const left = Math.max(4, Math.min(shown.x, innerWidth - 228));
  const top = Math.max(4, Math.min(shown.y, innerHeight - 12 - 30 * shown.items.length));
  const keys = (e: KeyboardEvent) => {
    const items = [...(menu.current?.querySelectorAll<HTMLButtonElement>("button:not(:disabled)") ?? [])];
    const at = items.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === "Escape" || e.key === "Tab") { e.preventDefault(); close(); }
    else if (e.key === "ArrowDown") { e.preventDefault(); items[(at + 1) % items.length]?.focus(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); items[(at - 1 + items.length) % items.length]?.focus(); }
  };
  return (
    <div class="popover context-menu" role="menu" ref={menu} style={{ left: `${left}px`, top: `${top}px` }} onKeyDown={keys}>
      {shown.items.map((item) => (
        <button key={item.label} role="menuitem" title={item.help} disabled={item.disabled}
          onClick={() => { close(); item.run(); }}>{item.label}</button>
      ))}
    </div>
  );
}
