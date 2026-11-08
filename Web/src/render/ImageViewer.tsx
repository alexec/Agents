// A Work page's image, large, in the page (#4011), as the Mac's sheet (Shared/UI/Page/ImageViewer.swift):
// the image fitted to the viewer, which is as large as the image inside the window; the wheel, a
// pinch, a double-click or + and − to zoom, a drag to move about a zoomed image; Esc, Done or a
// click outside to close. No new tab: the person stays here.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import {
  clampMagnification, fitMagnification, magnificationAfterDoubleClick, magnificationAfterWheel,
  stepMagnification, viewerSize, zoomMost,
} from "../model/pageImage";

/** Where the zoom started, kept under the pointer once the image is drawn at the new level. */
interface Anchor { ix: number; iy: number; px: number; py: number }

export function ImageViewer({ src, alt, natural, close }: {
  src: string;
  alt: string;
  natural: { w: number; h: number };
  close: () => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null);
  const stage = useRef<HTMLDivElement>(null);
  /** Null while the image is fitted, so a resize of the window refits it. */
  const chosen = useSignal<number | null>(null);
  const room = useSignal({ w: 0, h: 0 });
  const window_ = useSignal({ w: innerWidth, h: innerHeight });
  const anchor = useRef<Anchor | null>(null);
  const label = alt || "Image";

  const fit = room.value.w > 0 ? fitMagnification(natural.w, natural.h, room.value.w, room.value.h) : 1;
  const shown = chosen.value === null ? fit : clampMagnification(chosen.value, fit);
  const fitted = chosen.value === null || Math.abs(shown - fit) < 0.0001;
  const size = viewerSize(natural.w, natural.h, window_.value.w, window_.value.h);

  /** Zooms to `level`, keeping the point under (x, y) on the page where it is, or the middle. */
  const zoomTo = (level: number, x?: number, y?: number) => {
    const el = stage.current;
    if (el) {
      const box = el.getBoundingClientRect();
      const px = x === undefined ? el.clientWidth / 2 : x - box.left;
      const py = y === undefined ? el.clientHeight / 2 : y - box.top;
      const was = shownNow();
      const ox = Math.max(0, (el.clientWidth - natural.w * was) / 2), oy = Math.max(0, (el.clientHeight - natural.h * was) / 2);
      anchor.current = { ix: (el.scrollLeft + px - ox) / was, iy: (el.scrollTop + py - oy) / was, px, py };
    }
    const f = fitNow();
    chosen.value = Math.abs(level - f) < 0.0001 ? null : level;
  };
  const fitNow = () => fitMagnification(natural.w, natural.h, room.peek().w, room.peek().h);
  const shownNow = () => { const f = fitNow(), c = chosen.peek(); return c === null ? f : clampMagnification(c, f); };

  useEffect(() => {
    const d = dialog.current;
    if (d && !d.open) d.showModal();
    const resized = () => { window_.value = { w: innerWidth, h: innerHeight }; };
    addEventListener("resize", resized);
    return () => { removeEventListener("resize", resized); d?.close(); };
  }, []);

  useLayoutEffect(() => {
    const el = stage.current;
    if (!el) return;
    const measure = () => { room.value = { w: el.clientWidth, h: el.clientHeight }; };
    measure();
    const watcher = new ResizeObserver(measure);
    watcher.observe(el);
    return () => watcher.disconnect();
  }, []);

  // After a zoom, the point the zoom started from goes back under the pointer.
  useLayoutEffect(() => {
    const el = stage.current, at = anchor.current;
    anchor.current = null;
    if (!el || !at) return;
    const ox = Math.max(0, (el.clientWidth - natural.w * shown) / 2), oy = Math.max(0, (el.clientHeight - natural.h * shown) / 2);
    el.scrollLeft = at.ix * shown + ox - at.px;
    el.scrollTop = at.iy * shown + oy - at.py;
  }, [shown]);

  // The wheel and a trackpad's pinch zoom; two fingers on a touch screen pinch; one finger, or the
  // mouse, drags a zoomed image about.
  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      const delta = event.deltaMode === 1 ? event.deltaY * 16 : event.deltaY;
      zoomTo(magnificationAfterWheel(shownNow(), fitNow(), delta, event.ctrlKey), event.clientX, event.clientY);
    };
    const pointers = new Map<number, { x: number; y: number }>();
    let pinch: { distance: number; level: number } | null = null;
    const spread = () => {
      const [a, b] = [...pointers.values()];
      return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0;
    };
    const down = (event: PointerEvent) => {
      if (event.button !== 0) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      el.setPointerCapture(event.pointerId);
      if (pointers.size === 2) pinch = { distance: spread(), level: shownNow() };
    };
    const move = (event: PointerEvent) => {
      const was = pointers.get(event.pointerId);
      if (!was) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (pinch && pointers.size === 2) {
        const [a, b] = [...pointers.values()];
        if (pinch.distance > 0 && a && b) {
          zoomTo(clampMagnification(pinch.level * spread() / pinch.distance, fitNow()), (a.x + b.x) / 2, (a.y + b.y) / 2);
        }
        return;
      }
      el.scrollLeft -= event.clientX - was.x;
      el.scrollTop -= event.clientY - was.y;
    };
    const up = (event: PointerEvent) => {
      pointers.delete(event.pointerId);
      if (pointers.size < 2) pinch = null;
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    el.addEventListener("pointerdown", down);
    el.addEventListener("pointermove", move);
    el.addEventListener("pointerup", up);
    el.addEventListener("pointercancel", up);
    return () => {
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("pointerdown", down);
      el.removeEventListener("pointermove", move);
      el.removeEventListener("pointerup", up);
      el.removeEventListener("pointercancel", up);
    };
  }, []);

  return (
    <dialog class="image-viewer" ref={dialog} aria-label={label} onClose={close}
      style={{ width: `${size.w}px`, height: `${size.h}px` }}
      // A click on the backdrop is a click on the dialog itself: outside, so it closes.
      onClick={(event) => { if (event.target === dialog.current) close(); }}
      onKeyDown={(event) => {
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (event.key === "+" || event.key === "=") { event.preventDefault(); zoomTo(stepMagnification(shown, fit, 1)); }
        else if (event.key === "-") { event.preventDefault(); zoomTo(stepMagnification(shown, fit, -1)); }
      }}>
      <div class={`image-viewer-stage${fitted ? "" : " zoomed"}`} ref={stage}
        onDblClick={(event) => zoomTo(magnificationAfterDoubleClick(shown, fit), event.clientX, event.clientY)}>
        {room.value.w > 0 && (
          <img src={src} alt={label} draggable={false}
            style={{ width: `${Math.round(natural.w * shown)}px`, height: `${Math.round(natural.h * shown)}px` }} />
        )}
      </div>
      <div class="image-viewer-bar">
        <span class="caption quiet small">{label}</span>
        <span class="spacer" />
        <button type="button" class="icon" aria-label="Zoom Out" title="Zoom Out (−)" disabled={shown <= fit + 0.001}
          onClick={() => zoomTo(stepMagnification(shown, fit, -1))}>−</button>
        <button type="button" class="icon zoom-level" title="Fit the image to the window" onClick={() => zoomTo(fit)}>
          {`${Math.round(shown * 100)}%`}</button>
        <button type="button" class="icon" aria-label="Zoom In" title="Zoom In (+)" disabled={shown >= Math.max(zoomMost, fit) - 0.001}
          onClick={() => zoomTo(stepMagnification(shown, fit, 1))}>+</button>
        <button type="button" class="done" onClick={close}>Done</button>
      </div>
    </dialog>
  );
}
