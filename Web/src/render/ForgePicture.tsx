// An image on a Work page (#4011), drawn from bytes the machine that read the page got with
// forge/image: the page never loads the forge's address, and a blob is what the CSP allows. While
// it loads, and when the machine refuses it, it is its alternative text. A click opens it in the
// viewer, in the page. The Mac's and the Remote's is MarkdownText's remote image (#4010).
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import { ImageViewer } from "./ImageViewer";

export function ForgePicture({ url, alt, read }: {
  url: string;
  alt: string;
  read: (url: string) => Promise<{ bytes: Uint8Array; type: string } | null>;
}) {
  const src = useSignal<string | null>(null);
  const natural = useSignal<{ w: number; h: number } | null>(null);
  const open = useSignal(false);
  const readRef = useRef(read);
  readRef.current = read;
  useEffect(() => {
    let current = true;
    let made: string | null = null;
    src.value = null;
    natural.value = null;
    void readRef.current(url).then(
      (got) => {
        if (!current || !got) return;
        made = URL.createObjectURL(new Blob([got.bytes as BlobPart], { type: got.type }));
        src.value = made;
      },
      () => {},
    );
    return () => {
      current = false;
      open.value = false;
      if (made) URL.revokeObjectURL(made);
    };
  }, [url]);
  if (!src.value) return <span class="image-placeholder" title={url}>{alt ? `[image: ${alt}]` : "[image]"}</span>;
  const label = alt || "Image";
  return (
    <>
      <button type="button" class="page-picture-open" title="Open the image" aria-label={`Open ${label}`}
        onClick={() => { open.value = true; }}>
        <img class="page-picture" src={src.value} alt={label}
          onLoad={(event) => {
            const img = event.currentTarget as HTMLImageElement;
            if (img.naturalWidth > 0) natural.value = { w: img.naturalWidth, h: img.naturalHeight };
          }} />
      </button>
      {open.value && natural.value && (
        <ImageViewer src={src.value} alt={alt} natural={natural.value} close={() => { open.value = false; }} />
      )}
    </>
  );
}
