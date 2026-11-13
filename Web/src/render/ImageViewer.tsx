// A Work page's image, large, in the page (#4011), as the Mac's sheet (Shared/UI/Page/ImageViewer.swift):
// the image fitted to the viewer, which is as large as the image inside the window; the wheel, a
// pinch, a double-click or + and − to zoom, a drag to move about a zoomed image; Esc, Done or a
// click outside to close. No new tab: the person stays here. It goes through the images of the
// same message (#4954): the arrows, which show while the pointer is over the image (always on a
// touch screen), ← and →, and a swipe sideways on a touch screen go to the previous and the next.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import {
  clampMagnification, fitMagnification, magnificationAfterDoubleClick, magnificationAfterWheel,
  sequenceCounter, sequenceStep, stepMagnification, swipeStep, viewerSize, zoomMost,
} from "../model/pageImage";

/** One image the viewer goes through. */
export interface ViewerImage { src: string; alt: string; natural: { w: number; h: number } }

/** Where the zoom started, kept under the pointer once the image is drawn at the new level. */
interface Anchor { ix: number; iy: number; px: number; py: number }

export function ImageViewer({ images, start, close }: {
  images: ViewerImage[];
  start: number;
  close: () => void;
}) {
  const at = useSignal(Math.min(Math.max(0, start), images.length - 1));
  const { src, alt, natural } = images[at.value]!;
  const naturalRef = useRef(natural);
  naturalRef.current = natural;
  const previous = sequenceStep(at.value, images.length, -1);
  const following = sequenceStep(at.value, images.length, 1);
  const counter = sequenceCounter(at.value, images.length);
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
  // As large as the largest image, so the viewer keeps its size from one image to the next.
  const size = viewerSize(Math.max(...images.map((i) => i.natural.w)), Math.max(...images.map((i) => i.natural.h)),
    window_.value.w, window_.value.h);

  /** Goes to the image at `next`, fitted. */
  const show = (next: number | null) => {
    if (next === null) return;
    anchor.current = null;
    chosen.value = null;
    at.value = next;
  };
  const showRef = useRef(show);
  showRef.current = show;
  const atRef = useRef(at.value);
  atRef.current = at.value;

  /** Zooms to `level`, keeping the point under (x, y) on the page where it is, or the middle. */
  const zoomTo = (level: number, x?: number, y?: number) => {
    const el = stage.current;
    if (el) {
      const box = el.getBoundingClientRect();
      const px = x === undefined ? el.clientWidth / 2 : x - box.left;
      const py = y === undefined ? el.clientHeight / 2 : y - box.top;
      const was = shownNow();
      const n = naturalRef.current;
      const ox = Math.max(0, (el.clientWidth - n.w * was) / 2), oy = Math.max(0, (el.clientHeight - n.h * was) / 2);
      anchor.current = { ix: (el.scrollLeft + px - ox) / was, iy: (el.scrollTop + py - oy) / was, px, py };
    }
    const f = fitNow();
    chosen.value = Math.abs(level - f) < 0.0001 ? null : level;
  };
  const fitNow = () => fitMagnification(naturalRef.current.w, naturalRef.current.h, room.peek().w, room.peek().h);
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

  // An arrow that was clicked is gone at an end: focus stays in the viewer, so ← and → still work.
  useEffect(() => {
    const d = dialog.current;
    if (d && !d.contains(document.activeElement)) d.focus();
  }, [at.value]);

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
    /** Where one finger went down on a fitted image: a swipe sideways from there steps (#4954). */
    let swipe: { id: number; x: number; y: number } | null = null;
    const spread = () => {
      const [a, b] = [...pointers.values()];
      return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0;
    };
    const down = (event: PointerEvent) => {
      if (event.button !== 0) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      el.setPointerCapture(event.pointerId);
      if (pointers.size === 2) pinch = { distance: spread(), level: shownNow() };
      const fittedNow = Math.abs(shownNow() - fitNow()) < 0.0001;
      swipe = pointers.size === 1 && event.pointerType === "touch" && fittedNow
        ? { id: event.pointerId, x: event.clientX, y: event.clientY } : null;
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
      if (event.type === "pointerup" && swipe?.id === event.pointerId && pointers.size === 1) {
        const by = swipeStep(event.clientX - swipe.x, event.clientY - swipe.y);
        if (by) showRef.current(sequenceStep(atRef.current, images.length, by));
      }
      if (swipe?.id === event.pointerId || pointers.size > 1) swipe = null;
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
    <dialog class="image-viewer" ref={dialog} aria-label={label} onClose={close} tabIndex={-1}
      style={{ width: `${size.w}px`, height: `${size.h}px` }}
      // A click on the backdrop is a click on the dialog itself: outside, so it closes.
      onClick={(event) => { if (event.target === dialog.current) close(); }}
      onKeyDown={(event) => {
        if (event.metaKey || event.ctrlKey || event.altKey) return;
        if (event.key === "+" || event.key === "=") { event.preventDefault(); zoomTo(stepMagnification(shown, fit, 1)); }
        else if (event.key === "-") { event.preventDefault(); zoomTo(stepMagnification(shown, fit, -1)); }
        else if (event.key === "ArrowLeft" && previous !== null) { event.preventDefault(); show(previous); }
        else if (event.key === "ArrowRight" && following !== null) { event.preventDefault(); show(following); }
      }}>
      <div class="image-viewer-frame">
        <div class={`image-viewer-stage${fitted ? "" : " zoomed"}`} ref={stage}
          onDblClick={(event) => zoomTo(magnificationAfterDoubleClick(shown, fit), event.clientX, event.clientY)}>
          {room.value.w > 0 && (
            <img src={src} alt={label} draggable={false}
              style={{ width: `${Math.round(natural.w * shown)}px`, height: `${Math.round(natural.h * shown)}px` }} />
          )}
        </div>
        {images.length > 1 && previous !== null && (
          <button type="button" class="image-viewer-arrow previous" aria-label="Previous Image" title="Previous Image (←)"
            onClick={() => show(previous)}>‹</button>
        )}
        {images.length > 1 && following !== null && (
          <button type="button" class="image-viewer-arrow next" aria-label="Next Image" title="Next Image (→)"
            onClick={() => show(following)}>›</button>
        )}
      </div>
      <div class="image-viewer-bar">
        <span class="caption quiet small">{label}</span>
        {counter && <span class="counter quiet small">{counter}</span>}
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
