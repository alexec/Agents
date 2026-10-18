// The page zoom (#1419) on a page shown: ⌘+, ⌘− and ⌘0 are the page's while it is, not the
// browser's. CSS zoom rather than a font size, so code, tables, pictures and diagrams grow with the
// words, and the measure (70ch) with them, and the page still wraps to the pane.
import { useEffect } from "preact/hooks";
import { pageZoom, setPageZoom, zoomForKey } from "../../model/pageZoom";

/** Takes the zoom keys while the page is on screen, and gives the style that draws the level. */
export function usePageZoom(): { zoom: string } | undefined {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      const next = zoomForKey(pageZoom.value, e);
      if (next === null) return;
      e.preventDefault();
      setPageZoom(next);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  const zoom = pageZoom.value;
  return zoom === 1 ? undefined : { zoom: String(zoom) };
}
