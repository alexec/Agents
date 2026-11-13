// An image on a Work page (#4011), drawn from bytes the machine that read the page got with
// forge/image: the page never loads the forge's address, and a blob is what the CSP allows. While
// it loads, and when the machine refuses it, it is its alternative text. A click opens it in the
// viewer, in the page, with the other images of the same message to go through (#4954). A small
// image (a logo, a badge) and an image that is a link do not open: a click on a link follows it.
// The Mac's and the Remote's is MarkdownText's remote image (#4010).
import { useSignal } from "@preact/signals";
import { useEffect, useRef } from "preact/hooks";
import { ImageViewer, type ViewerImage } from "./ImageViewer";
import { opensLarge } from "../model/pageImage";

/** The images of the message `opener` is in that open large, in their order, and `opener`'s place in them. */
function sequenceOf(opener: HTMLImageElement): { images: ViewerImage[]; start: number } {
  const message = opener.closest(".markdown") ?? opener.parentElement;
  const found = [...(message?.querySelectorAll<HTMLImageElement>("button.page-picture-open > img.page-picture") ?? [])]
    .filter((img) => img.naturalWidth > 0);
  const start = Math.max(0, found.indexOf(opener));
  const images = found.map((img) => ({ src: img.src, alt: img.dataset["alt"] ?? "", natural: { w: img.naturalWidth, h: img.naturalHeight } }));
  return images.length > 0 ? { images, start } : { images: [], start: 0 };
}

export function ForgePicture({ url, alt, read, linked = false }: {
  url: string;
  alt: string;
  read: (url: string) => Promise<{ bytes: Uint8Array; type: string } | null>;
  linked?: boolean;
}) {
  const src = useSignal<string | null>(null);
  const natural = useSignal<{ w: number; h: number } | null>(null);
  const open = useSignal<{ images: ViewerImage[]; start: number } | null>(null);
  const picture = useRef<HTMLImageElement>(null);
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
      open.value = null;
      if (made) URL.revokeObjectURL(made);
    };
  }, [url]);
  if (!src.value) return <span class="image-placeholder" title={url}>{alt ? `[image: ${alt}]` : "[image]"}</span>;
  const label = alt || "Image";
  const img = (
    <img class="page-picture" ref={picture} src={src.value} alt={label} data-alt={alt}
      onLoad={(event) => {
        const el = event.currentTarget as HTMLImageElement;
        const was = natural.peek();
        if (el.naturalWidth > 0 && (was?.w !== el.naturalWidth || was?.h !== el.naturalHeight)) {
          natural.value = { w: el.naturalWidth, h: el.naturalHeight };
        }
      }} />
  );
  // Until its size is known, and when it is small or a link, it is only drawn.
  if (linked || !natural.value || !opensLarge(natural.value.w, natural.value.h)) return img;
  return (
    <>
      <button type="button" class="page-picture-open" title="Open the image" aria-label={`Open ${label}`}
        onClick={() => {
          const opener = picture.current;
          const got = opener ? sequenceOf(opener) : { images: [], start: 0 };
          open.value = got.images.length > 0 ? got
            : { images: [{ src: src.value!, alt, natural: natural.value! }], start: 0 };
        }}>
        {img}
      </button>
      {open.value && (
        <ImageViewer images={open.value.images} start={open.value.start} close={() => { open.value = null; }} />
      )}
    </>
  );
}
