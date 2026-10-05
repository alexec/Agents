// One file, read through the host (071 FR-029, FR-031, research R12): text numbered, Markdown
// through the renderer, pictures fitted and able to zoom, SVG only as an <img> made from its
// bytes (which a browser draws with scripts off and nothing loaded), and HTML as its source.
// Nothing a file holds can run or reach anywhere: no HTML sink, and the page's CSP besides.
//
// Read again whenever the host says something under this agent changed, with the stamp held
// so an unchanged file costs nothing (#258). A slow read of the last file does not land here.
import { useSignal } from "@preact/signals";
import { useLayoutEffect, useMemo, useRef } from "preact/hooks";
import type { FileReading } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { openFileShouldReread } from "../../model/fileWatch";
import { bytesOf, mediaType, pictureFromReading } from "../../model/pageImage";
import { Markdown, type PageImages } from "../../render/markdown";
import { nameOf, textShownAs } from "./paneState";
import { FileLines } from "./FileLines";
import { ZoomPicture } from "./ZoomPicture";

export function FileView({ store, host, agentID, path, line }: {
  store: Store; host: string; agentID: string; path: string; line?: number | undefined;
}) {
  const reading = useSignal<FileReading | null>(null);
  const failed = useSignal<string | null>(null);
  const held = useRef<{ host: string; agentID: string; path: string; reading: FileReading } | null>(null);
  const change = store.filesChanged.value;
  const changedAt = openFileShouldReread(change, agentID) ? change!.at : 0;
  // A different file must not keep the last one's text for a frame while the next read is in flight.
  if (held.current && (held.current.host !== host || held.current.agentID !== agentID || held.current.path !== path)) {
    held.current = null;
    reading.value = null;
    failed.value = null;
  }
  useLayoutEffect(() => {
    let current = true;
    const sameFile = held.current?.host === host && held.current.agentID === agentID && held.current.path === path;
    const known = sameFile ? held.current?.reading.stamp : undefined;
    if (!known) {
      reading.value = null;
      failed.value = null;
    }
    void store.readFile(host, agentID, path, known).then(
      (r) => {
        if (!current || r.kind === "unchanged") return;
        held.current = { host, agentID, path, reading: r };
        reading.value = r;
        failed.value = null;
      },
      (e) => {
        if (!current) return;
        held.current = null;
        reading.value = null;
        failed.value = describe(e);
      });
    return () => { current = false; };
  }, [host, agentID, path, changedAt]);

  const images: PageImages = useMemo(() => ({
    document: path,
    revision: changedAt,
    read: (file) => store.readFile(host, agentID, file).then(
      (r) => pictureFromReading(file, r),
      () => null,
    ),
  }), [path, changedAt, host, agentID, store]);
  // The bytes stay the same object until the reading changes, or the picture is made again on every draw.
  const picture = useMemo(() => {
    const current = reading.value;
    if (!current) return null;
    return pictureFromReading(path, current)
      ?? (current.kind === "image" ? { bytes: bytesOf(current.bytes), type: mediaType(path) ?? "image/png" } : null);
  }, [reading.value, path]);

  const name = nameOf(path);
  if (failed.value) return <p class="hint">{failed.value}</p>;
  const r = reading.value;
  if (!r) return <p class="hint">Reading {name}…</p>;
  switch (r.kind) {
    case "image":
      return picture
        ? <ZoomPicture bytes={picture.bytes} type={picture.type} name={r.describedAs || name} description={r.describedAs} />
        : <p class="hint">{name}: it can't be shown here.</p>;
    case "other":
      return <p class="hint">{name}: {r.describedAs}. It can't be shown here.</p>;
    case "unchanged":
      return null;
    case "text": {
      const note = r.isTruncated ? <p class="quiet small">Only the start of {name} is shown.</p> : null;
      const shown = textShownAs(path);
      if (shown === "picture") return <>{note}<ZoomPicture bytes={picture?.bytes ?? r.text} type="image/svg+xml" name={name} /></>;
      if (shown === "page") return <>{note}<div class="file-page"><Markdown text={r.text} images={images} /></div></>;
      if (shown === "source") {
        return (
          <>
            <p class="quiet small">HTML is shown as its source here, so nothing in it runs.</p>
            {note}
            <FileLines text={r.text} line={line} />
          </>
        );
      }
      return <>{note}<FileLines text={r.text} line={line} /></>;
    }
  }
}
