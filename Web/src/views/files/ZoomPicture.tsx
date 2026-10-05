// A picture that opens fitted to the pane and can be looked into (ImageFile, #258):
// Zoom out, Actual size, Zoom in and Fit, and a pinch. It is never drawn larger than
// itself until the reader asks, and scrolling the pane reaches the edges.
import { useSignal } from "@preact/signals";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import {
  clampMagnification, fitMagnification, magnificationAfterDoubleClick, stepMagnification, zoomMost,
} from "../../model/pageImage";

export function ZoomPicture({ bytes, type, name, description }: {
  bytes: Uint8Array | string;
  type: string;
  name: string;
  description?: string | undefined;
}) {
  const src = useSignal<string | null>(null);
  const natural = useSignal<{ w: number; h: number } | null>(null);
  /** Null while the picture is fitted, so a resize of the pane refits it. */
  const chosen = useSignal<number | null>(null);
  const room = useSignal({ w: 320, h: 240 });
  const frame = useRef<HTMLDivElement>(null);

  useEffect(() => {
    natural.value = null;
    chosen.value = null;
    const made = URL.createObjectURL(new Blob([bytes as BlobPart], { type }));
    src.value = made;
    return () => URL.revokeObjectURL(made);
  }, [bytes, type]);

  useLayoutEffect(() => {
    const scroll = frame.current?.closest(".scroll");
    if (!scroll) return;
    const measure = () => {
      room.value = { w: Math.max(40, scroll.clientWidth - 24), h: Math.max(80, scroll.clientHeight - 96) };
    };
    measure();
    const watcher = new ResizeObserver(measure);
    watcher.observe(scroll);
    return () => watcher.disconnect();
  }, []);

  useEffect(() => {
    const el = frame.current;
    if (!el) return;
    const onWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return;
      const size = natural.peek();
      if (!size) return;
      event.preventDefault();
      const fit = fitMagnification(size.w, size.h, room.peek().w, room.peek().h);
      const shown = chosen.peek() ?? fit;
      chosen.value = stepMagnification(shown, fit, event.deltaY < 0 ? 1 : -1);
    };
    el.addEventListener("wheel", onWheel, { passive: false });
    return () => el.removeEventListener("wheel", onWheel);
  }, []);

  const size = natural.value;
  const fit = size ? fitMagnification(size.w, size.h, room.value.w, room.value.h) : 1;
  const shown = size ? (chosen.value === null ? fit : clampMagnification(chosen.value, fit)) : 1;
  const fitted = chosen.value === null || Math.abs(shown - fit) < 0.0001;
  const caption = size && description ? `${description} · ${size.w} × ${size.h}` : description || name;

  return (
    <div class="picture-view" ref={frame}>
      {src.value && (
        <img class="picture" src={src.value} alt={name}
          style={size ? { width: `${Math.round(size.w * shown)}px`, height: `${Math.round(size.h * shown)}px` } : undefined}
          onLoad={(event) => {
            const img = event.currentTarget as HTMLImageElement;
            if (img.naturalWidth > 0) natural.value = { w: img.naturalWidth, h: img.naturalHeight };
          }}
          onDblClick={() => { if (size) chosen.value = magnificationAfterDoubleClick(shown, fit); }} />
      )}
      <div class="picture-bar">
        <span class="caption quiet small">{caption}</span>
        <button class="icon" aria-label="Zoom out" title="Zoom out" disabled={!size || shown <= fit + 0.001}
          onClick={() => { chosen.value = stepMagnification(shown, fit, -1); }}>−</button>
        <button class="icon" aria-label="Actual size" title="Actual size" disabled={!size}
          onClick={() => { chosen.value = clampMagnification(1, fit); }}>{size ? `${Math.round(shown * 100)}%` : "100%"}</button>
        <button class="icon" aria-label="Zoom in" title="Zoom in" disabled={!size || shown >= Math.max(zoomMost, fit) - 0.001}
          onClick={() => { chosen.value = stepMagnification(shown, fit, 1); }}>+</button>
        <button class="icon" aria-label="Fit" title="Fit the picture to the pane" disabled={!size || fitted}
          onClick={() => { chosen.value = null; }}>Fit</button>
      </div>
    </div>
  );
}
