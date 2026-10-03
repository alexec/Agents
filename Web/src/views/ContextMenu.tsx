// A row's context menu in the sidebar (#151), as the window's rows have them: opened by a right
// click where it was clicked, or by the keyboard's menu key or Shift-F10 at the row. Escape or a
// click elsewhere closes it, and the keys move through its items.
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
