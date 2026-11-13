// A modal sheet, shared by the dialogs: here, apart from any of them, so a page can open one
// without loading another's module.
import type { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";

/** A modal `<dialog>`: Escape and the backdrop's focus come with it. `keep` true leaves it open on Escape.
 * `modeless` opens it as a panel in the corner instead, with the page under it still working (#5203). */
export function Modal({ label, close, keep, modeless, children }: {
  label: string; close: () => void; keep?: () => boolean; modeless?: boolean; children: ComponentChildren;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) { if (modeless) dialog.show(); else dialog.showModal(); }
    return () => dialog?.close();
  }, []);
  return (
    <dialog class={modeless ? "sheet modeless" : "sheet"} ref={ref} aria-label={label} onClose={close}
      onCancel={(event) => { if (keep?.()) event.preventDefault(); }}>
      {children}
    </dialog>
  );
}
