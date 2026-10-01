// One file, read through the host (071 FR-029, FR-031, research R12): text in monospace,
// Markdown through the renderer, pictures as pictures, SVG only as an <img> made from its bytes
// (which a browser draws with scripts off and nothing loaded), and HTML as its source. Nothing a
// file holds can run or reach anywhere: no HTML sink, and the page's CSP besides.
import { useSignal } from "@preact/signals";
import { useEffect } from "preact/hooks";
import type { FileReading } from "../../protocol/generated";
import type { Store } from "../../model/store";
import { describe } from "../../model/errors";
import { Markdown } from "../../render/markdown";
import { extensionOf, nameOf } from "./paneState";

const pictureTypes: Record<string, string> = {
  png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp",
  heic: "image/heic", bmp: "image/bmp", tif: "image/tiff", tiff: "image/tiff", svg: "image/svg+xml", ico: "image/x-icon",
};

function bytesOf(base64: string): Uint8Array {
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

/** A picture as a blob: URL, revoked when the view lets it go. */
function Picture({ bytes, type, name }: { bytes: Uint8Array | string; type: string; name: string }) {
  const url = useSignal<string | null>(null);
  useEffect(() => {
    const made = URL.createObjectURL(new Blob([bytes as BlobPart], { type }));
    url.value = made;
    return () => URL.revokeObjectURL(made);
  }, [bytes, type]);
  return url.value ? <img class="picture" src={url.value} alt={name} /> : null;
}

export function FileView({ store, host, agentID, path }: { store: Store; host: string; agentID: string; path: string }) {
  const reading = useSignal<FileReading | null>(null);
  const failed = useSignal<string | null>(null);
  useEffect(() => {
    reading.value = null;
    failed.value = null;
    void store.readFile(host, agentID, path).then((r) => (reading.value = r), (e) => (failed.value = describe(e)));
  }, [host, agentID, path]);

  const name = nameOf(path);
  const ext = extensionOf(path);
  if (failed.value) return <p class="hint">{failed.value}</p>;
  const r = reading.value;
  if (!r) return <p class="hint">Reading {name}…</p>;
  switch (r.kind) {
    case "image":
      return <Picture bytes={bytesOf(r.bytes)} type={pictureTypes[ext] ?? "image/png"} name={r.describedAs || name} />;
    case "other":
      return <p class="hint">{name}: {r.describedAs}. It can't be shown here.</p>;
    case "unchanged":
      return null;
    case "text": {
      const note = r.isTruncated ? <p class="quiet small">Only the start of {name} is shown.</p> : null;
      if (ext === "svg") return <>{note}<Picture bytes={r.text} type="image/svg+xml" name={name} /></>;
      if (ext === "md" || ext === "markdown") return <>{note}<div class="file-page"><Markdown text={r.text} /></div></>;
      if (ext === "html" || ext === "htm") {
        return (
          <>
            <p class="quiet small">HTML is shown as its source here, so nothing in it runs.</p>
            {note}
            <pre class="file-text">{r.text}</pre>
          </>
        );
      }
      return <>{note}<pre class="file-text">{r.text}</pre></>;
    }
  }
}
