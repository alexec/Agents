// A modal sheet, shared by the dialogs: here, apart from any of them, so a page can open one
// without loading another's module.
import type { ComponentChildren } from "preact";
import { useEffect, useRef } from "preact/hooks";

/** A modal `<dialog>`: Escape and the backdrop's focus come with it. */
export function Modal({ label, close, children }: { label: string; close: () => void; children: ComponentChildren }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    if (dialog && !dialog.open) dialog.showModal();
    return () => dialog?.close();
  }, []);
  return (
    <dialog class="sheet" ref={ref} aria-label={label} onClose={close}>
      {children}
    </dialog>
  );
}
